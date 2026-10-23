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

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::Notify;
use PVE::UpdateManager::QemuPower;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Target;

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

    my $label = PVE::UpdateManager::Guest::label($target->{type});
    my $name = $target->{name};
    return defined($name) && length($name)
        ? "$label $target->{id} ($name)"
        : "$label $target->{id}";
}

# The same target, short enough to sit in front of every line of its output.
# Without the hostname on purpose: a container called
# "nextcloud-production-frontend" would push the output of every line it prints
# off the right of the task viewer.
sub _short_desc {
    my ($target) = @_;

    return $target->{type} eq 'node'
        ? "Host $target->{id}"
        : PVE::UpdateManager::Guest::label($target->{type}) . " $target->{id}";
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
# The word a run ends with, for the run log's header and for the summary - one
# function, so the two cannot disagree. NOT FIXED (#73): the script exited 0,
# but security updates pending before the run are still not installed - red,
# no rollback, and not a FAILED.
sub _verdict {
    my ($rc, $facts) = @_;

    return 'SKIPPED' if !defined($rc);
    return 'FAILED' if $rc != 0;
    return 'NOT FIXED' if ($facts // {})->{not_fixed_count};
    return 'OK';
}

sub _store_log {
    my ($target, $upid, $facts, $rc, $note, $lines, $opts) = @_;

    my $keep = $opts->{run_logs};
    return if !defined($keep) || $keep < 1;

    my $state = _verdict($rc, $facts);

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
        PVE::UpdateManager::Logs::save_log(
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
        ($rc, $note, $facts) = PVE::UpdateManager::Target::run_one($target, $timeout, $upid, $opts);
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

    my $state = _verdict($rc, $facts);

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
# How many run at once is the node's setting (`parallel_max` in the run options,
# 0 = no cap). Measured on a real node before the cap existed: 36 targets started
# in the same second - the node's DNS and reverse-proxy containers among them -
# and that night's failures were network fetches that went through when retried
# one at a time. The cap does not change what a wave is: the next position still
# waits for the last target of this one.
sub _run_group {
    my ($group, $timeout, $upid, $opts) = @_;

    my $max = $opts->{parallel_max} // 0;
    $max = 0 if $max !~ m/\A\d+\z/;

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

        _wait_for_slot(\@children, $max) if $max;

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

        # A child the cap already reaped has its status stored; a second
        # waitpid on it would return -1 and lose it.
        if (!$child->{reaped}) {
            waitpid($child->{pid}, 0);
            $child->{status} = $?;
        }
        my $status = $child->{status};

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

# Blocks until fewer than $max forked children of this wave are still running.
#
# Polled per child with WNOHANG rather than a blocking waitpid(-1): this process
# has children that are not targets - the shutdown inhibitor is one, and
# release_shutdown reaps it by pid - and reaping one of those here would take
# its exit status from whoever is waiting for it. The status of a target's
# child is kept on its record, because the collecting loop in _run_group must
# not waitpid it a second time. Inline targets never count - they run later, in
# this process, one at a time.
our $SLOT_POLL = 0.2;

sub _wait_for_slot {
    my ($children, $max) = @_;

    while (1) {
        my $running = 0;
        for my $child (@$children) {
            next if !$child->{pid} || $child->{reaped};
            # -1 is "no such child" and counts as gone: counted as running, it
            # would keep this loop waiting for ever on a process that cannot end.
            my $got = waitpid($child->{pid}, POSIX::WNOHANG());
            if ($got == $child->{pid} || $got == -1) {
                $child->{status} = $?;
                $child->{reaped} = 1;
                next;
            }
            $running++;
        }
        return if $running < $max;
        select(undef, undef, undef, $SLOT_POLL);
    }
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
    # A batch with a VM in it is sized by the VM figure, for every target: a VM
    # boots slower than a container starts and can be rebooted on top, and the
    # budget only has to be generous, not exact. A batch of containers alone
    # keeps the container figure - inflating it would hold the node's shutdown
    # for nothing after a killed worker.
    my $has_vm = scalar(grep { $_->{type} eq 'qemu' } @$targets);
    my $handling = (
        $opts->{start_stopped}
            || ($has_vm && $opts->{reboot_vms})
            || ($opts->{snapshot_before} && $opts->{snapshot_shutdown})
    )
        ? ($has_vm
            ? $PVE::UpdateManager::QemuPower::PER_TARGET_GRACE
            : $PVE::UpdateManager::Runner::PER_TARGET_GRACE)
        : 0;

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
            my $cap = $opts->{parallel_max} // 0;
            _log(
                "=== position $wave of $waves: "
                    . join(', ', map { _describe($_) } @$group)
                    . ($cap && $cap < scalar(@$group) ? ", at most $cap at once" : '')
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
    my $unfixed = scalar(grep { $_->{state} eq 'NOT FIXED' } @results);
    my $ok = $total - $failed - $skipped - $unfixed;

    _log('');
    _log('=== Summary ===');
    for my $r (@results) {
        _log(sprintf('%-8s %s (%s)', $r->{state}, $r->{desc}, $r->{note}));
    }
    # "not fixed" only when there is one: every other run keeps the line it had.
    _log("$ok ok, " . ($unfixed ? "$unfixed not fixed, " : '') . "$failed failed, $skipped skipped, $total total");

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

    # The security notification about it, at most every cooldown per node (#73)
    # - also when nothing FAILED, and before the die below for the same reason
    # as the one above.
    if ($unfixed && $opts->{security_notify}) {
        my $sent = eval {
            require PVE::UpdateManager::SecReact;
            PVE::UpdateManager::SecReact::notify_unfixed(
                [grep { $_->{state} eq 'NOT FIXED' } @results], $opts->{security_unfixed_cooldown},
            );
        };
        _log("WARNING: the notification about NOT FIXED targets failed - $@") if $@;
        _log($sent ? 'a notification about the NOT FIXED targets was handed to Proxmox'
            : 'no notification about the NOT FIXED targets - the last one is within the cooldown')
            if !$@;
    }

    # The task must go red when something went wrong, and the message has to say
    # what - a worker that returns quietly after a failed dist-upgrade is worse
    # than no button at all. NOT FIXED goes red as well (#73: "the run is OK only when all
    # security updates are through"), named separately from a failure.
    die "$failed of $total update targets failed\n" if $failed;
    die "$unfixed of $total update targets are NOT FIXED - security updates pending before the run"
        . " are still not installed\n" if $unfixed;

    return;
}

1;
