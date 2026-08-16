package PVE::UpdateManager::Job;

# One update run over one or more targets, written for the Proxmox task log.
#
# Both the single-container button and the "update selected" button on the node
# end up here, so a run of one and a run of twelve are logged the same way: a
# banner per target, the raw command output underneath, a one-line verdict, and
# a summary at the end that can be read without scrolling back.
#
# A failing target does not stop the batch - the remaining ones still run, and
# the job as a whole fails at the end. Stopping halfway would leave the operator
# guessing which containers were even attempted.
#
# Every target's outcome is also written to its state file as it happens, which
# is what puts a live status into each row of the grids and lets the Last Log
# button find the right task.

use strict;
use warnings;

use PVE::LXC;

use PVE::UpdateManager::Config;
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

sub _log {
    my ($msg) = @_;
    print "$msg\n";
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

    my ($script) = PVE::UpdateManager::Config::load_script($target->{type}, $target->{id});
    if (!defined($script) || $script !~ m/\S/) {
        return (undef, skip_no_script($target, $upid, $started));
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
        return (undef, 'container is not running');
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
        return (undef, 'already being updated by another task');
    }

    my ($logfunc, $report) = _capped_logger($MAX_OUTPUT_BYTES);

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
            return (undef, $note);
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
            return (-1, 'could not be started for the update');
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
    my $state = {
        state => $rc == 0 ? 'ok' : 'failed',
        upid => $upid,
        started => $started,
        finished => $finished,
        exit => $rc,
    };
    $state->{note} = $note
        if $dropped || $shutdown_failed || $rc == $PVE::UpdateManager::Runner::TIMEOUT_RC;

    _set_state($target, $state);

    return ($rc, $note);
}

sub run_all {
    my ($targets, $timeout, $opts) = @_;

    my $upid = current_upid();
    my $total = scalar(@$targets);
    my @results;

    # The node has no config lock to take, so shutdown and reboot of the machine
    # itself are held off with a systemd inhibitor for as long as the job runs.
    # Sized to the worst case - every target hitting its own limit - so it never
    # lets go while something is still updating, and never outlives the job by
    # more than that either.
    my $budget = ($timeout // $PVE::UpdateManager::Runner::DEFAULT_TIMEOUT) * $total
        + $PVE::UpdateManager::Runner::OUTER_GRACE;
    $budget = $PVE::UpdateManager::Runner::MAX_TIMEOUT
        if $budget > $PVE::UpdateManager::Runner::MAX_TIMEOUT;

    my $inhibit = PVE::UpdateManager::Runner::inhibit_shutdown($budget, \&_log);
    _log('holding off shutdown and reboot of this node until the job is done')
        if $inhibit;

    my $i = 0;
    for my $target (@$targets) {
        $i++;
        my $desc = _describe($target);

        _log('') if $i > 1;
        _log("=== [$i/$total] $desc ===");

        my ($rc, $note) = run_one($target, $timeout, $upid, $opts);

        if (!defined($rc)) {
            _log("--- $desc: SKIPPED ($note)");
            push @results, { desc => $desc, state => 'SKIPPED', note => $note };
        } elsif ($rc == 0) {
            _log("--- $desc: OK ($note)");
            push @results, { desc => $desc, state => 'OK', note => $note };
        } else {
            _log("--- $desc: FAILED ($note)");
            push @results, { desc => $desc, state => 'FAILED', note => $note };
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

    # The task must go red when something went wrong, and the message has to say
    # what - a worker that returns quietly after a failed dist-upgrade is worse
    # than no button at all.
    die "$failed of $total update targets failed\n" if $failed;

    return;
}

1;
