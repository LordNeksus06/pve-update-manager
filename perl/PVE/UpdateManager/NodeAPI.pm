package PVE::UpdateManager::NodeAPI;

# API below /nodes/{node}/updatemgr - the node-wide tab.
#
# Two jobs: list every update target on this node (the host plus its
# containers) with enough state for the grid to render, and run a selection of
# them in one task.
#
# Registered into PVE::API2::Nodes::Nodeinfo at runtime by
# PVE::UpdateManager::Inject.

use strict;
use warnings;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::LXC;
use PVE::LXC::Config;
use PVE::RESTHandler;
use PVE::RPCEnvironment;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Runner;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Update manager index.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {},
        },
        links => [{ rel => 'child', href => '{name}' }],
    },
    code => sub {
        return [
            { name => 'script' },
            { name => 'targets' },
            { name => 'run' },
            { name => 'settings' },
        ];
    },
});

# ── the node's settings ─────────────────────────────────────────────────────
#
# Deliberately only here. A container has no opinion about when it should be
# updated and a cluster-wide schedule would have to pick a node to run it, so
# this belongs to the node that owns the targets and whose timer will fire.

my $settings_properties = {
    parallel_manual => {
        type => 'boolean',
        description => "Start all targets at once when Update Selected is pressed.",
    },
    timeout => {
        type => 'integer',
        minimum => $PVE::UpdateManager::Runner::MIN_TIMEOUT,
        maximum => $PVE::UpdateManager::Runner::MAX_TIMEOUT,
        description => "Kill a target's update after this many seconds. Applies to manual"
            . " and scheduled runs alike. This really does kill the process tree, so it"
            . " must sit above anything a real upgrade takes.",
    },
    start_stopped => {
        type => 'boolean',
        description => "Start a stopped container for its update and shut it down again"
            . " afterwards. Off by default: a stopped container is skipped, because"
            . " starting one runs its services for as long as the update takes.",
    },
    schedule_enabled => {
        type => 'boolean',
        description => "Run the selected targets on a schedule.",
    },
    schedule_time => {
        type => 'string',
        maxLength => 128,
        description => "When to run, as a systemd calendar event - the same syntax as a"
            . " backup job's schedule: '03:00', 'mon..fri 02:30', '*/8:00'.",
    },
    schedule_parallel => {
        type => 'boolean',
        description => "Start all targets at once on a scheduled run too.",
    },
    schedule_host => {
        type => 'boolean',
        description => "Include the node's own update script in scheduled runs.",
    },
    schedule_vmids => {
        type => 'string',
        # The empty string has to be allowed: it is how "no containers" is
        # expressed, and without it the settings window could never have its last
        # container unticked - Save would fail on the pattern.
        pattern => '(\d+(,\d+)*)?',
        maxLength => 4096,
        description => "Comma separated container ids for scheduled runs. Empty for none.",
    },
};

__PACKAGE__->register_method({
    name => 'get_settings',
    path => 'settings',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "Get the node's update manager settings.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            %$settings_properties,
            last_run => {
                type => 'integer',
                description => "When the schedule last started a run. 0 means never.",
            },
            next_run => {
                type => 'integer',
                optional => 1,
                description => "When the schedule fires next. Absent while disabled.",
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $settings = PVE::UpdateManager::Config::load_settings($param->{node});

        my $res = { %$settings };

        if ($settings->{schedule_enabled}) {
            # From now, not from last_run: this answers "when will it next fire",
            # and a schedule that is already overdue would otherwise report a
            # time in the past.
            my $next = PVE::UpdateManager::Config::next_schedule_run($settings, time());
            $res->{next_run} = $next if defined($next);
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'set_settings',
    path => 'settings',
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Set the node's update manager settings.",
    permissions => {
        description => "A schedule runs the stored commands as root, on the node and inside"
            . " containers, without anybody watching - so it needs the privilege that"
            . " running them by hand needs.",
        check => ['perm', '/nodes/{node}', ['Sys.Console']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            (map { $_ => { %{ $settings_properties->{$_} }, optional => 1 } }
                keys %$settings_properties),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $node = delete $param->{node};

        PVE::UpdateManager::Config::save_settings($node, $param);

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'targets',
    path => 'targets',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List every update target on this node: the host itself and every container.",
    permissions => {
        description => "Lists only what the user may see: the host needs Sys.Audit on /nodes/{node},"
            . " a container VM.Audit on /vms/{vmid}.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                type => { type => 'string', enum => ['node', 'lxc'] },
                id => { type => 'string', description => "Node name for the host, vmid for a container." },
                vmid => { type => 'integer', optional => 1 },
                name => { type => 'string' },
                status => { type => 'string' },
                stored => { type => 'boolean', description => "An update script is stored for this target." },
                template => { type => 'boolean', optional => 1 },
                parallel_manual => {
                    type => 'boolean',
                    optional => 1,
                    description => "Node rows only: whether manual runs on this node start"
                        . " all targets at once. The grids read it from here so a run"
                        . " honours the setting of the node that owns the target.",
                },
                %{ PVE::UpdateManager::Config::last_run_schema() },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $node = $param->{node};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $res = [];

        # The host goes first so it is where the eye lands, but the UI leaves it
        # unticked - Proxmox has its own updater for the node and this row is the
        # exception, not the default.
        if ($rpcenv->check($authuser, "/nodes/$node", ['Sys.Audit'], 1)) {
            push @$res, {
                type => 'node',
                id => $node,
                name => $node,
                status => 'online',
                stored => PVE::UpdateManager::Config::has_script('node', $node) ? 1 : 0,
                parallel_manual =>
                    PVE::UpdateManager::Config::load_settings($node)->{parallel_manual} ? 1 : 0,
                %{ PVE::UpdateManager::Config::last_run('node', $node) },
            };
        }

        my $list = PVE::LXC::config_list();
        for my $vmid (sort { $a <=> $b } keys %$list) {
            next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);

            my $conf = eval { PVE::LXC::Config->load_config($vmid) } || {};
            my $running = PVE::LXC::check_running($vmid) ? 1 : 0;

            push @$res, {
                type => 'lxc',
                id => "$vmid",
                vmid => int($vmid),
                name => $conf->{hostname} // "CT$vmid",
                status => $running ? 'running' : 'stopped',
                template => $conf->{template} ? 1 : 0,
                stored => PVE::UpdateManager::Config::has_script('lxc', $vmid) ? 1 : 0,
                %{ PVE::UpdateManager::Config::last_run('lxc', $vmid) },
            };
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'get_script',
    path => 'script',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "Get the stored update script of the host itself.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            script => { type => 'string' },
            stored => { type => 'boolean' },
            %{ PVE::UpdateManager::Config::last_run_schema() },
        },
    },
    code => sub {
        my ($param) = @_;

        my $node = $param->{node};
        my ($script, $stored) = PVE::UpdateManager::Config::load_script('node', $node);

        return {
            # Empty when nothing is stored, rather than a template dressed up as
            # this target's commands. A box that fills itself in reads as "there
            # is already something here", and the Templates menu is right there
            # for anyone who wants a starting point.
            script => $stored ? $script : '',
            stored => $stored ? 1 : 0,
            %{ PVE::UpdateManager::Config::last_run('node', $node) },
        };
    },
});

__PACKAGE__->register_method({
    name => 'set_script',
    path => 'script',
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Store the update script of the host itself.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            script => {
                type => 'string',
                maxLength => $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE,
                description => "The update commands. Runs as root on the node.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Config::save_script('node', $param->{node}, $param->{script});

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete_script',
    path => 'script',
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Delete the stored update script of the host itself.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Config::delete_script('node', $param->{node});

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'run',
    path => 'run',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Run the update scripts of the selected targets in one task."
        . " Returns the UPID of that task.",
    permissions => {
        description => "Checked per target: VM.Console on /vms/{vmid} for every container,"
            . " Sys.Console on /nodes/{node} when the host is included.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmids => {
                type => 'string',
                optional => 1,
                pattern => '\d+(,\d+)*',
                description => "Comma separated list of container ids to update.",
            },
            host => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Also run the host's own update script.",
            },
            timeout => {
                type => 'integer',
                optional => 1,
                minimum => $PVE::UpdateManager::Runner::MIN_TIMEOUT,
                maximum => $PVE::UpdateManager::Runner::MAX_TIMEOUT,
                description => "Kill a single target's run after this many seconds."
                    . " Defaults to the node's configured timeout.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $node = $param->{node};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        # The settings are the default, not a hardcoded hour: the limit now kills
        # the process tree, so whoever owns the node has to be able to see it and
        # move it.
        my $settings = PVE::UpdateManager::Config::load_settings($node);
        my $timeout = $param->{timeout} // $settings->{timeout};
        my $opts = { start_stopped => $settings->{start_stopped} };

        my $targets = [];

        if ($param->{host}) {
            $rpcenv->check($authuser, "/nodes/$node", ['Sys.Console']);
            push @$targets, { type => 'node', id => $node, name => $node };
        }

        if (defined($param->{vmids}) && length($param->{vmids})) {
            for my $vmid (split(/,/, $param->{vmids})) {
                $rpcenv->check($authuser, "/vms/$vmid", ['VM.Console']);
                my $name = eval { PVE::LXC::Config->load_config($vmid)->{hostname} };
                push @$targets, { type => 'lxc', id => $vmid, name => $name };
            }
        }

        raise_param_exc({ vmids => "no update target selected" }) if !scalar(@$targets);

        my $realcmd = sub {
            PVE::UpdateManager::Job::run_all($targets, $timeout, $opts);
        };

        return $rpcenv->fork_worker('updatemgr', $node, $authuser, $realcmd);
    },
});

1;
