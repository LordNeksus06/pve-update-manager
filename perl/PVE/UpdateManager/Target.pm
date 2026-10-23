package PVE::UpdateManager::Target;

# One target of a run, from the decision whether it runs at all to the row and
# the log it leaves behind: the checks that skip or fail it before anything
# happens, the snapshot, the lock, starting a stopped guest, the script, the
# rollback, putting the guest back the way it was found, the reboot a VM asked
# for, and the note that sums it up.
#
# Split out of Job.pm (#21), which was 1534 lines with this one function as half
# of them. Job keeps the run - the waves, the parallel children, the summary and
# the notification - and calls run_one here for each target. The logging it
# shares with Job (_log, _set_state, the capture of a target's output) stays in
# Job and is called from here; the two short wrappers below keep those calls
# readable.

use strict;
use warnings;

use PVE::LXC::Config;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::QemuPower;
use PVE::UpdateManager::QemuRunner;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::SecVerify;
use PVE::UpdateManager::Settings;
use PVE::UpdateManager::Snapshot;

# Calls rather than aliases: a test that replaces Job::_log or Job::_set_state
# with `local *...` has to reach these too.
sub _log { return PVE::UpdateManager::Job::_log(@_) }
sub _set_state { return PVE::UpdateManager::Job::_set_state(@_) }

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
    local $PVE::UpdateManager::Job::CAPTURE = ($opts->{run_logs} // 0) > 0 ? \@captured : undef;

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

        PVE::UpdateManager::Job::_store_log($target, $upid, $facts, $rc, $note, \@captured, $opts);

        return $facts;
    };

    # A target may carry its own commands: an immediate security update in
    # mode 'security' (#43) runs an upgrade of exactly the affected packages
    # instead of the stored script, with everything else - snapshot, lock,
    # rollback, log - exactly as for any run. Never set by an API caller; only
    # SecReact builds it, from package names that passed SecCompare's checks.
    my ($script) = defined($target->{script})
        ? ($target->{script})
        : PVE::UpdateManager::Config::load_script($target->{type}, $target->{id});
    if (!defined($script) || $script !~ m/\S/) {
        my $skip = PVE::UpdateManager::Job::skip_no_script($target, $upid, $started);
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
    my $guest = PVE::UpdateManager::Guest::is_guest_type($target->{type});
    my $vm = $target->{type} eq 'qemu';
    my $noun = PVE::UpdateManager::Guest::noun($target->{type});

    my $conf = $guest
        ? eval { PVE::UpdateManager::Guest::load_config($target->{type}, $target->{id}) }
        : undef;

    if ($guest && !$conf) {
        my $note = "not a $noun on this node";
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
    # off its own source - so with 'start stopped guests' on, a template in
    # the selection came out as a FAILED target rather than as one there was
    # never anything to do for. Select All picks them up, which is how it gets
    # into a run in the first place.
    if ($conf && PVE::UpdateManager::Guest::is_template($target->{type}, $conf)) {
        my $note = "this is a template, not a $noun";
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
    my $stopped = $guest && !PVE::UpdateManager::Guest::is_running($target->{type}, $target->{id});

    # One switch for both kinds, the owner's decision: a stopped VM is started
    # for its update and shut down again exactly when a stopped container is.
    if ($stopped && !$opts->{start_stopped}) {
        my $note = "$noun is not running";
        _set_state(
            $target,
            {
                state => 'skipped', upid => $upid, started => $started,
                finished => time(), note => $note,
            },
        );
        return (undef, $note, $stop->(undef, $note));
    }

    # A VM is reached through its guest agent and nothing else. Without one the
    # update did not happen, and that is a FAILURE, not a skip - the owner's
    # call: a VM that silently never gets updated is the outcome to avoid, and a
    # skip sends no notification.
    #
    # Asked before the row is claimed, so a VM without an agent does not flash
    # a spinner for the three seconds the ping takes. A VM that is off cannot be
    # pinged yet: for that one only the option is read here, and the agent has
    # to answer once the VM has booted - see $ready below.
    if ($vm) {
        my $missing = !PVE::UpdateManager::Guest::agent_enabled($conf)
            ? 'the QEMU guest agent is not enabled in the options of this VM'
            : !$stopped && !PVE::UpdateManager::QemuRunner::agent_running($target->{id})
            ? 'the QEMU guest agent is not answering - is qemu-guest-agent running inside the VM?'
            : undef;

        if (defined($missing)) {
            _set_state(
                $target,
                {
                    state => 'failed', upid => $upid, started => $started,
                    finished => time(), exit => -1, note => $missing,
                },
            );
            return (-1, $missing, $stop->(-1, $missing));
        }
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

    my ($logfunc, $report) = PVE::UpdateManager::Job::_capped_logger($PVE::UpdateManager::Job::MAX_OUTPUT_BYTES);

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
    #
    # A VM is asked too: a backup or a migration holds its config lock the same
    # way, and running apt inside a VM that is being migrated away is the same
    # mistake. Only the repairs below are container business.
    my $foreign_lock = $guest
        ? eval { PVE::UpdateManager::Guest::load_config($target->{type}, $target->{id})->{lock} }
        : undef;

    # A 'snapshot-delete' lock nobody has touched for ten minutes is not another
    # task holding the container, it is the wreck of an earlier run of ours -
    # and skipping it means skipping this container for good. Repaired here so
    # the next update is what un-sticks it, rather than a manual `pct unlock`.
    if (!$vm && defined($foreign_lock)
        && $foreign_lock eq $PVE::UpdateManager::Snapshot::SNAPSHOT_DELETE_LOCK) {

        my $wedged = PVE::UpdateManager::Snapshot::stale_delete_wedge($target->{id});
        if (defined($wedged)) {
            _log("CT $target->{id} is locked by a snapshot removal an earlier run"
                . " did not finish - repairing it before the update");
            PVE::UpdateManager::Snapshot::_repair_stuck_delete($target->{id}, $wedged, $logfunc);
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
            . int($PVE::UpdateManager::Snapshot::STALE_WEDGE_SECONDS / 60)
            . " minutes, so this may be left over from an update that was"
            . " interrupted; 'pct unlock $target->{id}' clears it"
            if !$vm && PVE::UpdateManager::Runner::stale_own_lock($target->{id});

        _set_state(
            $target,
            {
                state => 'skipped', upid => $upid, started => $started,
                finished => time(), note => $note,
            },
        );
        return (undef, $note, $stop->(undef, $note));
    }

    # Switching the guest off and on, per kind. A container is "ready" once it
    # has a default route, and not having one is a warning: a container with no
    # network is a legitimate thing to update from a local mirror. A VM is ready
    # once its guest agent answers, and not answering is fatal: the update goes
    # through the agent and nothing else, and a missing agent is a FAILURE by the
    # owner's decision (see above).
    my ($start, $shutdown, $ready) = $vm
        ? (
            \&PVE::UpdateManager::QemuPower::start_vm,
            \&PVE::UpdateManager::QemuPower::shutdown_vm,
            sub {
                return 1 if PVE::UpdateManager::QemuPower::wait_agent($target->{id});
                _log("the guest agent did not answer within"
                    . " $PVE::UpdateManager::QemuPower::AGENT_WAIT seconds of the start");
                return 0;
            },
        )
        : (
            \&PVE::UpdateManager::Runner::start_lxc,
            \&PVE::UpdateManager::Runner::shutdown_lxc,
            sub {
                _log('WARNING: the container came up without a default route - updating anyway')
                    if !PVE::UpdateManager::Runner::wait_online($target->{id}, $logfunc);
                return 1;
            },
        );

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
        (undef, $stuck) = PVE::UpdateManager::Snapshot::prune_snapshots(
            $target->{id},
            $opts->{snapshot_keep} // $PVE::UpdateManager::Settings::DEFAULT_SNAPSHOT_KEEP,
            $logfunc,
            $snapshot,
        );
    };

    # A VM is snapshotted with the same settings as a container, the owner's
    # decision - disk only, never its memory (see Runner::snapshot_guest).
    if ($guest && $opts->{snapshot_before}) {
        if (!PVE::UpdateManager::Snapshot::can_snapshot($target->{id})) {
            _log("the storage of this $noun cannot snapshot - updating without one");
        } else {
            # A cold snapshot, if that was asked for. An LXC snapshot never
            # carries memory, and the VM one this addon takes does not either, so
            # a running guest is caught as if the power had been pulled - for a
            # VM with its agent the filesystems are frozen around it, but a
            # database mid transaction is still caught mid transaction. Stopping
            # it first is the only way to a consistent one; it is off by default
            # because it buys that with downtime.
            #
            # A guest that was found stopped is already as cold as it gets and is
            # left alone here - starting it for its update is the other setting's
            # job, and it happens after this.
            my $cold = $opts->{snapshot_shutdown} && !$stopped;

            if ($cold) {
                _log("shutting the $noun down for a consistent snapshot");

                if ($shutdown->($target->{id}, $logfunc) != 0) {
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
                PVE::UpdateManager::Snapshot::snapshot_guest($target->{id}, $logfunc, $started);
            };
            my $snap_err = $@ // '';

            # Back up before anything is reported, and whatever the snapshot
            # did: a guest left switched off because its snapshot failed is a
            # worse outcome than the failure itself.
            if ($cold) {
                _log(
                    defined($snapshot)
                    ? "snapshot taken - starting the $noun again"
                    : "the snapshot failed - starting the $noun again before reporting it",
                );

                my $back = $start->($target->{id}, $logfunc) == 0;
                my $note = !$back
                    ? 'could not be started again after its snapshot'
                    : !$ready->()
                    ? 'came back up after its snapshot, but its guest agent did not answer'
                    : undef;

                if (defined($note)) {
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
    # keep a guest from being switched off in the middle of its own
    # dist-upgrade. Taken after the row is claimed, given back below whatever
    # happens. A container and a VM take different lock values - see
    # Runner::LXC_LOCK and QemuRunner::VM_LOCK for why each is the one it is.
    my ($lock_guest, $unlock_guest) = $vm
        ? (\&PVE::UpdateManager::QemuRunner::lock_vm, \&PVE::UpdateManager::QemuRunner::unlock_vm)
        : (\&PVE::UpdateManager::Runner::lock_guest, \&PVE::UpdateManager::Runner::unlock_guest);

    my $locked = 0;
    if ($guest) {
        if (eval { $lock_guest->($target->{id}); 1 }) {
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
        _log("$noun is stopped - starting it for the update");

        # The third argument is $skiplock, and only start_vm reads it: the VM
        # carries our own lock by now, and qm start refuses while one is set -
        # see QemuPower::start_vm.
        if ($start->($target->{id}, $logfunc, $locked) != 0) {
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
            # guest unstoppable until somebody found `pct unlock` / `qm unlock`.
            $unlock_guest->($target->{id}, $logfunc) if $locked;
            $prune->();
            return (
                            -1,
                            'could not be started for the update',
                            $stop->(-1, 'could not be started for the update'),
                        );
        }

        $we_started_it = 1;

        if (!$ready->()) {
            # Only a VM gets here - see $ready. It is up and nothing can reach
            # into it, so it is put back the way it was found before reporting:
            # a VM left running that somebody had switched off is the outcome the
            # setting promises not to produce. The lock goes first, because
            # qm shutdown refuses while one is set.
            my $note = 'was started for the update, but its guest agent did not answer';
            $unlock_guest->($target->{id}, $logfunc) if $locked;
            $note .= ', and it could NOT be stopped again'
                if $shutdown->($target->{id}, $logfunc) != 0;
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
    }

    # What the last security check found pending, read before the script runs:
    # that is the list this run has to clear (#73).
    my $expect = PVE::UpdateManager::SecVerify::expected($target, $opts);

    my $rc;
    if ($target->{type} eq 'node') {
        $rc = PVE::UpdateManager::Runner::run_host($script, $timeout, $logfunc);
    } elsif ($vm) {
        $rc = PVE::UpdateManager::QemuRunner::run_vm($target->{id}, $script, $timeout, $logfunc);
    } else {
        $rc = PVE::UpdateManager::Runner::run_lxc($target->{id}, $script, $timeout, $logfunc);
    }

    # BEFORE the shutdown below, not after. The lock we hold is the same one PVE
    # checks in vm_shutdown, so leaving it on would make our own attempt to put
    # the container back fail - the guard would defeat the thing it is guarding.
    # The update itself is over by this point, which is what the lock was for.
    $unlock_guest->($target->{id}, $logfunc) if $locked;

    # After the script, before a guest this run started is stopped again: a
    # stopped container on block storage, or a VM, could not be read any more.
    # Only after an exit 0 - a script that failed is FAILED whatever it left.
    my $unfixed;
    if ($rc == 0 && @$expect) {
        _log('checking that the ' . scalar(@$expect) . ' security update(s) pending before the run are installed');
        my $v = PVE::UpdateManager::SecVerify::verify($target, $expect, $logfunc);
        if (@{ $v->{missing} }) {
            $unfixed = PVE::UpdateManager::SecVerify::describe($v);
            $facts->{not_fixed_count} = scalar(@{ $v->{missing} });
            $facts->{not_fixed} = $unfixed;
            _log("NOT FIXED: $unfixed");
        } else {
            _log('all of them are installed');
        }
        # What the UI shows comes from the stored result, not from this run (#76).
        PVE::UpdateManager::SecVerify::record($target, $v, $logfunc);
    }

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
        _log("the update failed - rolling the $noun back to $snapshot");

        if (eval {
            PVE::UpdateManager::Snapshot::rollback_guest(
                $target->{id}, $snapshot, $logfunc, $opts->{rollback_remove_newer},
            );
            1;
        }) {
            $rolled_back = 1;

            # PVE stops the guest to roll it back and leaves it stopped - read
            # off AbstractConfig and then watched on a real 9.2 for a container;
            # for a VM AbstractConfig calls QemuConfig's
            # __snapshot_rollback_vm_stop and starts it again only for a snapshot
            # WITH memory, which ours never has. Whatever we knew about having
            # started it ourselves is no longer true.
            $we_started_it = 0;

            if (!$stopped) {
                _log("rolled back - starting the $noun again");
                $rollback_failed = 1 if $start->($target->{id}, $logfunc) != 0;
                _log("WARNING: the $noun did not come back up after the rollback")
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
            if (!$stopped && !PVE::UpdateManager::Guest::is_running($target->{type}, $target->{id})) {
                _log("the $noun is off after the failed rollback - starting it again");
                $start->($target->{id}, $logfunc);
            }
        }
    }

    # Put back the way it was found, whatever the update did. Inside no eval
    # because nothing above dies - run_lxc turns every failure into an exit
    # code - and a shutdown that is skipped on a failed update would leave the
    # container running, which is the one outcome nobody asked for.
    my $shutdown_failed = 0;
    if ($we_started_it) {
        _log("update finished - putting the $noun back into the stopped state it was in");
        $shutdown_failed = $shutdown->($target->{id}, $logfunc) != 0;
        _log("WARNING: the $noun could not be stopped again") if $shutdown_failed;
    }

    # A reboot the update asked for, where the node is set to do it. VMs only,
    # and off by default - both the owner's decision. Only for a VM that was
    # running before and still is: one this run started has just been shut down
    # again and boots the new kernel next time anyway, and one that was rolled
    # back is not on the update that wanted the reboot any more.
    #
    # After the lock is given back: qm reboot refuses while one is set. And the
    # target only counts as OK once the agent answers again - a VM that does not
    # come back from a reboot it was given is a failed target, not an updated one.
    my $rebooted = 0;
    my $reboot_failed = 0;
    if ($vm && $rc == 0 && $opts->{reboot_vms} && !$stopped && !$rolled_back) {
        my $wanted = PVE::UpdateManager::QemuPower::reboot_required($target->{id});

        if (!defined($wanted)) {
            _log("WARNING: could not ask the VM whether it needs a reboot - not rebooting it");
        } elsif ($wanted) {
            _log("$PVE::UpdateManager::QemuPower::REBOOT_FLAG exists - rebooting the VM");
            if (PVE::UpdateManager::QemuPower::reboot_vm($target->{id}, $logfunc) == 0) {
                $rebooted = 1;
                _log('the VM is back up and its guest agent answers');
            } else {
                $reboot_failed = 1;
            }
        }
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
    $note .= ', rebooted' if $rebooted;
    $note .= ', but the reboot it needed FAILED' if $reboot_failed;

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
    $facts->{reboot_failed} = $reboot_failed ? 1 : 0;
    $facts->{rolled_back} = $rolled_back ? 1 : 0;
    $facts->{rollback_failed} = $rollback_failed ? 1 : 0;

    # A reboot that did not bring the VM back fails the target although the
    # script exited 0: the owner's decision is that it counts as OK only once the
    # agent answers again. -1 rather than the script's 0, the code this job uses
    # wherever the step around the script failed - and it is what makes the row,
    # the summary and the notification all say FAILED. The note keeps the
    # script's own exit code at its front.
    my $result_rc = $reboot_failed ? -1 : $rc;

    # NOT FIXED: red, but not a failure (#73) - no rollback happened for it,
    # and the exit code stays the script's 0.
    $note .= ", NOT FIXED: $unfixed" if defined($unfixed) && $result_rc == 0;

    my $state = {
        state => $result_rc != 0 ? 'failed' : defined($unfixed) ? 'not_fixed' : 'ok',
        upid => $upid,
        started => $started,
        finished => $finished,
        exit => $result_rc,
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
        if defined($unfixed)
        || $dropped
        || $shutdown_failed
        || $rebooted
        || $reboot_failed
        || $rolled_back
        || $rollback_failed
        || $wedged
        || (defined($snapshot) && $rc != 0)
        || $rc == $PVE::UpdateManager::Runner::TIMEOUT_RC;

    _set_state($target, $state);

    # Through the same closure as every early exit, so the log of a run that
    # finished is written by the line that writes the log of one that did not.
    $stop->($result_rc, $note);

    return ($result_rc, $note, $facts);
}

1;
