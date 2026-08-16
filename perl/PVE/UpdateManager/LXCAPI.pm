package PVE::UpdateManager::LXCAPI;

# API below /nodes/{node}/lxc/{vmid}/updatemgr - the per-container tab.
#
# Registered into PVE::API2::LXC at runtime by PVE::UpdateManager::Inject, so
# no file shipped by pve-manager carries a modified API tree.

use strict;
use warnings;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::LXC;
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
            vmid => get_standard_option('pve-vmid'),
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
        return [{ name => 'script' }, { name => 'run' }];
    },
});

__PACKAGE__->register_method({
    name => 'get_script',
    path => 'script',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "Get the stored update script of a container.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            script => {
                type => 'string',
                description => "The stored commands. Empty when nothing is stored.",
            },
            stored => {
                type => 'boolean',
                description => "False when nothing is stored, in which case 'script' is empty.",
            },
            %{ PVE::UpdateManager::Config::last_run_schema() },
        },
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my ($script, $stored) = PVE::UpdateManager::Config::load_script('lxc', $vmid);

        return {
            # Empty when nothing is stored, rather than a template dressed up as
            # this target's commands. A box that fills itself in reads as "there
            # is already something here", and the Templates menu is right there
            # for anyone who wants a starting point.
            script => $stored ? $script : '',
            stored => $stored ? 1 : 0,
            %{ PVE::UpdateManager::Config::last_run('lxc', $vmid) },
        };
    },
});

__PACKAGE__->register_method({
    name => 'set_script',
    path => 'script',
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Store the update script of a container.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Config.Options']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            script => {
                type => 'string',
                maxLength => $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE,
                description => "The update commands. Runs as root inside the container.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Config::save_script('lxc', $param->{vmid}, $param->{script});

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete_script',
    path => 'script',
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Delete the stored update script of a container.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Config.Options']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Config::delete_script('lxc', $param->{vmid});

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'run',
    path => 'run',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Run the update script inside the container. Returns the UPID of the task,"
        . " or an empty string when the container has no script stored - that is recorded as a"
        . " skipped run on the container itself and starts no task.",
    permissions => {
        description => "Running arbitrary commands as root inside a container is what console"
            . " access already allows, so VM.Console is what this needs.",
        check => ['perm', '/vms/{vmid}', ['VM.Console']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            script => {
                type => 'string',
                optional => 1,
                maxLength => $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE,
                description => "Store this script first, then run it. The UI sends the text box"
                    . " content here so pressing Update never runs a stale version.",
            },
            timeout => {
                type => 'integer',
                optional => 1,
                minimum => $PVE::UpdateManager::Runner::MIN_TIMEOUT,
                maximum => $PVE::UpdateManager::Runner::MAX_TIMEOUT,
                description => "Kill the run after this many seconds. Defaults to the"
                    . " timeout configured on the node this container runs on.",
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $vmid = $param->{vmid};
        # A container has no settings of its own - it inherits those of the node
        # it runs on, which is where the Settings dialog lives.
        my $settings = PVE::UpdateManager::Config::load_settings($param->{node});
        my $timeout = $param->{timeout} // $settings->{timeout};
        my $opts = { start_stopped => $settings->{start_stopped} };

        if (defined(my $script = $param->{script})) {
            raise_param_exc({ script => "must not be empty" }) if $script !~ m/\S/;
            PVE::UpdateManager::Config::save_script('lxc', $vmid, $script);
        }

        # FIRST, before anything below writes anything. The worker checks this
        # again under a lock; this one is here so pressing Update twice says so
        # immediately instead of opening a task that skips - and, now that the
        # no-script case below records a state instead of raising, so that
        # removing a container's script mid-run and pressing Update again cannot
        # put "skipped" over a live "running" and stop the spinner on a row whose
        # task is still working. It used to sit two checks further down, which
        # was harmless while everything here only raised.
        die "CT $vmid is already being updated\n"
            if PVE::UpdateManager::Config::target_is_running('lxc', $vmid);

        # Nothing stored is a SKIP, not an error - and it is recorded on the
        # container's own row rather than raised.
        #
        # It used to raise. Updating forty containers means forty of these
        # requests, and a dozen of them coming back as errors turned into a
        # dialog with a dozen lines in it - for a case the confirmation dialog
        # had just described as "will be skipped". The row is where that belongs,
        # it is where the worker puts the same verdict for the targets it walks
        # itself, and it survives the popup being clicked away.
        my ($stored) = PVE::UpdateManager::Config::load_script('lxc', $vmid);
        if (!defined($stored) || $stored !~ m/\S/) {
            PVE::UpdateManager::Job::skip_no_script({ type => 'lxc', id => $vmid });
            # No task was started, so there is no UPID to hand back. The caller
            # reads that as "nothing to watch", not as a failure.
            return '';
        }

        # Checked here rather than in the worker: the caller gets a plain error
        # response instead of a task that has to be opened to find out why it
        # did nothing. Unless the node is set to start stopped containers, in
        # which case being stopped is exactly what the run is meant to handle.
        die "CT $vmid is not running (enable 'start stopped containers' in the node's"
            . " Update Manager settings to update it anyway)\n"
            if !$opts->{start_stopped} && !PVE::LXC::check_running($vmid);

        my $name = eval { PVE::LXC::Config->load_config($vmid)->{hostname} };

        my $realcmd = sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => $vmid, name => $name }],
                $timeout,
                $opts,
            );
        };

        return $rpcenv->fork_worker('ctupdate', $vmid, $authuser, $realcmd);
    },
});

1;
