package PVE::UpdateManager::Config;

# Storage for the update scripts.
#
# One plain file per target, holding exactly what the user typed into the text
# box - no encoding, no wrapper format. `cat /etc/pve/pve-update-manager/lxc-101.conf`
# shows the script and an editor can change it without going through the UI.
#
# The scripts live in the cluster filesystem on purpose: /etc/pve is replicated
# to every node, so a container keeps its update script when it migrates, and a
# second node shows the same content. pmxcfs supports both mkdir and the
# tmpfile+rename that file_set_contents does (verified on PVE 9.2).

use strict;
use warnings;

use PVE::CalendarEvent;
use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;

use PVE::UpdateManager::Runner;

# `our` rather than a constant so the test suite can point it at a tmpdir.
our $BASE_DIR = '/etc/pve/pve-update-manager';

# pmxcfs refuses files above 1 MiB. Cut off far below that: an update script is
# a handful of lines, and a request that tries to store a megabyte of text is a
# mistake we want to name rather than a write we want to attempt.
our $MAX_SCRIPT_SIZE = 64 * 1024;

# Builds the path AND validates the id. Every caller goes through here, so a
# vmid or node name from an API request can never walk out of $BASE_DIR.
# `or -d` because two saves racing on a fresh install would otherwise have one
# of them die on the other's EEXIST. $! is captured BEFORE the -d stat, which
# would otherwise overwrite it and report a genuine EACCES as "No such file or
# directory".
sub _ensure_base_dir {
    return if -d $BASE_DIR;

    return if mkdir($BASE_DIR);
    my $err = $!;

    return if -d $BASE_DIR;

    die "unable to create '$BASE_DIR' - $err\n";
}

# The public half of the same thing, for the modules that store something beside
# the per-target files - the template list, which has no target and so no
# script_file() call to create the directory as a side effect.
sub ensure_base_dir {
    _ensure_base_dir();

    return $BASE_DIR;
}

sub script_file {
    my ($type, $id) = @_;

    die "unknown target type '$type'\n" if $type ne 'lxc' && $type ne 'node';
    die "missing target id\n" if !defined($id) || $id eq '';

    my $safe;
    if ($type eq 'lxc') {
        ($safe) = $id =~ m/\A([1-9][0-9]{2,8})\z/
            or die "invalid vmid '$id'\n";
    } else {
        ($safe) = $id =~ m/\A([A-Za-z0-9](?:[A-Za-z0-9\-\.]{0,62}))\z/
            or die "invalid node name '$id'\n";
    }

    return "$BASE_DIR/$type-$safe.conf";
}

# Returns ($script, $exists). A target with no file yet is not an error - the
# UI shows the default template for it and only writes on save.
sub load_script {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    return (undef, 0) if !-f $file;

    my $raw = PVE::Tools::file_get_contents($file, $MAX_SCRIPT_SIZE);
    return ($raw, 1);
}

# "Has a script" means "has something to run", not "has a file". An empty file
# would otherwise show a tick in the grid and then be skipped at run time for
# having no commands - a row that promises one thing and does another.
#
# Never dies. This is called once per target while building the node and
# datacenter lists, and load_script dies on a file above $MAX_SCRIPT_SIZE - so a
# single hand-written oversized file used to take out the WHOLE list, for every
# target, on both tabs. One broken target may cost its own row's tick and a line
# in the syslog; it may not cost the list.
sub has_script {
    my ($type, $id) = @_;

    my ($script) = eval { load_script($type, $id) };
    if (my $err = $@) {
        chomp($err);
        warn "pve-update-manager: cannot read the update script of $type $id: $err\n";
        return 0;
    }

    return (defined($script) && $script =~ m/\S/) ? 1 : 0;
}

sub save_script {
    my ($type, $id, $script) = @_;

    my $file = script_file($type, $id);

    # Text pasted out of a Windows editor carries CR before every LF, and a shell
    # takes those as part of the command: measured, a pasted script died with
    # "$'uptime\r': command not found", which names neither the cause nor the
    # cure. A literal CR in a shell script is always an accident - anyone who
    # wants one writes it as an escape - so it is dropped here, at the one place
    # everything is stored through, and what the box shows afterwards is what
    # will actually run.
    $script =~ s/\r\n/\n/g if defined($script);

    die "update script is too large (max $MAX_SCRIPT_SIZE bytes)\n"
        if length($script) > $MAX_SCRIPT_SIZE;

    # Storing nothing is refused rather than accepted: it reads as "saved" in the
    # web interface and then silently skips at run time. Removing a target's
    # commands is what DELETE is for, and it says so.
    die "refusing to store an empty update script - use DELETE to remove it\n"
        if $script !~ m/\S/;

    _ensure_base_dir();

    PVE::Tools::file_set_contents($file, $script);

    return $file;
}

# Removes the commands and NOTHING else. The recorded last run stays: when a
# target was last updated is a fact about the target, not about the script that
# happened to be stored at the time - and it is the answer to the question the
# grid gets asked most ("when did this last get updated?"). The two columns say
# two different things, and after a delete they still both say something true:
# no commands stored, last updated on such a date.
sub delete_script {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    return 0 if !-f $file;

    unlink($file) or die "unable to delete '$file' - $!\n";

    return 1;
}

# Only for wiping a target's history on purpose. Nothing in the UI calls it -
# purging the package takes the whole directory instead.
sub delete_state {
    my ($type, $id) = @_;

    my $file = state_file($type, $id);
    return 0 if !-f $file;

    unlink($file) or die "unable to delete '$file' - $!\n";

    return 1;
}

# ── last run per target ─────────────────────────────────────────────────────
#
# One file next to the script, same plain-text spirit: `key=value` per line, no
# JSON, `cat` tells you what happened. It records what the grid needs to show a
# target's state without scanning the task archive - and because it lives in
# /etc/pve, a node can show the state of a run that happened on another node,
# which is what the Datacenter view is built on.
#
# Deliberately not the task log itself: task logs rotate away, this does not.

sub state_file {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    $file =~ s/\.conf\z/.state/;

    return $file;
}

# Returns a hashref or undef. A corrupt file is treated as "no state" rather
# than an error: a broken bookkeeping file must not stop an update from running.
sub load_state {
    my ($type, $id) = @_;

    my $file = state_file($type, $id);
    return undef if !-f $file;

    my $raw = eval { PVE::Tools::file_get_contents($file, 8192) };
    return undef if !defined($raw);

    my $state = {};
    for my $line (split(/\n/, $raw)) {
        next if $line !~ m/\A([a-z_]+)=(.*)\z/;
        $state->{$1} = $2;
    }

    return undef if !defined($state->{state});

    return $state;
}

# The schema half of last_run(), so the node API and the cluster API describe
# the same fields without drifting apart.
sub last_run_schema {
    return {
        last_state => {
            type => 'string',
            optional => 1,
            enum => ['running', 'ok', 'failed', 'skipped', 'unknown'],
            description => "State of the last run. Absent when the target was never run."
                . " 'unknown' means the run ended without recording a result - its worker"
                . " was killed, or the state file is unreadable.",
        },
        last_upid => {
            type => 'string',
            optional => 1,
            description => "UPID of the task that produced that state - open it for the log.",
        },
        last_started => { type => 'integer', optional => 1 },
        last_finished => { type => 'integer', optional => 1 },
        last_exit => { type => 'integer', optional => 1 },
        last_note => {
            type => 'string',
            optional => 1,
            description => "Why a run was skipped.",
        },
    };
}

our @KNOWN_STATES = qw(running ok failed skipped unknown);

# Is the worker that wrote a "running" state still alive?
#
# A worker that is killed - node reboot, SIGKILL, an out-of-memory kill - never
# reaches the line that records its result. Without this check the row spins
# forever, the grid polls it every few seconds for ever, and the Update button
# stays disabled because the target looks busy: a dead end that can only be left
# by deleting the state file by hand.
#
# Only the local node can be judged. A worker on another node has a /proc we
# cannot read, so an unverifiable run is left alone rather than declared dead.
sub _worker_gone {
    my ($state) = @_;

    my $upid = $state->{upid};
    # Nothing to check against, and nothing that could still write a result.
    return 1 if !defined($upid) || $upid eq '';

    my $task = eval { PVE::Tools::upid_decode($upid, 1) };
    return 0 if !$task || !defined($task->{pid});

    my $localnode = eval { PVE::INotify::nodename() };
    return 0 if !defined($localnode) || ($task->{node} // '') ne $localnode;

    return PVE::ProcFSTools::check_process_running($task->{pid}, $task->{pstart}) ? 0 : 1;
}

# The same state, flattened into the `last_*` properties the API returns and the
# grids render. Keys with nothing behind them are left out rather than sent as
# null, so the schema stays honest about what is actually known.
sub last_run {
    my ($type, $id) = @_;

    my $state = load_state($type, $id);
    return {} if !$state;

    my $res = {};

    $res->{last_upid} = $state->{upid} if defined($state->{upid});
    $res->{last_note} = $state->{note} if defined($state->{note});

    my $reported = $state->{state};

    if (!grep { $_ eq $reported } @KNOWN_STATES) {
        # A state nobody wrote on purpose - a hand-edited or truncated file. Say
        # so instead of passing a value the schema does not allow up to the grid.
        $res->{last_note} = "unreadable state in the state file";
        $reported = 'unknown';
    } elsif ($reported eq 'running' && _worker_gone($state)) {
        $res->{last_note} = "the task ended without recording a result";
        $reported = 'unknown';
    }

    $res->{last_state} = $reported;

    for my $key (qw(started finished exit)) {
        next if !defined($state->{$key});
        next if $state->{$key} !~ m/\A-?\d+\z/;
        $res->{"last_$key"} = int($state->{$key});
    }

    return $res;
}

sub save_state {
    my ($type, $id, $state) = @_;

    my $raw = '';
    for my $key (sort keys %$state) {
        my $value = $state->{$key};
        next if !defined($value);
        # One record per line, so a note carrying a newline cannot forge a field.
        $value =~ s/[\r\n]+/ /g;
        $raw .= "$key=$value\n";
    }

    _ensure_base_dir();

    PVE::Tools::file_set_contents(state_file($type, $id), $raw);

    return;
}

# ── the node's settings ─────────────────────────────────────────────────────
#
# Offered on a node's tab only. A container knows nothing about when it should
# be updated, and a cluster-wide schedule would have to decide which node runs
# it - so the node that owns the targets owns its settings too.
#
# Two separate parallel switches on purpose - a manual run and a scheduled one
# are different situations and deserve their own answer. Both start OFF: a dozen
# dist-upgrades at once on one node is a decision, and a default that quietly
# saturates a host's disk is not one to make on somebody's behalf. Turning either
# on is a click, and it is remembered.
#
# The schedule is a systemd calendar event - the same syntax and the same parser
# Proxmox backup jobs use ("03:00", "mon..fri 02:30", "*/8:00"), so a time of day
# is expressible and "every N seconds" no longer has to stand in for one.
#
# `last_run` is written by the scheduler, never by the web interface, so saving
# settings cannot accidentally make a run look overdue (or not).

sub settings_file {
    my ($node) = @_;

    # Reuse script_file's validation of the node name, then move the prefix.
    my $file = script_file('node', $node);
    $file =~ s{/node-([^/]+)\.conf\z}{/settings-$1.conf};

    return $file;
}

our $DEFAULT_SNAPSHOT_KEEP = 3;

# One is the floor and not zero: keeping none would delete the snapshot the run
# had just taken, which is the opposite of what the setting is for.
our $MIN_SNAPSHOT_KEEP = 1;
our $MAX_SNAPSHOT_KEEP = 100;

# snapshot_before is the one switch here that starts ON. Every other one changes
# what a run DOES and so has to be asked for; this one only adds something to
# undo it with, and it does nothing at all where the storage cannot snapshot - so
# for once the cautious default and the useful one are the same value.
sub default_settings {
    return {
        parallel_manual => 0,
        timeout => $PVE::UpdateManager::Runner::DEFAULT_TIMEOUT,
        start_stopped => 0,
        snapshot_before => 1,
        snapshot_keep => $DEFAULT_SNAPSHOT_KEEP,
        schedule_enabled => 0,
        schedule_time => '03:00',
        schedule_parallel => 0,
        schedule_host => 0,
        schedule_vmids => '',
        last_run => 0,
    };
}

# The API's description of the settings, in ONE place. The node's endpoint and
# the datacenter-wide one both describe the same switches, and two copies of a
# minimum, a pattern or a sentence of documentation drift apart the first time
# one of them is corrected.
sub settings_schema {
    return {
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
        snapshot_before => {
            type => 'boolean',
            description => "Take a snapshot of a container before updating it. On by default,"
                . " because it is the one thing that makes a bad dist-upgrade undoable - and it"
                . " does nothing at all where the storage cannot snapshot, in which case the"
                . " container is updated exactly as it was before this setting existed.",
        },
        snapshot_keep => {
            type => 'integer',
            minimum => $MIN_SNAPSHOT_KEEP,
            maximum => $MAX_SNAPSHOT_KEEP,
            description => "How many of these snapshots to keep per container. The oldest ones"
                . " above this are removed after each run. Only snapshots this addon took are"
                . " ever touched.",
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
}

# The keys a datacenter-wide save may write: everything that means the same
# thing on every node.
#
# schedule_vmids is the one that does not, and it is why "apply to all nodes"
# cannot simply be a loop over this whole hash: a vmid lives on exactly one
# node, so broadcasting one node's list would point every other node at
# containers it does not have - and un-tick the ones it does.
#
# last_run is not here either: it belongs to the scheduler, like everywhere else.
our @PER_NODE_SETTINGS = qw(schedule_vmids last_run);

sub global_settings_schema {
    my $schema = settings_schema();

    delete $schema->{$_} for @PER_NODE_SETTINGS;

    return $schema;
}

sub load_settings {
    my ($node) = @_;

    my $res = default_settings();

    my $file = settings_file($node);
    return $res if !-f $file;

    my $raw = eval { PVE::Tools::file_get_contents($file, 8192) };
    if (!defined($raw)) {
        warn "pve-update-manager: cannot read the settings of node $node: $@";
        return $res;
    }

    for my $line (split(/\n/, $raw)) {
        next if $line !~ m/\A([a-z_]+)=(.*)\z/;
        my ($key, $value) = ($1, $2);
        next if !exists($res->{$key});

        if ($key eq 'timeout') {
            # Clamped rather than rejected: a settings file edited by hand into
            # nonsense should not disarm the one limit that stops a hung run.
            my $secs = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $secs = $PVE::UpdateManager::Runner::MIN_TIMEOUT
                if $secs < $PVE::UpdateManager::Runner::MIN_TIMEOUT;
            $secs = $PVE::UpdateManager::Runner::MAX_TIMEOUT
                if $secs > $PVE::UpdateManager::Runner::MAX_TIMEOUT;
            $res->{$key} = $secs;
        } elsif ($key eq 'snapshot_keep') {
            # Clamped rather than rejected, same reason as the timeout: a file
            # edited by hand into a 0 would delete the snapshot the run had just
            # taken, which is the opposite of what the setting is for.
            my $keep = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $keep = $MIN_SNAPSHOT_KEEP if $keep < $MIN_SNAPSHOT_KEEP;
            $keep = $MAX_SNAPSHOT_KEEP if $keep > $MAX_SNAPSHOT_KEEP;
            $res->{$key} = $keep;
        } elsif ($key eq 'schedule_vmids') {
            $res->{$key} = ($value =~ m/\A\d+(?:,\d+)*\z/) ? $value : '';
        } elsif ($key eq 'schedule_time') {
            # A calendar event nobody can parse would make the timer silently
            # never fire. Fall back to the default rather than to "never".
            $res->{$key} = parse_schedule_time($value) ? $value : $res->{$key};
        } else {
            $res->{$key} = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
        }
    }

    return $res;
}

sub _write_settings {
    my ($node, $settings) = @_;

    my $raw = '';
    for my $key (sort keys %{ default_settings() }) {
        $raw .= "$key=" . ($settings->{$key} // 0) . "\n";
    }

    _ensure_base_dir();

    PVE::Tools::file_set_contents(settings_file($node), $raw);

    return $settings;
}

sub save_settings {
    my ($node, $settings) = @_;

    # Merge FIRST, then validate. Every field of the API is optional, so a
    # request that only flips one switch carries nothing else - and validating
    # the raw input would reject it for values the caller never sent and the
    # stored settings already answer.
    #
    # last_run belongs to the scheduler. A save from the web interface keeps
    # whatever is on disk, so changing the time does not reset the clock - and
    # cannot be used to force a run either.
    my $current = load_settings($node);
    my $merged = { %$current, %$settings };
    $merged->{last_run} = $current->{last_run};

    # The one exception: switching a schedule on for the first time starts its
    # clock now. Due-ness is measured from last_run, so leaving it at 0 would
    # measure from 1970 and fire the moment the box is ticked - which is not what
    # "every day at 03:00" says, and not what anyone expects to happen while they
    # are still looking at the dialog.
    $merged->{last_run} = time()
        if $merged->{schedule_enabled} && !$current->{schedule_enabled} && !$current->{last_run};

    my $vmids = $merged->{schedule_vmids};
    die "invalid vmid list '$vmids'\n"
        if defined($vmids) && length($vmids) && $vmids !~ m/\A\d+(?:,\d+)*\z/;

    die "invalid schedule '$merged->{schedule_time}'\n"
        if !parse_schedule_time($merged->{schedule_time});

    my $secs = $merged->{timeout};
    die "invalid timeout '$secs' - must be between $PVE::UpdateManager::Runner::MIN_TIMEOUT"
        . " and $PVE::UpdateManager::Runner::MAX_TIMEOUT seconds\n"
        if !defined($secs)
        || $secs !~ m/\A\d+\z/
        || $secs < $PVE::UpdateManager::Runner::MIN_TIMEOUT
        || $secs > $PVE::UpdateManager::Runner::MAX_TIMEOUT;

    my $keep = $merged->{snapshot_keep};
    die "invalid snapshot count '$keep' - must be between $MIN_SNAPSHOT_KEEP"
        . " and $MAX_SNAPSHOT_KEEP\n"
        if !defined($keep)
        || $keep !~ m/\A\d+\z/
        || $keep < $MIN_SNAPSHOT_KEEP
        || $keep > $MAX_SNAPSHOT_KEEP;

    return _write_settings($node, $merged);
}

sub mark_schedule_run {
    my ($node, $when) = @_;

    my $settings = load_settings($node);
    $settings->{last_run} = $when // time();

    return _write_settings($node, $settings);
}

# Wrapped so the one place that knows about PVE::CalendarEvent is here, and so a
# rejected event is a false rather than an exception at every call site.
sub parse_schedule_time {
    my ($spec) = @_;

    return undef if !defined($spec) || $spec !~ m/\S/;

    my $parsed = eval { PVE::CalendarEvent::parse_calendar_event($spec) };

    return $@ ? undef : $parsed;
}

# When the schedule would next fire after $since. Undef when it never would.
sub next_schedule_run {
    my ($settings, $since) = @_;

    my $event = parse_schedule_time($settings->{schedule_time})
        or return undef;

    $since //= $settings->{last_run} || time();

    my $next = eval { PVE::CalendarEvent::compute_next_event($event, $since) };

    return $@ ? undef : $next;
}

# What a run does, taken from the node's settings, in ONE place.
#
# There are three callers - the node's run endpoint, a container's, and the
# timer - and an option added to two of them is a scheduled run that quietly
# behaves differently from the manual one somebody tested with. That has
# happened once already, which is why this exists rather than three literals.
sub run_opts {
    my ($settings) = @_;

    return {
        start_stopped => $settings->{start_stopped},
        snapshot_before => $settings->{snapshot_before},
        snapshot_keep => $settings->{snapshot_keep},
    };
}

# Is a scheduled run due? Kept here rather than in the timer's script so the API
# can report the same answer the timer will act on.
sub schedule_is_due {
    my ($settings, $now) = @_;

    return 0 if !$settings->{schedule_enabled};

    $now //= time();

    # Measured from the last run, so a node that was switched off through 03:00
    # still updates once it is back - and one that already ran at 03:00 does not
    # run again at 03:01.
    my $next = next_schedule_run($settings, $settings->{last_run} || 0);

    return 0 if !defined($next);

    return $now >= $next ? 1 : 0;
}

# Is any of these targets mid-run right now?
#
# The timer asks every few minutes and a scheduled run can outlive its own
# schedule - so without this a second run would be started on top of the first,
# two apt processes fighting over one dpkg lock. The per-target state already
# knows, including the case where a previous worker was killed and only looks
# busy.
sub any_target_running {
    my ($targets) = @_;

    for my $target (@$targets) {
        return $target if target_is_running($target->{type}, $target->{id});
    }

    return undef;
}

sub target_is_running {
    my ($type, $id) = @_;

    # Deliberately last_run and not the raw state file: that is where a worker
    # which was killed rather than finished stops counting as busy, so a crash
    # cannot make a container un-updatable until somebody deletes a file.
    return (last_run($type, $id)->{last_state} // '') eq 'running' ? 1 : 0;
}

# Serialises "is this target busy?" with "mark it busy", which otherwise are two
# steps with a gap - and two clicks on Update land in that gap easily. Measured
# before this existed: two workers ran apt in the same container at the same
# time, and the second one's UPID overwrote the first one's in the row.
#
# The lock is node-local on purpose. A run only ever happens on the node that
# owns the target (every run endpoint is proxied there), so /run is the right
# scope - and it is a real flock, unlike anything /etc/pve could offer.
sub lock_target {
    my ($type, $id, $code) = @_;

    # Reuses the id validation of script_file: a lock path is a path too.
    my $file = script_file($type, $id);
    $file =~ s|\A.*/||;
    $file =~ s|\.conf\z||;

    return PVE::Tools::lock_file("/run/lock/pve-update-manager-$file.lck", 10, $code);
}

1;
