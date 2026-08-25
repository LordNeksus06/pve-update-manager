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
        return [
            { name => 'script' }, { name => 'run' }, { name => 'order' }, { name => 'logs' },
        ];
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

        my $rpcenv = PVE::RPCEnvironment::get();

        PVE::UpdateManager::Config::save_script(
            'lxc', $param->{vmid}, $param->{script}, $rpcenv->get_user(),
        );

        return undef;
    },
});

# ── the previous versions of that script ────────────────────────────────────
#
# Two endpoints rather than one that carries the text of every version: the
# retention goes up to 50 and a script up to 64 KiB, and a list nobody has
# picked from yet has no business being three megabytes.

__PACKAGE__->register_method({
    name => 'script_versions',
    path => 'script/versions',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List the saved versions of a container's update script, newest first.",
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
        type => 'array',
        items => {
            type => 'object',
            properties => {
                version => {
                    type => 'string',
                    maxLength => 32,
                    description => "How this version is asked for, and what stands in its"
                        . " filename: the local second it was saved at,"
                        . " '2026-08-21-13-21-12'. Versions saved before that shape existed"
                        . " are a plain epoch instead, and are still listed and readable.",
                },
                time => {
                    type => 'integer',
                    description => "The same moment as a unix timestamp, for rendering. Kept"
                        . " apart from the identifier: an epoch is not what somebody reading"
                        . " a directory wants, and a formatted local time is not something to"
                        . " do arithmetic on.",
                },
                user => {
                    type => 'string',
                    optional => 1,
                    description => "Who saved it. Absent for a version written before this"
                        . " was recorded, or by something that did not go through the API.",
                },
                size => { type => 'integer' },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        return PVE::UpdateManager::Config::list_versions('lxc', $param->{vmid});
    },
});

__PACKAGE__->register_method({
    name => 'script_version',
    path => 'script/versions/{version}',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "The text of one saved version. Restoring it is a normal save of that"
        . " text, which is why there is no endpoint for it here.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            version => {
                type => 'string',
                # Exactly the two shapes version_file() accepts - the local
                # second a save is named after, or the epoch an older save was
                # named after. Bounded here as well so anything else is a
                # parameter error rather than an exception out of the path
                # builder.
                pattern => '[0-9]{4}(-[0-9]{2}){5}|[0-9]{1,12}',
                maxLength => 32,
                description => "The version, as listed by the endpoint above.",
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
            PVE::UpdateManager::Config::load_version('lxc', $param->{vmid}, $param->{version});

        raise_param_exc({ version => "no such version" }) if !defined($script);

        return { script => $script };
    },
});

# ── where this container sits in a run ──────────────────────────────────────

__PACKAGE__->register_method({
    name => 'set_order',
    path => 'order',
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Set the position of this container in a serial update run.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Config.Options']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            order => {
                type => 'integer',
                minimum => 0,
                maximum => $PVE::UpdateManager::Config::MAX_ORDER,
                description => "Lower goes first. Containers with the same number are"
                    . " updated by ascending vmid. 0 means no answer given, and those go"
                    . " after everything that has one.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Config::save_order('lxc', $param->{vmid}, $param->{order});

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete_script',
    path => 'script',
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Delete the stored update script of a container. With 'purge' the"
        . " recorded last run goes too, which is what the destroy dialog asks for.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Config.Options']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            purge => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Also delete the recorded last run, the saved versions,"
                    . " the update order and the kept run logs. Off by default, because"
                    . " removing a target's commands is not the same as forgetting when it"
                    . " was last updated - the two columns say different things and both"
                    . " stay true after a delete. The destroy dialog sets it: keeping any"
                    . " of it for a container that no longer exists would hand it to"
                    . " whatever is created with that vmid next.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};

        PVE::UpdateManager::Config::delete_script('lxc', $vmid);

        # The history survives a delete, exactly like the recorded last run: what
        # this container ran last week stays true whether or not commands are
        # stored for it now, and it is the one thing that makes a delete
        # undoable. A purge is the destroy dialog, and there the container itself
        # is going - keeping either would hand it to whatever gets that vmid next.
        if ($param->{purge}) {
            PVE::UpdateManager::Config::delete_state('lxc', $vmid);
            PVE::UpdateManager::Config::delete_versions('lxc', $vmid);
            PVE::UpdateManager::Config::delete_order('lxc', $vmid);
            # The kept run logs too, and for the same reason: a log of what CT
            # 101 did last week, handed to whatever is created as 101 next, is
            # somebody else's history in somebody else's editor.
            PVE::UpdateManager::Config::delete_logs('lxc', $vmid);
        }

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'logs',
    path => 'logs',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List the kept logs of this container's past runs, newest first."
        . " They live on the node that ran them, not in /etc/pve - a run log can be far"
        . " larger than the 1 MiB a file there may be. How many are kept is the node's"
        . " `run_logs` setting.",
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
        type => 'array',
        items => {
            type => 'object',
            properties => {
                log => {
                    type => 'string',
                    maxLength => 32,
                    description => "How this log is asked for, and what stands in its"
                        . " filename: the local second the run finished at.",
                },
                time => {
                    type => 'integer',
                    description => "The same moment as a unix timestamp, for rendering.",
                },
                size => { type => 'integer' },
                state => {
                    type => 'string',
                    optional => 1,
                    enum => ['ok', 'failed', 'skipped'],
                    description => "How that run ended, read from the log's own header."
                        . " Absent for a log that has none - one a killed worker left half"
                        . " written.",
                },
                note => {
                    type => 'string',
                    optional => 1,
                    description => "What the verdict said beyond the state - the exit code,"
                        . " the snapshot, a rollback.",
                },
                upid => {
                    type => 'string',
                    optional => 1,
                    description => "The task that produced this log. Proxmox' own log for it"
                        . " is richer while it lasts; it stops being reachable once its entry"
                        . " falls out of the task index, which is why this copy exists.",
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        return PVE::UpdateManager::Config::list_logs('lxc', $param->{vmid});
    },
});

__PACKAGE__->register_method({
    name => 'log',
    path => 'logs/{log}',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "The text of one kept run log. This is the addon's own copy: Proxmox'"
        . " task log stays on disk but stops being reachable once its entry falls out of"
        . " the task index, and this one is pruned on purpose instead.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            log => {
                type => 'string',
                pattern => '[0-9]{4}(-[0-9]{2}){5}',
                maxLength => 32,
                description => "The log, as listed by the endpoint above.",
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

        my $text = PVE::UpdateManager::Config::load_log('lxc', $param->{vmid}, $param->{log});

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
                description => "Store this script first, then run it - a convenience for a"
                    . " caller that would otherwise make two requests. Sending it needs"
                    . " VM.Config.Options on top of VM.Console, because it is a save like"
                    . " any other: what is stored is what the node's schedule runs later,"
                    . " unattended. The web interface does not use it; it saves through PUT"
                    . " and then runs, so pressing Update never runs a stale version either.",
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
        # No parallel flag: this endpoint runs exactly one container, and one
        # target is one wave whichever way the node's switch is set.
        my $opts = PVE::UpdateManager::Config::run_opts($settings);

        if (defined(my $script = $param->{script})) {
            # Running is VM.Console; STORING is VM.Config.Options, here as
            # everywhere else. Console access already means arbitrary root
            # commands inside this container, so the run itself is not what this
            # guards - what it guards is leaving them behind, where the node's
            # schedule will run them again with nobody watching.
            $rpcenv->check($authuser, "/vms/$vmid", ['VM.Config.Options']);

            raise_param_exc({ script => "must not be empty" }) if $script !~ m/\S/;
            PVE::UpdateManager::Config::save_script('lxc', $vmid, $script, $authuser);
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

        # The same rule the worker follows, checked here for the same reason
        # everything else in this endpoint is: the caller gets a plain error
        # instead of a task that has to be opened to find out why it did
        # nothing. The scripts live in /etc/pve and are found wherever this
        # request lands, so a container that has migrated away - or a vmid that
        # names a VM - would otherwise be turned away as "not running", which is
        # true here and wrong everywhere else.
        my $conf = eval { PVE::LXC::Config->load_config($vmid) };
        die "CT $vmid is not a container on node $param->{node}\n" if !$conf;

        # And a template is not one either. Without this the answer below is
        # "not running - enable 'start stopped containers' to update it anyway",
        # which is advice that cannot work: PVE refuses to start a template and
        # refuses to snapshot one.
        die "CT $vmid is a template - there is nothing to update\n"
            if PVE::LXC::Config->is_template($conf);

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
