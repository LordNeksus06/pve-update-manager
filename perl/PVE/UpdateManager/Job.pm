package PVE::UpdateManager::Job;

# One update run over one or more targets, written for the Proxmox task log.
#
# Both the single-container button and the "update selected" button on the node
# end up here, so a run of one and a run of twelve are logged the same way: a
# banner per target, the raw command output underneath, a one-line verdict, and
# a summary at the end that can be read without scrolling back.
#
# A run walks its targets in waves - one wave per update-order number, which the
# log and the web interface both call a POSITION. A serial run is the case where
# every wave holds one target; a parallel run starts everything sharing a number
# at once and does not begin the next number until the last of them is done. Both
# shapes are ONE task either way, which is what lets the summary - and the
# notification behind it - speak for the whole run rather than for a target.
#
# A failing target does not stop the batch - the remaining ones still run, and
# the job as a whole fails at the end. Stopping halfway would leave the operator
# guessing which containers were even attempted.
#
# Every target's outcome is also written to its state file as it happens, which
# is what puts a live status into each row of the grids and lets the Logs window
# find the right task.

use strict;
use warnings;

use IO::Handle;
use POSIX ();

use PVE::LXC;
use PVE::LXC::Config;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Notify;
use PVE::UpdateManager::Runner;

# A worker's STDOUT is the task log file itself - fork_worker points it there
# with PVE::UPID::open_log and nothing in between counts bytes. Proxmox never
# rotates or deletes those files either (logs from weeks ago are still on the
# test node), so a script that prints in a loop writes straight into /var/log
# on the node's root filesystem until it is full. Measured on PVE 9.2: 103 MB
# in 3 seconds, and the 1 hour default timeout is no protection at that rate.
#
# Hence a ceiling on what one target may contribute. It cuts the log, not the
# run: a dist-upgrade that has already started is worse to abandon than to stop
# describing, and a real one stays far below this - a few hundred kilobytes.
#
# PER TARGET, and a parallel position of twelve therefore has twelve of these in
# ONE task log. The bytes on the disk are the same either way - a parallel run
# used to be twelve tasks with twelve logs - and Proxmox' viewer reads a log by
# line range rather than whole, so what changed is which file it is in and not
# how much of the node's root filesystem it can take.
#
# Known limit: this counts whole lines, and run_command hands them over only
# once it has one. Output that never breaks a line therefore sits in the
# worker's memory until it does - measured at 333 MB of RSS for a 200 MB blob.
# It takes output with no newline, no carriage return and no backspace in it at
# all, because run_command splits on all three, so a progress bar does not do
# it but `cat` of a large binary would. Fixing it means piping the command
# through something like `fold`, and a pipeline in POSIX sh reports the exit
# status of its last member - trading a correct exit code for an exotic memory
# case is the worse deal, so this is documented rather than fixed.
our $MAX_OUTPUT_BYTES = 8 * 1024 * 1024;

# What every line this job writes is prefixed with.
#
# Empty everywhere except inside a child that is updating one target of a
# parallel wave, where several processes write into the same task log at the same
# time and a line without its target's name in front of it belongs to nobody.
# Set once in the child rather than threaded through run_one and the runner,
# which would mean a logfunc argument on every function between here and
# run_command.
our $LINE_PREFIX = '';

# Where one target's own output is collected while it runs, so it can be kept
# beside its script afterwards.
#
# Here rather than in the runner's logfunc because the logfunc only sees what the
# COMMAND printed: "taking snapshot ... before the update", "container is stopped
# - starting it for the update" and every warning around the run go through _log
# directly, and a stored log missing those is a log that cannot explain itself.
#
# An arrayref while a target is being recorded, undef otherwise. Set with `local`
# in run_one, which is what makes it end at every one of that function's exits
# without a line at each of them - and what keeps a forked child of a parallel
# wave collecting its own target and nothing else.
#
# The prefix is deliberately NOT stored: a file about CT 101 does not need
# "[CT 101]" in front of every line.
our $CAPTURE;

sub _log {
    my ($msg) = @_;

    push @$CAPTURE, $msg if $CAPTURE;

    print "$LINE_PREFIX$msg\n";
}

# Terminal control sequences, taken out of what a script prints.
#
# The task viewer cannot render them: Proxmox' LogView does
# `Ext.htmlEncode(line.t)` and joins the lines with <br>, so an escape sequence
# arrives as visible text and a coloured line reads "[0;31m!! Fehler". Colour
# would need a change to Proxmox' own JavaScript, which this addon does not
# make - so the next best thing is that the words are readable.
#
# CSI first (colour, cursor moves), then OSC with either terminator, then the
# two-character escapes. A lone ESC that is none of those is left alone rather
# than guessed at.
our $ANSI_RE = qr/
    \e \[ [0-9;:<=>?]* [\x20-\x2f]* [\x40-\x7e]   # CSI ... final byte
  | \e \] .*? (?: \a | \e \\ )                    # OSC ... BEL or ST
  | \e [\x40-\x5a\x5c-\x5f]                       # two-character escapes
/x;

sub strip_ansi {
    my ($line) = @_;

    return $line if !defined($line);

    $line =~ s/$ANSI_RE//g;

    return $line;
}

# Returns (logfunc, report). The logfunc is what the runner writes command
# output to; report tells run_one afterwards whether anything was dropped, so
# the summary and the row can say so rather than leaving a log that simply
# stops mid-sentence.
sub _capped_logger {
    my ($limit) = @_;

    my $written = 0;
    my $capped = 0;
    my $dropped = 0;

    my $logfunc = sub {
        my ($line) = @_;

        # Before the counting, so the limit counts what is written rather than
        # what was sent.
        $line = strip_ansi($line);

        if (!$capped) {
            $written += length($line) + 1;

            if ($written <= $limit) {
                _log($line);
                return;
            }

            # This line is over the edge, so it is dropped like the ones after
            # it - counted below, not here, which is where an off-by-one lived
            # while "dropped" doubled as both the flag and the counter.
            $capped = 1;
            _log(
                sprintf(
                    '... output limit of %d MiB reached - the script keeps running,'
                        . ' but the rest of its output is not written to this log',
                    $limit / 1024 / 1024,
                ),
            );
        }

        $dropped++;
    };

    return ($logfunc, sub { return $dropped });
}

sub _describe {
    my ($target) = @_;

    if ($target->{type} eq 'node') {
        return "Host $target->{id}";
    }

    my $name = $target->{name};
    return defined($name) && length($name) ? "CT $target->{id} ($name)" : "CT $target->{id}";
}

# The same target, short enough to sit in front of every line of its output.
# Without the hostname on purpose: a container called
# "nextcloud-production-frontend" would push the output of every line it prints
# off the right of the task viewer.
sub _short_desc {
    my ($target) = @_;

    return $target->{type} eq 'node' ? "Host $target->{id}" : "CT $target->{id}";
}

# The worker's own UPID, so a row can link to the log of the run that set its
# state. PVE::RESTEnvironment::fork_worker renames the child to "task <UPID>"
# and exposes it nowhere else - reading $0 back is the only way in, and an
# unrecognised $0 simply means the row gets no log link.
sub current_upid {
    return $1 if ($0 // '') =~ m/\Atask (UPID:\S+)\z/;
    return undef;
}

sub _set_state {
    my ($target, $state) = @_;

    eval { PVE::UpdateManager::Config::save_state($target->{type}, $target->{id}, $state) };
    warn "unable to record the state of $target->{type} $target->{id}: $@" if $@;

    return;
}

sub _human_time {
    my ($epoch) = @_;

    return POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime($epoch // time()));
}

# One target's own log of one run, written beside its script.
#
# Self-describing on purpose: a file somebody finds in six months has to say what
# it is the log OF without a database next to it - which target, when, how it
# went, and which task it was, so the task log can still be opened while it is
# still reachable.
#
# Never dies and never lets its own failure become the run's. The update happened
# either way; a disk that is full is worth a line in the syslog and not a target
# reported as failed for something that has nothing to do with it.
sub _store_log {
    my ($target, $upid, $facts, $rc, $note, $lines, $opts) = @_;

    my $keep = $opts->{run_logs};
    return if !defined($keep) || $keep < 1;

    my $state = !defined($rc) ? 'SKIPPED' : $rc == 0 ? 'OK' : 'FAILED';

    my $header = join(
        "\n",
        '=== pve-update-manager ===',
        'target:   ' . _describe($target),
        # Read as a time, not as a filename: the dashes in the name are there
        # because a colon in a path is a bad idea, and the header has no such
        # excuse. Same format Proxmox' own notifications render a timestamp in.
        'started:  ' . _human_time($facts->{started}),
        'finished: ' . _human_time($facts->{finished}),
        'result:   ' . $state . (defined($note) && length($note) ? " ($note)" : ''),
        'task:     ' . (defined($upid) ? $upid : '-'),
        '',
        '',
    );

    eval {
        PVE::UpdateManager::Config::save_log(
            $target->{type},
            $target->{id},
            $header . join("\n", @{ $lines // [] }) . "\n",
            $keep,
            $facts->{finished},
        );
    };

    warn "unable to keep the run log of $target->{type} $target->{id}: $@" if $@;

    return;
}

our $NO_SCRIPT_NOTE = 'no update script stored';

# Records "there is nothing stored to run here" on the target's own row.
#
# Called from two places on purpose. The worker calls it while walking a list of
# targets; the container's run endpoint calls it before it starts a worker at
# all, because forty containers pressed at once used to answer with forty error
# lines in one dialog for a case the confirmation had just called a skip. Both
# routes have to leave the SAME row behind - one answering in the grid and the
# other in a popup is two answers to one question.
#
# Returns the note, so a caller can report it in the same words.
sub skip_no_script {
    my ($target, $upid, $started) = @_;

    my $now = time();

    _set_state(
        $target,
        {
            state => 'skipped', upid => $upid, started => $started // $now,
            finished => $now, note => $NO_SCRIPT_NOTE,
        },
    );

    return $NO_SCRIPT_NOTE;
}

# Returns (exit_code, note). exit_code 0 means the script ran and succeeded;
# `undef` means the target was skipped and never ran, which the summary reports
# separately from a failure so "stopped" does not look like "broken".
sub run_one {
    my ($target, $timeout, $upid, $opts) = @_;

    $opts //= {};
    my $started = time();

    # The facts behind the note, one field each.
    #
    # The note is a sentence, for the row and the task log. A sentence is the
    # wrong shape for anything that has to say WHICH snapshot, or WHETHER it was
    # rolled back, on a line of its own - which is what the failure notification
    # is asked for. So the pieces are collected here as they happen and handed
    # back beside the note rather than parsed back out of it: a report that
    # regexes its own log is a report that breaks the day the wording improves.
    my $facts = { started => $started };

    # What this target printed, kept for the log below. Local, so it ends at every
    # one of this function's exits by itself.
    my @captured;
    local $CAPTURE = ($opts->{run_logs} // 0) > 0 ? \@captured : undef;

    # Every exit from run_one goes through this, so no caller has to guess when a
    # target stopped or how long it took - including the exits that stop before
    # anything ran, where the answer is "no time at all" rather than "unknown".
    #
    # It is also the one place that writes this target's log, for the same reason:
    # eleven exits mean eleven chances to forget, and a run that reports an
    # outcome without leaving the log of it is the one this feature exists to
    # prevent.
    my $stop = sub {
        my ($rc, $note) = @_;

        $facts->{finished} //= time();
        $facts->{elapsed} //= $facts->{finished} - $started;

        _store_log($target, $upid, $facts, $rc, $note, \@captured, $opts);

        return $facts;
    };

    my ($script) = PVE::UpdateManager::Config::load_script($target->{type}, $target->{id});
    if (!defined($script) || $script !~ m/\S/) {
        my $skip = skip_no_script($target, $upid, $started);
                return (undef, $skip, $stop->(undef, $skip));
    }

    # A container whose config is not on this node is not ours to update. It has
    # been migrated away since the list was built, or the vmid names a VM, or a
    # scheduled list still carries one that has moved - and the scripts live in
    # /etc/pve, which is the same everywhere, so the stored commands are found
    # either way and nothing further down would notice.
    #
    # Without this the answer is check_running()'s "container is not running":
    # true, because it looks for a cgroup this node does not have, and wrong,
    # because the container is running perfectly well somewhere else. On a
    # schedule that is the same misleading line every night, and starting it -
    # which is what the note invites - fails for a reason that names no cause.
    my $conf = $target->{type} eq 'lxc'
        ? eval { PVE::LXC::Config->load_config($target->{id}) }
        : undef;

    if ($target->{type} eq 'lxc' && !$conf) {
        my $note = 'not a container on this node';
        _set_state(
            $target,
            {
                state => 'skipped', upid => $upid, started => $started,
                finished => time(), note => $note,
            },
        );
        return (undef, $note, $stop->(undef, $note));
    }

    # A template is not a container that happens to be switched off. PVE refuses
    # to start one ("you can't start a CT if it's a template") and refuses to
    # snapshot one ("you can't take a snapshot if it's a template"), both read
    # off its own source - so with 'start stopped containers' on, a template in
    # the selection came out as a FAILED target rather than as one there was
    # never anything to do for. Select All picks them up, which is how it gets
    # into a run in the first place.
    if ($conf && PVE::LXC::Config->is_template($conf)) {
        my $note = 'this is a template, not a container';
        _set_state(
            $target,
            {
                state => 'skipped', upid => $upid, started => $started,
                finished => time(), note => $note,
            },
        );
        return (undef, $note, $stop->(undef, $note));
    }

    # A stopped container is skipped, and that stays the default: starting one
    # somebody deliberately stopped runs its services and its cron for as long
    # as the update takes, which is not a decision an update tool gets to make
    # on its own. The node's settings are where it can be granted.
    my $stopped = $target->{type} eq 'lxc' && !PVE::LXC::check_running($target->{id});

    if ($stopped && !$opts->{start_stopped}) {
        _set_state(
            $target,
            {
                state => 'skipped', upid => $upid, started => $started,
                finished => time(), note => 'container is not running',
            },
        );
        return (undef, 'container is not running', $stop->(undef, 'container is not running'));
    }

    # Written before the run, not after: this is what makes the grid show a
    # spinner on the row while apt is still working. Claiming it under the lock
    # is what stops a second run from starting on top of this one - two apt
    # processes in one container fight over the dpkg lock, and the row can only
    # point at one task log.
    my $busy;
    eval {
        PVE::UpdateManager::Config::lock_target(
            $target->{type},
            $target->{id},
            sub {
                if (PVE::UpdateManager::Config::target_is_running($target->{type}, $target->{id})) {
                    $busy = 1;
                    return;
                }
                _set_state($target, { state => 'running', upid => $upid, started => $started });
            },
        );
        1;
    } or do {
        # A lock we cannot take must not silently turn into a run we cannot
        # account for. Refusing is the safe half of the choice.
        $busy = 1;
    };

    # Note what is NOT done here: no state is written. The other task owns this
    # row and is still running in it - recording our own "skipped" on top would
    # replace a live spinner with a finished-looking result and point the row's
    # log link at the task that did nothing.
    if ($busy) {
        return (
                    undef,
                    'already being updated by another task',
                    $stop->(undef, 'already being updated by another task'),
                );
    }

    my ($logfunc, $report) = _capped_logger($MAX_OUTPUT_BYTES);

    # ── the rollback point ──────────────────────────────────────────────────
    #
    # Before the config lock below, not after: snapshot_create takes its own
    # lock and PVE refuses one while another is held, so the guard would defeat
    # the thing it is guarding. Before the container is started, too, when it
    # was found stopped - the state somebody left it in is the cleaner thing to
    # roll back to.
    #
    # Only where the storage really can. Where it cannot the run goes ahead
    # exactly as it did before this setting existed: a container on a directory
    # storage is not one to refuse to update.
    # Asked before the snapshot and not only by lock_guest below: a container
    # whose nightly backup overlaps the update window is skipped every single
    # run, and snapshotting it first would leave one snapshot per attempt behind
    # - which the pruning below cannot clear either, because removing a snapshot
    # takes a config lock too and that is exactly what is not available.
    #
    # A check-then-act, deliberately. lock_guest stays the real guard; this only
    # keeps the common case from paying for a snapshot nobody can use.
    my $foreign_lock = $target->{type} eq 'lxc'
        ? eval { PVE::LXC::Config->load_config($target->{id})->{lock} }
        : undef;

    # A 'snapshot-delete' lock nobody has touched for ten minutes is not another
    # task holding the container, it is the wreck of an earlier run of ours -
    # and skipping it means skipping this container for good. Repaired here so
    # the next update is what un-sticks it, rather than a manual `pct unlock`.
    if (defined($foreign_lock)
        && $foreign_lock eq $PVE::UpdateManager::Runner::SNAPSHOT_DELETE_LOCK) {

        my $wedged = PVE::UpdateManager::Runner::stale_delete_wedge($target->{id});
        if (defined($wedged)) {
            _log("CT $target->{id} is locked by a snapshot removal an earlier run"
                . " did not finish - repairing it before the update");
            PVE::UpdateManager::Runner::_repair_stuck_delete($target->{id}, $wedged, $logfunc);
            $foreign_lock = eval { PVE::LXC::Config->load_config($target->{id})->{lock} };
        }
    }

    if (defined($foreign_lock) && length($foreign_lock)) {
        my $note = "another task holds the lock ($foreign_lock)";

        # ... unless it is ours and nobody has touched the container since. A
        # worker that was killed never reaches unlock_guest, and the row would
        # otherwise say the same thing every night without ever saying what to
        # do about it. The lock is left alone on purpose - see stale_own_lock.
        $note .= " - nothing has touched this container in "
            . int($PVE::UpdateManager::Runner::STALE_WEDGE_SECONDS / 60)
            . " minutes, so this may be left over from an update that was"
            . " interrupted; 'pct unlock $target->{id}' clears it"
            if PVE::UpdateManager::Runner::stale_own_lock($target->{id});

        _set_state(
            $target,
            {
                state => 'skipped', upid => $upid, started => $started,
                finished => time(), note => $note,
            },
        );
        return (undef, $note, $stop->(undef, $note));
    }

    my $snapshot;

    # What a failed removal left behind that could not be repaired. It belongs
    # in the row and not only in the log: a container that is still locked will
    # refuse its next update, its next backup and its next start, and nobody
    # reads the log of a run that reported success.
    my $stuck = [];

    # Every exit from here on has to prune, not only the one at the bottom. A run
    # that snapshots and then returns early - the lock taken in the gap above,
    # a container that will not start - would otherwise add one snapshot per
    # attempt and never drop any, and snapshot_keep would quietly mean nothing.
    my $prune = sub {
        return if !defined($snapshot);

        # The count is spelled out rather than left to prune_snapshots' own
        # floor of one: a caller that asked for a snapshot and forgot to say how
        # many to keep would otherwise lose every earlier one on the first run.
        (undef, $stuck) = PVE::UpdateManager::Runner::prune_snapshots(
            $target->{id},
            $opts->{snapshot_keep} // $PVE::UpdateManager::Config::DEFAULT_SNAPSHOT_KEEP,
            $logfunc,
        );
    };

    if ($target->{type} eq 'lxc' && $opts->{snapshot_before}) {
        if (!PVE::UpdateManager::Runner::can_snapshot($target->{id})) {
            _log('the storage of this container cannot snapshot - updating without one');
        } else {
            # A cold snapshot, if that was asked for. An LXC snapshot never
            # carries memory - that exists for VMs only - so a running container
            # is caught as if the power had been pulled, and a database mid
            # transaction is snapshotted mid transaction. Stopping it first is
            # the only way to a consistent one; it is off by default because it
            # buys that with downtime.
            #
            # A container that was found stopped is already as cold as it gets
            # and is left alone here - starting it for its update is the other
            # setting's job, and it happens after this.
            my $cold = $opts->{snapshot_shutdown} && !$stopped;

            if ($cold) {
                _log('shutting the container down for a consistent snapshot');

                if (PVE::UpdateManager::Runner::shutdown_lxc($target->{id}, $logfunc) != 0) {
                    # Before the update, not during it: the run is refused
                    # rather than quietly falling back to a snapshot of a
                    # running container, which is the thing the setting says it
                    # will not do.
                    my $note = 'could not be shut down for its snapshot';
                    _set_state(
                        $target,
                        {
                            state => 'failed', upid => $upid, started => $started,
                            finished => time(), exit => -1, note => $note,
                        },
                    );
                    return (-1, $note, $stop->(-1, $note));
                }
            }

            $snapshot = eval {
                PVE::UpdateManager::Runner::snapshot_lxc($target->{id}, $logfunc, $started);
            };
            my $snap_err = $@ // '';

            # Back up before anything is reported, and whatever the snapshot
            # did: a container left switched off because its snapshot failed is
            # a worse outcome than the failure itself.
            if ($cold) {
                _log(
                    defined($snapshot)
                    ? 'snapshot taken - starting the container again'
                    : 'the snapshot failed - starting the container again before reporting it',
                );

                if (PVE::UpdateManager::Runner::start_lxc($target->{id}, $logfunc) != 0) {
                    my $note = 'could not be started again after its snapshot';
                    $note .= " (and the snapshot failed too)" if !defined($snapshot);
                    _set_state(
                        $target,
                        {
                            state => 'failed', upid => $upid, started => $started,
                            finished => time(), exit => -1, note => $note,
                        },
                    );
                    $prune->();
                    return (-1, $note, $stop->(-1, $note));
                }

                # Not fatal, exactly as when a stopped container is started for
                # its update: a container with no network is a legitimate thing
                # to update from a local mirror.
                _log('WARNING: the container came back up without a default route')
                    if !PVE::UpdateManager::Runner::wait_online($target->{id}, $logfunc);
            }

            # On the facts as soon as it exists, not only at the bottom: every
            # early return below this point is a run that has a rollback point
            # and has to be able to say which one.
            $facts->{snapshot} = $snapshot if defined($snapshot);

            if (!defined($snapshot)) {
                # A failure, not a warning, and deliberately different from "the
                # storage cannot do it": the storage said it could and then did
                # not. The usual reason is a full thin pool, which is the exact
                # situation where continuing into a dist-upgrade is worst.
                my $err = $snap_err;
                chomp($err);
                my $note = "could not be snapshotted before the update - $err";
                _set_state(
                    $target,
                    {
                        state => 'failed', upid => $upid, started => $started,
                        finished => time(), exit => -1, note => $note,
                    },
                );
                # Nothing to give back: the config lock below has not been taken
                # yet, which is the whole reason the snapshot happens here.
                return (-1, $note, $stop->(-1, $note));
            }
        }
    }

    # Proxmox refuses to stop, shut down, reboot or migrate a locked guest -
    # every one of those paths calls check_lock - so the lock is all it takes to
    # keep a container from being switched off in the middle of its own
    # dist-upgrade. Taken after the row is claimed, given back below whatever
    # happens.
    my $locked = 0;
    if ($target->{type} eq 'lxc') {
        if (eval { PVE::UpdateManager::Runner::lock_guest($target->{id}); 1 }) {
            $locked = 1;
        } else {
            # set_lock refuses rather than overwriting, so this is somebody
            # else's lock - a backup, a migration. Updating on top of that is
            # exactly what the lock exists to prevent.
            my $err = $@ // '';
            chomp($err);
            my $note = "another task holds the lock ($err)";
            _set_state(
                $target,
                {
                    state => 'skipped', upid => $upid, started => $started,
                    finished => time(), note => $note,
                },
            );
            $prune->();
            return (undef, $note, $stop->(undef, $note));
        }
    }

    # Started here rather than before the lock, so the row already shows a
    # spinner while the container boots - that is part of the run's duration and
    # a second task must not slip in during it.
    my $we_started_it = 0;
    if ($stopped) {
        _log('container is stopped - starting it for the update');

        if (PVE::UpdateManager::Runner::start_lxc($target->{id}, $logfunc) != 0) {
            my $failed = time();
            _set_state(
                $target,
                {
                    state => 'failed', upid => $upid, started => $started,
                    finished => $failed, exit => -1,
                    note => 'could not be started for the update',
                },
            );
            # A failure, not a skip: this target was asked for explicitly by
            # turning the setting on, and it did not happen. The lock goes back
            # on the way out - an early return that keeps it would leave the
            # container unstoppable until somebody found `pct unlock`.
            PVE::UpdateManager::Runner::unlock_guest($target->{id}, $logfunc) if $locked;
            $prune->();
            return (
                            -1,
                            'could not be started for the update',
                            $stop->(-1, 'could not be started for the update'),
                        );
        }

        $we_started_it = 1;

        if (!PVE::UpdateManager::Runner::wait_online($target->{id}, $logfunc)) {
            # Not fatal. A container with no network is a legitimate thing to
            # update from a local mirror, and guessing otherwise would refuse a
            # run that would have worked.
            _log('WARNING: the container came up without a default route - updating anyway');
        }
    }

    my $rc;
    if ($target->{type} eq 'node') {
        $rc = PVE::UpdateManager::Runner::run_host($script, $timeout, $logfunc);
    } else {
        $rc = PVE::UpdateManager::Runner::run_lxc($target->{id}, $script, $timeout, $logfunc);
    }

    # BEFORE the shutdown below, not after. The lock we hold is the same one PVE
    # checks in vm_shutdown, so leaving it on would make our own attempt to put
    # the container back fail - the guard would defeat the thing it is guarding.
    # The update itself is over by this point, which is what the lock was for.
    PVE::UpdateManager::Runner::unlock_guest($target->{id}, $logfunc) if $locked;

    # ── undoing an update that failed ───────────────────────────────────────
    #
    # Off by default, and it has to be: a rollback throws away everything that
    # happened since the snapshot, not only what the update did. Fifteen minutes
    # of a database's day go with it. Where it is switched on, it is switched on
    # for containers whose update either works or is to be taken back whole.
    #
    # After the lock, never before: PVE's snapshot_rollback calls check_lock and
    # refuses while any lock is set - ours included.
    my $rolled_back = 0;
    my $rollback_failed = 0;

    if ($rc != 0 && defined($snapshot) && $opts->{rollback_on_failure}) {
        _log("the update failed - rolling the container back to $snapshot");

        if (eval {
            PVE::UpdateManager::Runner::rollback_lxc($target->{id}, $snapshot, $logfunc);
            1;
        }) {
            $rolled_back = 1;

            # PVE stops the container to roll it back and leaves it stopped -
            # read off AbstractConfig and then watched on a real 9.2. Whatever
            # we knew about having started it ourselves is no longer true.
            $we_started_it = 0;

            if (!$stopped) {
                _log('rolled back - starting the container again');
                $rollback_failed = 1
                    if PVE::UpdateManager::Runner::start_lxc($target->{id}, $logfunc) != 0;
                _log('WARNING: the container did not come back up after the rollback')
                    if $rollback_failed;
            }
        } else {
            my $err = $@ // '';
            chomp($err);
            _log("WARNING: rolling back to $snapshot failed - $err");
            $rollback_failed = 1;

            # The stop happens before the rollback itself, so one that died in
            # the middle can leave the container off. Asked rather than assumed:
            # starting one that is already running is an error in the log for
            # nothing.
            if (!$stopped && !PVE::LXC::check_running($target->{id})) {
                _log('the container is off after the failed rollback - starting it again');
                PVE::UpdateManager::Runner::start_lxc($target->{id}, $logfunc);
            }
        }
    }

    # Put back the way it was found, whatever the update did. Inside no eval
    # because nothing above dies - run_lxc turns every failure into an exit
    # code - and a shutdown that is skipped on a failed update would leave the
    # container running, which is the one outcome nobody asked for.
    my $shutdown_failed = 0;
    if ($we_started_it) {
        _log('update finished - putting the container back into the stopped state it was in');
        $shutdown_failed = PVE::UpdateManager::Runner::shutdown_lxc($target->{id}, $logfunc) != 0;
        _log('WARNING: the container could not be stopped again') if $shutdown_failed;
    }

    # After the container is back the way it was found, and after the lock is
    # given back - snapshot_delete takes a lock of its own too. Housekeeping, so
    # it happens whether the update worked or not: what it keeps is the NEWEST
    # snapshots, this run's included, and a failed run is the one whose rollback
    # point matters most.
    $prune->();

    my $finished = time();
    my $elapsed = $finished - $started;

    # 124 is what coreutils `timeout` reports when it had to stop the command,
    # so the operator reads "timed out" instead of decoding an exit code - and
    # the run really is over, group and all, not just no longer watched.
    my $note = $rc == $PVE::UpdateManager::Runner::TIMEOUT_RC
        ? "timed out after ${elapsed}s"
        : "exit $rc after ${elapsed}s";

    my $dropped = $report->();
    $note .= ", $dropped further output line" . ($dropped == 1 ? '' : 's') . " not logged"
        if $dropped;

    # Worth the row's one line of space: a container left running when it was
    # supposed to end up stopped is a change to the system that outlives the
    # task log nobody reads afterwards.
    $note .= ', but it could NOT be stopped again' if $shutdown_failed;

    # The row only carries a note when there is something the exit code does not
    # already say. "exit 0 after 4s" next to every green tick is noise; "timed
    # out" or "output not logged" is the one case where the log alone would
    # mislead, because it just stops.
    # The same numbers the note is built from, so the notification and the log
    # can never disagree about how long a target ran or when it stopped.
    $facts->{finished} = $finished;
    $facts->{elapsed} = $elapsed;
    $facts->{exit} = $rc;
    $facts->{timed_out} = ($rc == $PVE::UpdateManager::Runner::TIMEOUT_RC) ? 1 : 0;
    $facts->{dropped} = $dropped;
    $facts->{shutdown_failed} = $shutdown_failed ? 1 : 0;
    $facts->{rolled_back} = $rolled_back ? 1 : 0;
    $facts->{rollback_failed} = $rollback_failed ? 1 : 0;

    my $state = {
        state => $rc == 0 ? 'ok' : 'failed',
        upid => $upid,
        started => $started,
        finished => $finished,
        exit => $rc,
    };
    # The snapshot is named on the row only when the run went wrong. That is the
    # one moment somebody needs to know which snapshot to roll back to, and it is
    # the moment the task log is least likely to still be the thing being read.
    # Where the run rolled back by itself, the row says THAT instead: the
    # container is not the one the update left behind any more, and somebody
    # reading "snapshot updmgr-..." would go and roll back to it a second time.
    if ($rolled_back) {
        $note .= ", rolled back to $snapshot";
        $note .= ' - but it did NOT come back up' if $rollback_failed;
    } elsif (defined($snapshot) && $rc != 0) {
        $note .= ", snapshot $snapshot";
        $note .= " - the rollback to it FAILED" if $rollback_failed;
    }

    # A snapshot PVE could neither remove nor be talked out of holding. The
    # container may still be locked, which stops its next update as well, so it
    # is said on the row and not left to the log.
    my $wedged = scalar(@{ $stuck // [] });
    $note .= ", $wedged snapshot" . ($wedged == 1 ? '' : 's') . " could NOT be removed"
        if $wedged;
    $facts->{stuck} = $wedged;

    $state->{note} = $note
        if $dropped
        || $shutdown_failed
        || $rolled_back
        || $rollback_failed
        || $wedged
        || (defined($snapshot) && $rc != 0)
        || $rc == $PVE::UpdateManager::Runner::TIMEOUT_RC;

    _set_state($target, $state);

    # Through the same closure as every early exit, so the log of a run that
    # finished is written by the line that writes the log of one that did not.
    $stop->($rc, $note);

    return ($rc, $note, $facts);
}

# run_one, and what to do when it does not come back at all.
#
# It turns nearly everything into an exit code, but not quite everything: a
# script file above the size limit makes load_script die, and PVE can die from
# under any of the calls below it. That used to end the whole job at the banner of
# the target it happened on - no verdict, no summary, and every target after it
# never attempted. Measured with a hand-written oversized file in
# /etc/pve/pve-update-manager, which is exactly the case has_script already
# carries a comment about: the run died with a raw perl message and the second
# container was never touched. Now it is that target's failure and the batch goes
# on, which is what this job promises everywhere else.
#
# Here rather than in the parallel path alone, deliberately: a forked child had to
# catch this anyway to be able to report at all, and a serial run that dies where
# a parallel one carries on is the two modes disagreeing about the same input.
#
# The row is written here too. run_one records every outcome it produces itself,
# and the ONE path that reaches this is the path where it did not get that far -
# so this can only ever add a result, never replace a real one. Its own last line
# is the final _set_state, and nothing after that can die.
sub _guarded_run_one {
    my ($target, $timeout, $upid, $opts) = @_;

    my $started = time();

    my ($rc, $note, $facts);
    my $survived = eval {
        ($rc, $note, $facts) = run_one($target, $timeout, $upid, $opts);
        1;
    };

    return ($rc, $note, $facts) if $survived;

    my $err = $@ // 'unknown error';
    chomp($err);
    $err =~ s/[\r\n]+/ /g;
    $note = "the update crashed - $err";

    _set_state(
        $target,
        {
            state => 'failed', upid => $upid, started => $started,
            finished => time(), exit => -1, note => $note,
        },
    );

    return (-1, $note, { started => $started, finished => time(), exit => -1 });
}

# One target's outcome, in the log and in the terms the summary counts in.
#
# Shared by the serial walk and the parallel one so a verdict line cannot come
# out differently depending on which of the two produced it - the operator reads
# the same three words either way.
sub _record {
    my ($desc, $rc, $note, $finished, $exit, $facts) = @_;

    my $state = !defined($rc) ? 'SKIPPED' : $rc == 0 ? 'OK' : 'FAILED';

    _log("--- $desc: $state ($note)");

    $facts //= {};

    return {
        desc => $desc,
        state => $state,
        note => $note,
        # run_one's own timestamp where there is one: it is the number the note
        # was built from, and a notification whose "failed at" disagrees with its
        # own note by a second is a notification somebody has to check twice.
        finished => $facts->{finished} // $finished,
        # For the notification, which names the exit code of every target that
        # failed. Undef for a skip, where there was no command to exit.
        exit => defined($exit) ? $exit : $rc,
        # The pieces the notification puts on lines of their own - which
        # snapshot, whether it was rolled back, how long it ran.
        facts => $facts,
    };
}

# What a child of a parallel wave tells its parent: the exit code, the note and
# when it finished.
#
# Over a pipe rather than a temp file - nothing to clean up, nothing left behind
# when the worker is killed mid-run, and no dependency on where TMPDIR points on
# somebody's node.
#
# The note is cut to this many bytes before it is written. The parent reads the
# pipe only after waitpid, so a child writing more than a pipe holds would block
# for ever while the parent waits on it: a deadlock inside a root job. Linux
# gives a pipe 64 KiB and a note is one line, so this is a guard and not a limit
# anybody will meet - and the note on the target's own ROW is written by the
# child before it reports, in full, so nothing is lost even if it were.
our $MAX_NOTE_BYTES = 4096;

# Overridable for the tests, and for nothing else.
#
# The fallback below runs when the kernel refuses a fork, which a test suite
# cannot provoke without exhausting the machine it is running on - and an
# untested fallback in a job that runs as root is how a fallback turns out to be
# either the only path that ever runs or a path that never could. The hook can
# only make a run WORSE: overriding it forces the slower, serial-inside-the-wave
# path, never the other way round.
our $FORK = sub { return fork() };

# One wave: every target in it is started at once, and this does not return until
# the last of them is done.
#
# One child process per target rather than one Proxmox worker per target. A
# worker of its own would give each target its own task and its own log, which is
# what a parallel run used to do - but then nothing is left that knows when the
# WHOLE run is over, which is what the order between waves and the notification
# at the end both need. So the wave runs inside this one task, and the target's
# name goes in front of every line it writes.
#
# No cap on how many run at once. Forty containers ticked in parallel mode were
# forty dist-upgrades at once before this existed too, and quietly holding some
# of them back would be a limit nobody asked for hiding inside a feature about
# ordering. The node's own settings are where that decision belongs if it is ever
# wanted.
sub _run_group {
    my ($group, $timeout, $upid, $opts) = @_;

    # Both halves matter. Setting $| flushes what this process has buffered right
    # now, so a child cannot inherit a half-written buffer and print it a second
    # time; and it keeps every later line a single write() syscall, which is what
    # stops two processes writing into the same task log from cutting each other's
    # lines in half. In a real worker fork_worker has already done this - it is
    # here for the runs that are not one, the test suite included.
    STDOUT->autoflush(1);

    my @children;

    for my $target (@$group) {
        my $desc = _describe($target);

        my ($reader, $writer);
        if (!pipe($reader, $writer)) {
            # Nothing to report through, so nothing is forked either: the target
            # is run here instead. Slower than it should be, and still updated -
            # which beats failing a container because the kernel was out of file
            # descriptors for a moment.
            _log("WARNING: no pipe for $desc - running it in this task instead");
            push @children, { target => $target, desc => $desc, inline => 1 };
            next;
        }

        my $pid = $FORK->();

        if (!defined($pid)) {
            close($reader);
            close($writer);
            _log("WARNING: could not fork for $desc - running it in this task instead");
            push @children, { target => $target, desc => $desc, inline => 1 };
            next;
        }

        if (!$pid) {
            # ── child ──
            #
            # Everything from here to the _exit at the bottom is inside an eval,
            # and that is structural rather than a case anybody has hit:
            # _guarded_run_one does not die, and nothing after it can. What the
            # eval buys is that a future line which CAN die does not escape the
            # fork - a die here unwinds into the parent's stack frames, which
            # this process is a copy of, and the child then goes on to run the
            # rest of the job a second time. Measured, by mutating the guard
            # away: the same three targets were reported twice and the test
            # plan came out at 157 assertions from one process and 6 from
            # another.
            close($reader);

            eval {
                # Every line this process writes from here on says which target
                # it belongs to. Several of them share one task log.
                $LINE_PREFIX = '[' . _short_desc($target) . '] ';
                STDOUT->autoflush(1);

                my ($rc, $note, $facts) = _guarded_run_one($target, $timeout, $upid, $opts);

                if (defined($note)) {
                    # One record per line, so a note carrying a newline cannot
                    # forge a field - the same rule save_state follows, and for a
                    # worse reason here: a note ending in "\nrc=0" turned a
                    # failed target into an OK one in the summary. Notes are built
                    # from PVE error strings, which are not always one line.
                    $note =~ s/[\r\n]+/ /g;

                    if (length($note) > $MAX_NOTE_BYTES) {
                        $note = substr($note, 0, $MAX_NOTE_BYTES);
                        # A note is bytes by the time it gets here - PVE reads its
                        # configs and its storage output without decoding - so a
                        # cut at a byte count can land in the middle of a
                        # multi-byte character and leave the task log holding half
                        # of one. The trailing fragment goes rather than the whole
                        # note being re-encoded: this is a guard on a length
                        # nothing reaches, and losing one character at the edge of
                        # it is the cheapest correct answer.
                        $note =~ s/[\xC0-\xFF][\x80-\xBF]*\z//;
                    }
                }

                print $writer "rc=" . (defined($rc) ? $rc : '') . "\n";
                print $writer "finished=" . time() . "\n";
                print $writer "note=" . (defined($note) ? $note : '') . "\n";

                # Every fact under an `f_` prefix, so the parent can reassemble
                # them without a list here and a matching list there - the two
                # would drift the first time one of them gained a field. Values
                # are flattened for the same reason the note is: one record per
                # line, or a snapshot name with a newline in it becomes an exit
                # code.
                for my $key (sort keys %{ $facts // {} }) {
                    next if $key !~ m/\A[a-z_]+\z/;
                    my $value = $facts->{$key};
                    next if !defined($value);
                    $value =~ s/[\r\n]+/ /g;
                    print $writer "f_$key=" . substr($value, 0, 256) . "\n";
                }

                close($writer);
                1;
            };

            # Nothing is reported here on purpose: the parent notices a child
            # that said nothing and calls it a failure by name. Writing a
            # half-report now would be the one thing worse than saying nothing.
            #
            # _exit, not exit: this process is a fork of a Proxmox worker, and
            # exit() would run its END blocks and its global destruction - the
            # worker's own cleanup, in a process that is not the worker. STDOUT
            # is unbuffered above, so there is nothing left to flush either.
            POSIX::_exit(0);
        }

        # ── parent ──
        #
        # The write end goes NOW, before the next target is forked: a later child
        # that inherited it would keep this pipe from ever reaching EOF, and the
        # read below - which happens after waitpid - would block on a process
        # that has nothing left to say.
        close($writer);
        push @children, { target => $target, desc => $desc, pid => $pid, fh => $reader };
    }

    my @results;

    # In the group's order, not in the order they happen to finish: the verdict
    # lines and the summary then read the same way twice in a row for the same
    # selection, which is what makes two task logs comparable.
    for my $child (@children) {
        if ($child->{inline}) {
            my ($rc, $note, $facts);
            {
                # Only around the run itself. The verdict line below is the
                # parent's own and is printed unprefixed, exactly as it is for a
                # target that really did get a process of its own.
                local $LINE_PREFIX = '[' . _short_desc($child->{target}) . '] ';
                ($rc, $note, $facts) = _guarded_run_one(
                    $child->{target}, $timeout, $upid, $opts,
                );
            }
            push @results, _record($child->{desc}, $rc, $note, time(), undef, $facts);
            next;
        }

        waitpid($child->{pid}, 0);
        my $status = $?;

        my $raw = '';
        {
            my $fh = $child->{fh};
            local $/ = undef;
            $raw = <$fh> // '';
        }
        close($child->{fh});

        my %report;
        my $facts = {};
        for my $line (split(/\n/, $raw, -1)) {
            # Only on the FIRST '=': a note carries prose and would otherwise be
            # cut at the first equals sign in it.
            next if $line !~ m/\A([a-z_]+)=(.*)\z/;
            my ($key, $value) = ($1, $2);

            if ($key =~ s/\Af_//) {
                $facts->{$key} = $value;
                next;
            }

            $report{$key} = $value;
        }

        if (!exists($report{rc})) {
            # The child never got as far as saying how it went. It was killed -
            # the job stopped, an OOM, a reboot - and the container it was
            # updating may still have a lock on it, so this has to be a failure
            # and not a shrug.
            #
            # Unlike the crash above, the target's ROW is deliberately left
            # alone. A child that was killed may have been killed AFTER writing
            # its result and before reporting it, and there is no way to tell
            # from here - so writing "died" over a real "ok" is a live risk,
            # while leaving it is not: the row says 'running', and last_run turns
            # that into "the task ended without recording a result" as soon as
            # this job's own worker is gone, because it is the pid on the row.
            my $note = 'its process died without reporting a result';
            $note .= sprintf(' (killed by signal %d)', $status & 127) if $status & 127;
            push @results, _record($child->{desc}, -1, $note, time(), -1, $facts);
            next;
        }

        # Strictly a number or the empty string that means "skipped". Anything
        # else is not a report this code wrote, so it is not read as one either.
        my $rc =
            $report{rc} =~ m/\A-?\d+\z/ ? int($report{rc})
            : !length($report{rc}) ? undef
            : -1;
        my $note = $report{note} // '';
        my $finished = ($report{finished} // '') =~ m/\A\d+\z/ ? int($report{finished}) : time();

        push @results, _record($child->{desc}, $rc, $note, $finished, undef, $facts);
    }

    return \@results;
}

sub run_all {
    my ($targets, $timeout, $opts) = @_;

    $opts //= {};

    # The same target twice is one target. A request that repeats a vmid, or a
    # schedule_vmids edited by hand into '101,101', would otherwise update it
    # twice and snapshot it twice - and the second snapshot fails outright when
    # both land in the same second, because the name carries a whole-second
    # timestamp and PVE refuses a name it already has. Measured against its
    # source: "snapshot name '...' already used".
    my %seen;
    $targets = [grep { !$seen{"$_->{type}-$_->{id}"}++ } @$targets];

    # Here and nowhere else, so every route into a run - the button, a single
    # container, the timer - walks its targets in the same order. A parallel run
    # goes through the same sort and then through the same numbers again to find
    # its waves, so the two modes cannot disagree about what comes first.
    my $groups = $opts->{parallel}
        ? PVE::UpdateManager::Config::group_targets($targets)
        : [map { [$_] } @{ PVE::UpdateManager::Config::sort_targets($targets) }];

    $targets = [map { @$_ } @$groups];

    my $upid = current_upid();
    my $total = scalar(@$targets);
    my $waves = scalar(@$groups);
    my $run_started = time();
    my @results;

    # Out of the control group of whatever daemon forked this worker, before a
    # single target is touched. A package whose postinst restarts pvedaemon would
    # otherwise take this worker and the dist-upgrade under it down with the
    # daemon - see detach_from_daemon, which is where that is measured.
    PVE::UpdateManager::Runner::detach_from_daemon(\&_log, $upid);

    # The node has no config lock to take, so shutdown and reboot of the machine
    # itself are held off with a systemd inhibitor for as long as the job runs.
    # Sized to the worst case - every target hitting its own limit - so it never
    # lets go while something is still updating, and never outlives the job by
    # more than that either.
    #
    # A run that switches containers off and on again takes longer than the sum
    # of its timeouts - the shutdown, the hard stop behind it, the start and the
    # wait for a default route all sit OUTSIDE the limit that bounds the script.
    # Sized without them, a batch of ten containers on a ten-minute timeout
    # outlives its own inhibitor by half an hour, and from that moment the node
    # can be powered off in the middle of an update. Nothing is lost by being
    # generous here: the inhibitor is released when the job ends, so the budget
    # only ever matters to a worker that was killed.
    my $handling = (
        $opts->{start_stopped}
            || ($opts->{snapshot_before} && $opts->{snapshot_shutdown})
    ) ? $PVE::UpdateManager::Runner::PER_TARGET_GRACE : 0;

    my $budget = (($timeout // $PVE::UpdateManager::Runner::DEFAULT_TIMEOUT) + $handling) * $total
        + $PVE::UpdateManager::Runner::OUTER_GRACE;
    $budget = $PVE::UpdateManager::Runner::MAX_TIMEOUT
        if $budget > $PVE::UpdateManager::Runner::MAX_TIMEOUT;

    my $inhibit = PVE::UpdateManager::Runner::inhibit_shutdown($budget, \&_log);
    _log('holding off shutdown and reboot of this node until the job is done')
        if $inhibit;

    my $i = 0;
    my $wave = 0;
    for my $group (@$groups) {
        $wave++;

        if ($opts->{parallel}) {
            _log('') if $wave > 1;
            _log(
                "=== position $wave of $waves: "
                    . join(', ', map { _describe($_) } @$group)
                    . " ===",
            );
            push @results, @{ _run_group($group, $timeout, $upid, $opts) };
            next;
        }

        # Serial: one target per group, walked exactly as it always was.
        for my $target (@$group) {
            $i++;
            my $desc = _describe($target);

            _log('') if $i > 1;
            _log("=== [$i/$total] $desc ===");

            my ($rc, $note, $facts) = _guarded_run_one($target, $timeout, $upid, $opts);

            push @results, _record($desc, $rc, $note, time(), undef, $facts);
        }
    }

    my $failed = scalar(grep { $_->{state} eq 'FAILED' } @results);
    my $skipped = scalar(grep { $_->{state} eq 'SKIPPED' } @results);
    my $ok = $total - $failed - $skipped;

    _log('');
    _log('=== Summary ===');
    for my $r (@results) {
        _log(sprintf('%-8s %s (%s)', $r->{state}, $r->{desc}, $r->{note}));
    }
    _log("$ok ok, $failed failed, $skipped skipped, $total total");

    # Released before the die below, not after: a job that ends red must still
    # give the node back, or a single failed update would keep the machine from
    # being rebooted until the inhibitor's own deadline ran out.
    PVE::UpdateManager::Runner::release_shutdown($inhibit);

    # HERE, at the end of the whole run, and nowhere earlier. A run of twelve
    # containers that breaks four is one thing that happened; four notifications
    # for it is how somebody learns to filter all of them away. Which is also why
    # it is the job that sends it and not run_one: only the job knows the run is
    # over.
    #
    # After the inhibitor is released and before the die, so a notification that
    # hangs on a slow SMTP server cannot hold the node's shutdown - and so a run
    # that ends red still sends it.
    #
    # `$failed &&` is an early-out and not the guard: notify_failures decides for
    # itself that a run with nothing broken in it sends nothing, and a mutation
    # test that removes this condition reddens no test at all. It stays because
    # what it saves is `require PVE::Notify` - and behind it PVE::Cluster and the
    # Rust notification library - on every run that worked, which is nearly all
    # of them.
    if ($failed && $opts->{notify_failure}) {
        my $sent = PVE::UpdateManager::Notify::notify_failures(
            \@results, $upid, time() - $run_started,
        );
        # In the log because the log is where somebody looks after being told
        # nothing: a notification nobody received is otherwise indistinguishable
        # from one that was never attempted.
        _log('a notification about the failed targets was handed to Proxmox') if $sent;
    }

    # The task must go red when something went wrong, and the message has to say
    # what - a worker that returns quietly after a failed dist-upgrade is worse
    # than no button at all.
    die "$failed of $total update targets failed\n" if $failed;

    return;
}

1;
