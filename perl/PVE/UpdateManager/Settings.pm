package PVE::UpdateManager::Settings;

# the node's settings and the schedule: defaults, the API schema, reading and validating, when a scheduled run is due, and the options every run is given.
#
# Split out of Config.pm (#21), which was 1705 lines. What stays there is the
# storage under /etc/pve that everything else builds on - the base directory,
# the scripts, the update order and the per-target state - and the target lock.

use strict;
use warnings;

use PVE::CalendarEvent;
use PVE::Tools;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::Versions;
use PVE::UpdateManager::SecSettings;

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
    my $file = PVE::UpdateManager::Config::script_file('node', $node);
    $file =~ s{/node-([^/]+)\.conf\z}{/settings-$1.conf};

    return $file;
}

our $DEFAULT_SNAPSHOT_KEEP = 3;

# How many targets of one parallel wave may run at once. 0 is no cap, which is
# what a parallel run did before the setting existed, so an upgrade changes
# nothing until somebody sets a number. The ceiling is only there so a typo
# cannot be stored; a wave never holds more targets than the node has.
our $MAX_PARALLEL = 100;

# One is the floor and not zero: keeping none would delete the snapshot the run
# had just taken, which is the opposite of what the setting is for.
our $MIN_SNAPSHOT_KEEP = 1;
our $MAX_SNAPSHOT_KEEP = 100;

# snapshot_before, notify_failure and rollback_remove_newer are the three
# switches here that start ON. Every other one changes what a run DOES and so
# has to be asked for; these three do not. snapshot_before only adds something
# to undo a run with, and it does nothing at all where the storage cannot
# snapshot. notify_failure only says out loud what already happened - and the
# run it reports on is an unattended one at 03:00, where the alternative to a
# notification is nobody finding out. rollback_remove_newer does nothing unless
# rollback_on_failure is on, which is the switch that already says "throw away
# everything since the snapshot"; all it decides is whether that instruction is
# carried out or refused because something else snapshotted the container in
# the meantime. So for once the cautious default and the useful one are the
# same value.
sub default_settings {
    return {
        # The security scan's keys (#41) live in SecSettings.pm and are part of
        # the same file, schema and save.
        %{ PVE::UpdateManager::SecSettings::defaults() },
        parallel_manual => 0,
        parallel_manual_max => 0,
        timeout => $PVE::UpdateManager::Runner::DEFAULT_TIMEOUT,
        start_stopped => 0,
        reboot_vms => 0,
        snapshot_before => 1,
        snapshot_keep => $DEFAULT_SNAPSHOT_KEEP,
        snapshot_shutdown => 0,
        rollback_on_failure => 0,
        rollback_remove_newer => 1,
        notify_failure => 1,
        script_versions => $PVE::UpdateManager::Versions::DEFAULT_SCRIPT_VERSIONS,
        run_logs => $PVE::UpdateManager::Logs::DEFAULT_RUN_LOGS,
        schedule_enabled => 0,
        schedule_time => '03:00',
        schedule_parallel => 0,
        schedule_parallel_max => 0,
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
        %{ PVE::UpdateManager::SecSettings::schema() },
        parallel_manual => {
            type => 'boolean',
            description => "Start all targets at once when Update Selected is pressed.",
        },
        parallel_manual_max => {
            type => 'integer',
            minimum => 0,
            maximum => $MAX_PARALLEL,
            description => "Manual parallel runs: at most this many targets at once. 0 = no limit.",
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
            description => "Start a stopped container or VM for its update and shut it down"
                . " again afterwards. Off by default: a stopped guest is skipped, because"
                . " starting one runs its services for as long as the update takes. A VM"
                . " counts as started once its QEMU guest agent answers; one whose agent"
                . " does not answer is shut down again and reported as failed.",
        },
        reboot_vms => {
            type => 'boolean',
            description => "Reboot a VM after a successful update when the update left"
                . " /var/run/reboot-required behind (a new kernel, a new libc), and wait"
                . " for its guest agent before the VM counts as updated. Off by default."
                . " VMs only, and only those that were running before the update - one that"
                . " was started for it is shut down again and boots the new kernel next"
                . " time. A VM that does not come back from the reboot is a failed target.",
        },
        snapshot_before => {
            type => 'boolean',
            description => "Take a snapshot of a container or VM before updating it. On by"
                . " default, because it is the one thing that makes a bad dist-upgrade"
                . " undoable - and it does nothing at all where the storage cannot snapshot,"
                . " in which case the guest is updated exactly as it was before this setting"
                . " existed. A VM snapshot holds its disks only, never its memory.",
        },
        snapshot_keep => {
            type => 'integer',
            minimum => $MIN_SNAPSHOT_KEEP,
            maximum => $MAX_SNAPSHOT_KEEP,
            description => "How many of these snapshots to keep per guest. The oldest ones"
                . " above this are removed after each run. Only snapshots this addon took are"
                . " ever touched.",
        },
        snapshot_shutdown => {
            type => 'boolean',
            description => "Shut a running container or VM down before its snapshot is taken"
                . " and start it again afterwards. Off by default. Neither an LXC snapshot nor"
                . " the disk-only VM snapshot taken here carries memory, so a running guest is"
                . " snapshotted as if it had lost power, and a database mid-transaction is"
                . " caught that way (a VM with its guest agent has its filesystems frozen for"
                . " the moment, which does not reach into a database). Stopping it first is"
                . " the only way to a consistent one, and it costs the downtime of a shutdown"
                . " and a start.",
        },
        rollback_on_failure => {
            type => 'boolean',
            description => "Roll a container or VM back to the snapshot this run took when"
                . " its update fails. Off by default, and not a small switch: a rollback"
                . " throws away everything that happened since the snapshot, not only what"
                . " the update did - anything a service wrote in the meantime goes with it."
                . " PVE stops the guest to roll it back; one that was running is started"
                . " again afterwards (a VM boots cold, its snapshot has no memory). Only a"
                . " snapshot this addon took in this run is ever rolled back to.",
        },
        rollback_remove_newer => {
            type => 'boolean',
            description => "Let a rollback remove snapshots that are newer than the one it"
                . " goes back to, when the storage refuses the rollback because of them. On"
                . " by default, and it only ever applies while rollback_on_failure is on."
                . " ZFS, classic LVM and qcow2 chains refuse to roll back while a newer"
                . " snapshot exists - one an auto-snapshot tool took during the update, for"
                . " instance - and there is no force to pass on: the rollback destroys those"
                . " snapshots either way, so the only way through is to remove them first."
                . " This is the one case in which a snapshot the Update Manager did not take"
                . " is removed, and the run names every one of them in its log. Switched off,"
                . " such a rollback fails and the container stays on the failed update.",
        },
        notify_failure => {
            type => 'boolean',
            description => "Send a notification when a run had a target fail. On by default."
                . " It goes out through Proxmox' own notification system, so it lands wherever"
                . " this node already sends its backup and package notifications and needs no"
                . " address of its own here; the notification targets and matchers under"
                . " Datacenter -> Notifications decide where that is. One notification per"
                . " run, once the whole run is over, listing the targets that failed with"
                . " their exit code and the time they finished. Nothing is sent for a run in"
                . " which everything worked, and a target that was skipped is not a failure.",
        },
        run_logs => {
            type => 'integer',
            minimum => $PVE::UpdateManager::Logs::MIN_RUN_LOGS,
            maximum => $PVE::UpdateManager::Logs::MAX_RUN_LOGS,
            description => "How many logs of past runs to keep per target. Each run writes"
                . " one, and the oldest above this are removed after it. 0 keeps none."
                . " They are kept on the node that ran them, under"
                . " /var/lib/pve-update-manager/logs, because a run log can be far larger"
                . " than the 1 MiB a file in /etc/pve may be - and because Proxmox' own task"
                . " log stays on disk but stops being reachable once its entry falls out of"
                . " the task index.",
        },
        script_versions => {
            type => 'integer',
            minimum => $PVE::UpdateManager::Versions::MIN_SCRIPT_VERSIONS,
            maximum => $PVE::UpdateManager::Versions::MAX_SCRIPT_VERSIONS,
            description => "How many saved versions of a target's update script to keep."
                . " Every save that changes something writes one; the oldest above this are"
                . " removed. The newest is what is stored now, so 3 means the current text"
                . " and the two before it.",
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
        schedule_parallel_max => {
            type => 'integer',
            minimum => 0,
            maximum => $MAX_PARALLEL,
            description => "Scheduled parallel runs: at most this many targets at once. 0 = no limit.",
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
our @PER_NODE_SETTINGS = (qw(schedule_vmids last_run), @PVE::UpdateManager::SecSettings::PER_NODE);

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

    # 16 KiB: the file holds two vmid lists of up to 4 KiB each and a package
    # pattern list of up to 1 KiB since the security scan (#41). At the old 8 KiB
    # a full file would have made this die, and the fallback below would then
    # silently replace every setting with its default.
    my $raw = eval { PVE::Tools::file_get_contents($file, 16384) };
    if (!defined($raw)) {
        warn "pve-update-manager: cannot read the settings of node $node: $@";
        return $res;
    }

    for my $line (split(/\n/, $raw)) {
        next if $line !~ m/\A([a-z_]+)=(.*)\z/;
        my ($key, $value) = ($1, $2);
        next if !exists($res->{$key});

        if (PVE::UpdateManager::SecSettings::handles($key)) {
            $res->{$key} = PVE::UpdateManager::SecSettings::load_value($key, $value);
        } elsif ($key eq 'timeout') {
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
        } elsif ($key eq 'run_logs') {
            # Clamped rather than rejected, like the counts above. Zero is a
            # legitimate answer here and needs no floor of its own.
            $res->{$key} = PVE::UpdateManager::Logs::log_retention($value);
        } elsif ($key eq 'script_versions') {
            # Clamped rather than rejected, like the two above: a hand-edited 0
            # would throw away the version of the save being made.
            my $keep = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $keep = $PVE::UpdateManager::Versions::MIN_SCRIPT_VERSIONS if $keep < $PVE::UpdateManager::Versions::MIN_SCRIPT_VERSIONS;
            $keep = $PVE::UpdateManager::Versions::MAX_SCRIPT_VERSIONS if $keep > $PVE::UpdateManager::Versions::MAX_SCRIPT_VERSIONS;
            $res->{$key} = $keep;
        } elsif ($key eq 'parallel_manual_max' || $key eq 'schedule_parallel_max') {
            # Clamped, like the counts above. Above the ceiling means "more than
            # any wave holds", which the ceiling says just as well.
            my $max = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $max = $MAX_PARALLEL if $max > $MAX_PARALLEL;
            $res->{$key} = $max;
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

    PVE::UpdateManager::Config::_ensure_base_dir();

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

    my $versions = $merged->{script_versions};
    die "invalid script version count '$versions' - must be between $PVE::UpdateManager::Versions::MIN_SCRIPT_VERSIONS"
        . " and $PVE::UpdateManager::Versions::MAX_SCRIPT_VERSIONS\n"
        if !defined($versions)
        || $versions !~ m/\A\d+\z/
        || $versions < $PVE::UpdateManager::Versions::MIN_SCRIPT_VERSIONS
        || $versions > $PVE::UpdateManager::Versions::MAX_SCRIPT_VERSIONS;

    for my $key (qw(parallel_manual_max schedule_parallel_max)) {
        my $max = $merged->{$key};
        die "invalid $key '" . ($max // '') . "' - must be between 0 and $MAX_PARALLEL\n"
            if !defined($max) || $max !~ m/\A\d+\z/ || $max > $MAX_PARALLEL;
    }

    PVE::UpdateManager::SecSettings::validate($merged);

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
    my ($settings, $parallel, $parallel_max) = @_;

    return {
        start_stopped => $settings->{start_stopped},
        reboot_vms => $settings->{reboot_vms},
        snapshot_before => $settings->{snapshot_before},
        snapshot_keep => $settings->{snapshot_keep},
        snapshot_shutdown => $settings->{snapshot_shutdown},
        rollback_on_failure => $settings->{rollback_on_failure},
        rollback_remove_newer => $settings->{rollback_remove_newer},
        notify_failure => $settings->{notify_failure},
        # Carried into the run rather than read again per target: forty targets
        # would otherwise be forty reads of the same settings file, and a setting
        # changed mid-run would apply to half the batch.
        run_logs => $settings->{run_logs},
        # #73: with the security check on, every run is checked afterwards for the
        # security updates that were pending before it; NOT FIXED is notified
        # through the security notification, at most every cooldown per node.
        security_verify => $settings->{security_scan} ? 1 : 0,
        security_notify => $settings->{security_notify} ? 1 : 0,
        security_unfixed_cooldown => $settings->{security_unfixed_cooldown},
        # An argument rather than a settings key, because there is no single key
        # to read: a manual run and a scheduled one have separate parallel
        # switches on purpose, and a single container's run has no list to spread
        # out at all. Passing it makes every caller answer the question instead
        # of one of them quietly inheriting the other one's answer.
        parallel => $parallel ? 1 : 0,
        # The cap travels with its switch for the same reason: each of the two
        # switches has its own number, and a caller that passes the switch has to
        # pass the number that belongs to it.
        parallel_max => $parallel ? int($parallel_max // 0) : 0,
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

1;
