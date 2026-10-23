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
use PVE::Storage;

use PVE::UpdateManager::Authz;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::SecReact;
use PVE::UpdateManager::SecSummary;
use PVE::UpdateManager::Settings;
use PVE::UpdateManager::Snapshot;
use PVE::UpdateManager::Versions;

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
            { name => 'logs' },
            { name => 'settings' },
            { name => 'order' },
            { name => 'security' },
        ];
    },
});

# ── the node's settings ─────────────────────────────────────────────────────
#
# The node is where they LIVE, and a run always follows the settings of the node
# that owns the target. A container has no opinion about when it should be
# updated and a cluster-wide schedule would have to pick a node to run it, so
# this belongs to the node that owns the targets and whose timer will fire.
#
# /cluster/updatemgr/settings writes these same files on every node at once. It
# is a convenience over this, not a second place where settings are kept - there
# is no cluster-wide value anywhere, only twelve nodes that were told the same
# thing.

my $settings_properties = PVE::UpdateManager::Settings::settings_schema();

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
            snapshot_capable => {
                type => 'boolean',
                description => "Whether any container on this node sits on a storage that can"
                    . " snapshot. False means the snapshot setting has nothing to act on here,"
                    . " and the web interface leaves it out rather than offering a switch that"
                    . " would do nothing.",
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $settings = PVE::UpdateManager::Settings::load_settings($param->{node});

        my $res = { %$settings };

        if ($settings->{schedule_enabled}) {
            # From now, not from last_run: this answers "when will it next fire",
            # and a schedule that is already overdue would otherwise report a
            # time in the past.
            my $next = PVE::UpdateManager::Settings::next_schedule_run($settings, time());
            $res->{next_run} = $next if defined($next);
        }

        # Asked per container rather than by looking at storage.cfg: whether a
        # snapshot is possible depends on every volume a container has, so one
        # mountpoint on a directory storage is enough to make the answer no -
        # and a list of "storage types that can snapshot" kept here would be
        # wrong the first time a plugin gained the feature.
        # Never dies, all of it. This builds a settings dialog, and a storage.cfg
        # or a guest list that cannot be read may cost the snapshot switch and a
        # line in the syslog - it may not cost the operator the whole window.
        $res->{snapshot_capable} = 0;

        my $storecfg = eval { PVE::Storage::config() };
        if (my $err = $@) {
            chomp($err);
            # Said once, here, rather than once per container from can_snapshot:
            # that is the whole reason for reading it in this loop's caller.
            warn "pve-update-manager: cannot read the storage configuration: $err\n";
        }

        # VMs count too: they are snapshotted with the same settings.
        GUEST: for my $type (@PVE::UpdateManager::Guest::TYPES) {
            my $list = eval { PVE::UpdateManager::Guest::config_list($type) } || {};
            for my $vmid (keys %$list) {
                next if !PVE::UpdateManager::Snapshot::can_snapshot($vmid, $storecfg);
                $res->{snapshot_capable} = 1;
                last GUEST;
            }
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
        description => "Sys.Console on /nodes/{node}. A save that changes anything also needs"
            . " what the node will then run unattended: for every scheduled or immediately"
            . " updated guest the privileges a run of it needs, and root\@pam when the host"
            . " script is scheduled or immediate updates cover every target (#63, #65).",
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

        my $rpcenv = PVE::RPCEnvironment::get();
        PVE::UpdateManager::Authz::check_settings_save(
            $rpcenv, $rpcenv->get_user(), PVE::UpdateManager::Settings::load_settings($node), $param,
        );

        PVE::UpdateManager::Settings::save_settings($node, $param);

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'targets',
    path => 'targets',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List every update target on this node: the host itself, every container"
        . " and every VM.",
    permissions => {
        description => "Lists only what the user may see: the host needs Sys.Audit on /nodes/{node},"
            . " a container or VM VM.Audit on /vms/{vmid}.",
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
                type => { type => 'string', enum => ['node', 'lxc', 'qemu'] },
                id => { type => 'string', description => "Node name for the host, vmid for a guest." },
                vmid => { type => 'integer', optional => 1 },
                name => { type => 'string' },
                status => { type => 'string' },
                stored => { type => 'boolean', description => "An update script is stored for this target." },
                template => { type => 'boolean', optional => 1 },
                order => {
                    type => 'integer',
                    description => "Where this target sits in a run. Lower goes first, 0"
                        . " means no answer given and goes last. In a parallel run everything"
                        . " sharing a number starts at once and the next number waits for it.",
                },
                parallel_manual => {
                    type => 'boolean',
                    optional => 1,
                    description => "Node rows only: whether manual runs on this node start"
                        . " all targets at once. The grids read it from here so a run"
                        . " honours the setting of the node that owns the target.",
                },
                snapshot_shutdown => {
                    type => 'boolean',
                    optional => 1,
                    description => "Node rows only: whether a container or VM on this node is shut"
                        . " down for its snapshot. The confirmation dialog says so out loud,"
                        . " because it is downtime nobody asked for at the moment of clicking.",
                },
                %{ PVE::UpdateManager::Config::last_run_schema() },
                %{ PVE::UpdateManager::SecSummary::row_schema() },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $node = $param->{node};
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        # The security check's results (#41), from the one summary file the
        # background round writes - read once here, never a guest touched:
        # this is an API call, and the web UI waits on it (#35).
        my $sec = PVE::UpdateManager::SecSummary::load($node);

        my $res = [];

        # The host goes first so it is where the eye lands, but the UI leaves it
        # unticked - Proxmox has its own updater for the node and this row is the
        # exception, not the default.
        if ($rpcenv->check($authuser, "/nodes/$node", ['Sys.Audit'], 1)) {
            my $settings = PVE::UpdateManager::Settings::load_settings($node);
            push @$res, {
                type => 'node',
                id => $node,
                name => $node,
                status => 'online',
                stored => PVE::UpdateManager::Config::has_script('node', $node) ? 1 : 0,
                order => PVE::UpdateManager::Config::load_order('node', $node),
                parallel_manual => $settings->{parallel_manual} ? 1 : 0,
                snapshot_shutdown =>
                    ($settings->{snapshot_before} && $settings->{snapshot_shutdown}) ? 1 : 0,
                %{ PVE::UpdateManager::Config::last_run('node', $node) },
                %{ PVE::UpdateManager::SecSummary::row_fields($sec, 'node', $node) },
            };
        }

        # Containers first, then VMs, each by vmid - the grid sorts for itself,
        # this only keeps the answer stable.
        for my $type (@PVE::UpdateManager::Guest::TYPES) {
            my $list = PVE::UpdateManager::Guest::config_list($type);
            for my $vmid (sort { $a <=> $b } keys %$list) {
                next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);

                my $conf = eval { PVE::UpdateManager::Guest::load_config($type, $vmid) } || {};
                my $running = PVE::UpdateManager::Guest::is_running($type, $vmid);

                push @$res, {
                    type => $type,
                    id => "$vmid",
                    vmid => int($vmid),
                    name => PVE::UpdateManager::Guest::name($type, $conf, $vmid),
                    status => $running ? 'running' : 'stopped',
                    template => $conf->{template} ? 1 : 0,
                    stored => PVE::UpdateManager::Config::has_script($type, $vmid) ? 1 : 0,
                    order => PVE::UpdateManager::Config::load_order($type, $vmid),
                    %{ PVE::UpdateManager::Config::last_run($type, $vmid) },
                    %{ PVE::UpdateManager::SecSummary::row_fields($sec, $type, $vmid) },
                };
            }
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
        description => "root\@pam only: the script runs as root on the node, and PVE gives a"
            . " root shell on the node to root\@pam alone (#63).",
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

        my $rpcenv = PVE::RPCEnvironment::get();
        PVE::UpdateManager::Authz::check_root($rpcenv->get_user(), 'the host script');

        PVE::UpdateManager::Config::save_script(
            'node', $param->{node}, $param->{script}, $rpcenv->get_user(),
        );

        return undef;
    },
});

# ── the previous versions of that script ────────────────────────────────────
#
# The same pair of endpoints the container tab has, for the host's own script.

__PACKAGE__->register_method({
    name => 'script_versions',
    path => 'script/versions',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List the saved versions of the host's update script, newest first.",
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
        type => 'array',
        items => {
            type => 'object',
            properties => {
                # The shape and the reasoning are the container endpoint's -
                # see PVE::UpdateManager::LXCAPI.
                version => { type => 'string', maxLength => 32 },
                time => { type => 'integer' },
                user => { type => 'string', optional => 1 },
                size => { type => 'integer' },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        return PVE::UpdateManager::Versions::list_versions('node', $param->{node});
    },
});

__PACKAGE__->register_method({
    name => 'script_version',
    path => 'script/versions/{version}',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "The text of one saved version of the host's update script.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            version => {
                type => 'string',
                # Exactly the two shapes version_file() accepts - see the
                # container endpoint for why there are two.
                pattern => '[0-9]{4}(-[0-9]{2}){5}|[0-9]{1,12}',
                maxLength => 32,
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            script => { type => 'string' },
        },
    },
    code => sub {
        my ($param) = @_;

        my $script =
            PVE::UpdateManager::Versions::load_version('node', $param->{node}, $param->{version});

        raise_param_exc({ version => "no such version" }) if !defined($script);

        return { script => $script };
    },
});

__PACKAGE__->register_method({
    name => 'set_order',
    path => 'order',
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Set the position of this host in a serial update run.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            order => {
                type => 'integer',
                minimum => 0,
                maximum => $PVE::UpdateManager::Config::MAX_ORDER,
                description => "Lower goes first. 0 means no answer given, and that goes"
                    . " after everything that has one - which is where the host row would"
                    . " otherwise sit anyway, since a run only ever includes it on purpose.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Config::save_order('node', $param->{node}, $param->{order});

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
    name => 'logs',
    path => 'logs',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List the kept logs of the host's own past runs, newest first. The shape"
        . " and the reasoning are the container endpoint's - see"
        . " PVE::UpdateManager::LXCAPI.",
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
        type => 'array',
        items => {
            type => 'object',
            properties => {
                # The shape and the reasoning are the container endpoint's.
                log => { type => 'string', maxLength => 32 },
                time => { type => 'integer' },
                size => { type => 'integer' },
                state => { type => 'string', optional => 1, enum => ['ok', 'not_fixed', 'failed', 'skipped'] },
                note => { type => 'string', optional => 1 },
                upid => { type => 'string', optional => 1 },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        return PVE::UpdateManager::Logs::list_logs('node', $param->{node});
    },
});

__PACKAGE__->register_method({
    name => 'log',
    path => 'logs/{log}',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "The text of one kept run log of the host itself.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            log => {
                type => 'string',
                pattern => '[0-9]{4}(-[0-9]{2}){5}',
                maxLength => 32,
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            log => { type => 'string' },
        },
    },
    code => sub {
        my ($param) = @_;

        my $text = PVE::UpdateManager::Logs::load_log('node', $param->{node}, $param->{log});

        raise_param_exc({ log => "no such run log" }) if !defined($text);

        return { log => $text };
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
        description => "Checked per target: for every guest what a run of it needs with the"
            . " node's settings - VM.Console, and VM.Snapshot, VM.Snapshot(.Rollback) or"
            . " VM.PowerMgmt where the run snapshots, rolls back or starts and stops it (#64);"
            . " root\@pam when the host is included (#63).",
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
                description => "Comma separated list of guest ids (containers or VMs) to update.",
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
        my $settings = PVE::UpdateManager::Settings::load_settings($node);
        my $timeout = $param->{timeout} // $settings->{timeout};
        # The node's own switch decides whether the selection is walked one at a
        # time or a position at a time - not the caller. It used to be the caller:
        # the web interface sent one request per target for a parallel run, which
        # is why the update order did nothing there and why nothing knew when the
        # whole run was over.
        my $opts = PVE::UpdateManager::Settings::run_opts(
            $settings, $settings->{parallel_manual}, $settings->{parallel_manual_max},
        );

        my $targets = [];

        if ($param->{host}) {
            PVE::UpdateManager::Authz::check_root($authuser, 'the host script');
            push @$targets, { type => 'node', id => $node, name => $node };
        }

        if (defined($param->{vmids}) && length($param->{vmids})) {
            for my $vmid (split(/,/, $param->{vmids})) {
                PVE::UpdateManager::Authz::check_guest_run($rpcenv, $authuser, "/vms/$vmid", $settings);
                push @$targets, PVE::UpdateManager::Guest::target($vmid);
            }
        }

        raise_param_exc({ vmids => "no update target selected" }) if !scalar(@$targets);

        my $realcmd = sub {
            PVE::UpdateManager::Job::run_all($targets, $timeout, $opts);
        };

        return $rpcenv->fork_worker('updatemgr', $node, $authuser, $realcmd);
    },
});

# ── the security check (#40, #41) ───────────────────────────────────────────

__PACKAGE__->register_method({
    name => 'security_index',
    path => 'security',
    method => 'GET',
    permissions => { user => 'all' },
    description => "Security check index.",
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => {
        type => 'array',
        items => { type => 'object', properties => {} },
        links => [{ rel => 'child', href => '{name}' }],
    },
    code => sub { return [{ name => 'scan' }] },
});

__PACKAGE__->register_method({
    name => 'security_scan',
    path => 'security/scan',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Check this node's targets for pending security updates now, in a"
        . " background task. Returns its UPID at once; when another check is still"
        . " running, the task says so and does nothing.",
    permissions => {
        description => "Sys.Console on /nodes/{node}: the check reads every guest's package"
            . " list, and with security_install on it can start updates.",
        check => ['perm', '/nodes/{node}', ['Sys.Console']],
    },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $node = $param->{node};
        my $rpcenv = PVE::RPCEnvironment::get();

        # A worker task, not the work: this call returns at once whatever the
        # guests do (#35 - pvedaemon has three workers, #36 V8).
        return $rpcenv->fork_worker('updmgrscan', $node, $rpcenv->get_user(),
            sub { PVE::UpdateManager::SecReact::worker($node) });
    },
});

1;
