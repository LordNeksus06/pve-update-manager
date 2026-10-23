#!/usr/bin/perl
# PVE::UpdateManager::Job, second half: a parallel run in waves, the
# notification at the end of a run, a target that crashes, a child that is
# killed or cannot be forked, the facts a failed target hands back, and the log
# a run leaves behind.
#
# Split from job.t (#21), which had grown past the 1000-line ceiling. The setup
# above the first section is the same in both files.

use strict;
use warnings;

use File::Path ();
use File::Temp qw(tempdir);
use IO::Handle;
use Test::More tests => 109;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Notify;
use PVE::ProcFSTools;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::Runner;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
# The target lock directory is root's below /run (#71); a test user cannot make it.
$PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";

# run_all moves its worker out of the control group of the daemon that forked it,
# which is a real busctl call and has no place in a unit test. Pointed at a file
# that does not exist, the runner cannot tell where it is and skips the move; the
# argv of that move is pinned in runner.t, and that run_all asks for it at all is
# checked below.
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

# Returns (stdout, error). Job writes with print because inside a Proxmox worker
# STDOUT is the task log.
#
# Into a real FILE, not an in-memory scalar. A parallel run forks a child process
# per target and those children write into the task log as well; a scalar
# filehandle is this process's own memory, so everything they printed would go
# with them and every claim about what the log says would be a claim about half of
# it. Autoflushed for the same reason it is autoflushed in the worker: two
# processes appending to one file must each write whole lines.
sub capture {
    my ($code) = @_;

    my $path = "$dir/capture.log";
    unlink($path);

    open(my $saved, '>&', \*STDOUT) or die "cannot dup STDOUT - $!";
    close(STDOUT);
    open(STDOUT, '>', $path) or die "cannot redirect STDOUT - $!";
    STDOUT->autoflush(1);

    my $err;
    eval {
        $code->();
        1;
    } or do {
        $err = $@;
    };

    close(STDOUT);
    open(STDOUT, '>&', $saved) or die "cannot restore STDOUT - $!";
    close($saved);

    my $out = '';
    if (open(my $fh, '<', $path)) {
        local $/ = undef;
        $out = <$fh> // '';
        close($fh);
    }

    return ($out, $err);
}

PVE::UpdateManager::Config::save_script('lxc', 101, "#!/bin/bash\napt-get update\n");
PVE::UpdateManager::Config::save_script('lxc', 103, "apt-get update\n");
PVE::UpdateManager::Config::save_script('node', 'pve-test', "apt-get update\n");
$PVE::LXC::RUNNING{101} = 4711;
$PVE::LXC::RUNNING{103} = undef;

# job.t sets this one up in its failing-batch section; the notification below
# needs a second running container with a script.
$PVE::LXC::RUNNING{104} = 4712;
PVE::UpdateManager::Config::save_script('lxc', 104, "apt-get update\n");


# ── a parallel run walks the update order in waves ──────────────────────────
#
# The claim, and it is the reason a parallel run had to move into ONE task: two
# targets on the same position run AT THE SAME TIME, and a target on the next
# position does not start until both of them have finished.
#
# Proven with a rendezvous rather than with a stopwatch. Each of the two targets
# in the first position writes a marker and then waits for the other one's marker
# before it finishes. If they really overlap, both get past it immediately; if the
# run were serial, the first would be waiting for a container that has not been
# started yet, the wait would run out, and the test would fail with "never
# overlapped" instead of being slow and flaky about it.
sub note_event {
    my ($file, $text) = @_;

    # Append mode and one small print: several processes write into this file at
    # the same time, and O_APPEND is what makes each line land whole.
    open(my $fh, '>>', $file) or die "cannot record an event - $!";
    print $fh "$text\n";
    close($fh);

    return;
}

sub events_of {
    my ($file) = @_;

    open(my $fh, '<', $file) or return [];
    local $/ = undef;
    my $raw = <$fh> // '';
    close($fh);

    return [grep { length } split(/\n/, $raw)];
}

# The position of the first event equal to $want, or -1.
sub event_at {
    my ($events, $want) = @_;

    for my $i (0 .. $#$events) {
        return $i if $events->[$i] eq $want;
    }

    return -1;
}

my $waves = [
    { type => 'lxc', id => 201, name => 'first-a' },
    { type => 'lxc', id => 202, name => 'first-b' },
    { type => 'lxc', id => 203, name => 'second' },
];

for my $vmid (201, 202, 203) {
    PVE::UpdateManager::Config::save_script('lxc', $vmid, "apt-get update\n");
    $PVE::LXC::RUNNING{$vmid} = 6000 + $vmid;
}
PVE::UpdateManager::Config::save_order('lxc', 201, 1);
PVE::UpdateManager::Config::save_order('lxc', 202, 1);
PVE::UpdateManager::Config::save_order('lxc', 203, 2);

# run_lxc builds [pct, 'exec', vmid, ...], so this is which container is being
# updated by the process that got here.
sub vmid_of_call {
    my ($cmd) = @_;
    return $cmd->[2];
}

{
    my $events = "$dir/wave-events";
    my $markers = "$dir/wave-markers";
    unlink($events);
    File::Path::remove_tree($markers) if -d $markers;
    mkdir($markers);

    local $PVE::Tools::RUN_RC = 0;
    # Something for the children to print, so the claim about the prefix below is
    # a claim about output that really travelled from a child process into this
    # log - and not about a log that happens to be empty.
    local $PVE::Tools::RUN_OUTPUT = ['reading package lists', 'done'];
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        my $vmid = vmid_of_call($cmd);

        note_event($events, "start $vmid");
        open(my $fh, '>', "$markers/$vmid") or die "cannot mark $vmid - $!";
        close($fh);

        if ($vmid == 201 || $vmid == 202) {
            my $peer = $vmid == 201 ? 202 : 201;
            my $tries = 0;
            # 20 seconds at the outside. A serial run reaches it and says so;
            # a parallel one is past it in milliseconds.
            until (-f "$markers/$peer" || $tries >= 400) {
                select(undef, undef, undef, 0.05);
                $tries++;
            }
            note_event($events, "never overlapped $vmid") if !-f "$markers/$peer";
        }

        note_event($events, "end $vmid");
    };

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all($waves, 60, { parallel => 1 });
        },
    );

    my $seen = events_of($events);

    # The premise first: without this the three claims below are claims about a
    # run that never started anything.
    is(scalar(grep { m/\Astart / } @$seen), 3, 'all three targets really ran');
    is(
        scalar(grep { m/\Anever overlapped/ } @$seen),
        0,
        'the two targets sharing a position really did run at the same time',
    );
    ok(
        event_at($seen, 'start 202') < event_at($seen, 'end 201'),
        'the second of them had started before the first one finished',
    );
    ok(
        event_at($seen, 'start 203') > event_at($seen, 'end 201')
            && event_at($seen, 'start 203') > event_at($seen, 'end 202'),
        'and the next position did not start until BOTH of the first were done',
    );

    ok(!defined($err), 'nothing failed, so the task does not die');
    like(
        $out,
        qr/=== position 1 of 2: CT 201 \(first-a\), CT 202 \(first-b\) ===/,
        'the log names the position and everything in it',
    );
    like($out, qr/=== position 2 of 2: CT 203 \(second\) ===/, 'and the one after it');
    like(
        $out,
        qr/^\[CT 201\] reading package lists$/m,
        'every line a target prints carries its name - several of them share this log',
    );
    like(
        $out,
        qr/^\[CT 202\] reading package lists$/m,
        'and what the child beside it printed arrived here too',
    );
    like($out, qr/--- CT 201 \(first-a\): OK \(exit 0 after \d+s\)/, 'each gets its own verdict');
    like($out, qr/--- CT 203 \(second\): OK/, 'the last one included');
    like($out, qr/3 ok, 0 failed, 0 skipped, 3 total/, 'and the summary counts the whole run');

    # The state files are written by the children, and they are what the grid
    # reads: a row that stays on "running" because the process that owned it went
    # away without writing is the failure mode this checks for.
    for my $vmid (201, 202, 203) {
        is(
            PVE::UpdateManager::Config::last_run('lxc', $vmid)->{last_state},
            'ok',
            "the row of CT $vmid was written by the child that updated it",
        );
    }
}

# The control: the same three targets, the same rendezvous switched off, and no
# parallel flag. One at a time, in the order the numbers give - which is what a
# serial run always did and must keep doing.
{
    my $events = "$dir/serial-events";
    unlink($events);

    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        my $vmid = vmid_of_call($cmd);
        note_event($events, "start $vmid");
        note_event($events, "end $vmid");
    };

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all($waves, 60);
        },
    );

    is_deeply(
        events_of($events),
        ['start 201', 'end 201', 'start 202', 'end 202', 'start 203', 'end 203'],
        'a serial run finishes each target before it starts the next',
    );
    like($out, qr/=== \[1\/3\] CT 201 \(first-a\) ===/, 'and its log is the numbered one, unchanged');
    unlike($out, qr/=== position /, 'with no positions in it');
    unlike($out, qr/^\[CT 201\] /m, 'and no prefixes either - one process owns this log');
}

# A failure in one target of a position must not take its neighbour down with it,
# and must not stop the position after it either. The whole point of a batch is
# that it reports on all of it.
{
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return vmid_of_call($cmd) == 201 ? 100 : 0;
    };
    local $PVE::Tools::RUN_RC = 0;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all($waves, 60, { parallel => 1 });
        },
    );

    like($out, qr/--- CT 201 \(first-a\): FAILED \(exit 100/, 'the one that failed is named');
    like($out, qr/--- CT 202 \(first-b\): OK/, 'the one beside it still ran');
    like($out, qr/--- CT 203 \(second\): OK/, 'and so did the position after it');
    like($out, qr/2 ok, 1 failed, 0 skipped, 3 total/, 'the summary counts all three');
    like($err // '', qr/1 of 3 update targets failed/, 'and the task goes red');
    is(
        PVE::UpdateManager::Config::last_run('lxc', 201)->{last_state},
        'failed',
        "and the failing container's own row says so",
    );
}

# A note that carries a newline must not be able to forge a field on the way from
# a child back to its parent. The report is one record per line, so a note ending
# in "\nrc=0" turns a failed target into an OK one - in the verdict, in the
# summary and in the exit code of the whole job.
#
# Not a hypothetical shape: a note is built out of whatever PVE said, and
# "could not be snapshotted before the update - $err" carries a storage error
# through verbatim. lvm and zfs both answer in more than one line.
{
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC_HOOK = undef;
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::Config::SNAPSHOT_DIE = "thin pool is full\nrc=0\nnote=all fine";
    delete $PVE::LXC::Config::CONFIGS{201}->{snapshots};

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 201, name => 'first-a' }],
                60,
                { parallel => 1, snapshot_before => 1, snapshot_keep => 3 },
            );
        },
    );

    like($out, qr/--- CT 201 \(first-a\): FAILED/, 'the target still comes out FAILED');
    like($out, qr/0 ok, 1 failed, 0 skipped, 1 total/, 'and is counted as one');
    like($err // '', qr/1 of 1 update targets failed/, 'and the job goes red for it');
    like(
        $out,
        qr/thin pool is full rc=0 note=all fine/,
        'the whole reason is still reported - flattened onto one line, not cut at it',
    );
}

# ── the notification at the end of a run ────────────────────────────────────
#
# After the whole run, once, and only when something actually failed. Sent from
# here rather than from run_one because only the job knows the run is over - which
# is the other half of why a parallel run is one task now.
{
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC_HOOK = undef;
    local $PVE::Tools::RUN_RC = 100;
    local @PVE::Notify::SENT = ();

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                    { type => 'lxc', id => 104, name => 'later-one' },
                ],
                60,
                { notify_failure => 1 },
            );
        },
    );

    is(scalar(@PVE::Notify::SENT), 1, 'two failed targets are ONE notification, not two');
    is(
        scalar(@{ $PVE::Notify::SENT[0]->{data}->{'failed-targets'} }),
        2,
        'and both of them are in it',
    );
    like($err // '', qr/2 of 2 update targets failed/, 'the task still goes red');
    like(
        $out,
        qr/a notification about the failed targets was handed to Proxmox/,
        'and the log says it went out - otherwise "nobody got a mail" has no evidence either way',
    );
}

{
    local $PVE::Tools::RUN_RC = 0;
    local @PVE::Notify::SENT = ();

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60,
                { notify_failure => 1 },
            );
        },
    );

    is(scalar(@PVE::Notify::SENT), 0, 'a run that worked notifies nobody');
}

{
    local $PVE::Tools::RUN_RC = 100;
    local @PVE::Notify::SENT = ();

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60,
                { notify_failure => 0 },
            );
        },
    );

    is(scalar(@PVE::Notify::SENT), 0, 'and switching it off really switches it off');
    unlike($out, qr/notification/, 'without claiming otherwise in the log');
}

# ── a target that crashes instead of returning an exit code ─────────────────
#
# run_one turns nearly everything into an exit code. A script file above the size
# limit is the exception that is actually reachable: load_script dies on it, and a
# hand-written oversized file in /etc/pve is the case has_script already carries a
# comment about. Before the guard, a serial run died at that target's banner - no
# verdict, no summary, and every target after it never attempted. Both modes, the
# same claim, because two modes that answer the same input differently is the bug
# underneath most of this file.
for my $mode ('serial', 'parallel') {
    my $opts = { parallel => ($mode eq 'parallel' ? 1 : 0) };

    for my $vmid (301, 302) {
        PVE::UpdateManager::Config::save_script('lxc', $vmid, "apt-get update\n");
        $PVE::LXC::RUNNING{$vmid} = 7000 + $vmid;
    }
    # Written past the limit directly: save_script refuses it, which is the point
    # - only a hand-edited file gets here.
    PVE::Tools::file_set_contents(
        PVE::UpdateManager::Config::script_file('lxc', 301),
        'x' x ($PVE::UpdateManager::Config::MAX_SCRIPT_SIZE + 10),
    );
    PVE::UpdateManager::Config::save_state('lxc', 301, { state => 'ok', exit => 0 });

    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC_HOOK = undef;
    local $PVE::Tools::RUN_RC = 0;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 301, name => 'broken' },
                    { type => 'lxc', id => 302, name => 'fine' },
                ],
                60, $opts,
            );
        },
    );

    like(
        $out,
        qr/--- CT 301 \(broken\): FAILED \(the update crashed - .*too long/,
        "$mode: a target that crashes is that target's failure, and says what happened",
    );
    like($out, qr/--- CT 302 \(fine\): OK/, "$mode: and the target after it still runs");
    like($out, qr/1 ok, 1 failed, 0 skipped, 2 total/, "$mode: the summary counts both");
    like($err // '', qr/1 of 2 update targets failed/, "$mode: the job goes red for it");

    # The row, not only the log: run_one died before it could record anything, so
    # without this the grid would keep showing the green tick of the run before.
    my $state = PVE::UpdateManager::Config::last_run('lxc', 301);
    is($state->{last_state}, 'failed', "$mode: and the target's own row says failed");
    like($state->{last_note} // '', qr/crashed/, "$mode: with the reason on it");

    unlink(PVE::UpdateManager::Config::script_file('lxc', 301));
}

# ── a child of a wave that is killed rather than finishing ──────────────────
#
# The container may still be locked and the update may be half done, so a child
# that never reported is a failure and not a shrug. Provoked by having the target
# kill its own process mid-run, which is what an OOM kill looks like from here.
{
    PVE::UpdateManager::Config::save_script('lxc', 303, "apt-get update\n");
    $PVE::LXC::RUNNING{303} = 7303;

    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        kill('KILL', $$) if vmid_of_call($cmd) == 303;
    };

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 303, name => 'doomed' }],
                60, { parallel => 1 },
            );
        },
    );

    like(
        $out,
        qr/--- CT 303 \(doomed\): FAILED \(its process died without reporting a result \(killed by signal 9\)\)/,
        'a child that was killed is reported as a failure, and the signal is named',
    );
    like($out, qr/0 ok, 1 failed, 0 skipped, 1 total/, 'and counted as one');
    like($err // '', qr/1 of 1 update targets failed/, 'the job goes red rather than quiet');
}

# ── the wave when the kernel will not fork ─────────────────────────────────
#
# The fallback runs the target in this process instead. Slower than it should be
# and still updated, which beats failing a container because the machine was out
# of processes for a moment. Reached through the $FORK hook: it cannot be
# provoked otherwise without exhausting the host, and a fallback in a root job
# that has never once run is not a fallback, it is a guess.
{
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_OUTPUT = ['reading package lists'];
    local $PVE::UpdateManager::Job::FORK = sub { return undef };

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 201, name => 'first-a' },
                    { type => 'lxc', id => 202, name => 'first-b' },
                ],
                60, { parallel => 1 },
            );
        },
    );

    ok(!defined($err), 'a wave that cannot fork still finishes');
    like($out, qr/WARNING: could not fork for CT 201 \(first-a\)/, 'and says so, per target');
    like($out, qr/--- CT 201 \(first-a\): OK/, 'the first one is updated anyway');
    like($out, qr/--- CT 202 \(first-b\): OK/, 'and so is the second');
    like($out, qr/2 ok, 0 failed, 0 skipped, 2 total/, 'both counted');
    like(
        $out,
        qr/^\[CT 201\] reading package lists$/m,
        'its output still carries the target it belongs to',
    );
    is(
        PVE::UpdateManager::Config::last_run('lxc', 201)->{last_state},
        'ok',
        'and the row was written by the process that did the work',
    );
}

# ── the things a wave must not lose ────────────────────────────────────────
{
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC = 0;

    # The same target twice is one target, in a parallel run as in a serial one:
    # two children snapshotting one container in the same second is the second
    # snapshot failing outright on a name PVE already has.
    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 201, name => 'first-a' },
                    { type => 'lxc', id => 201, name => 'first-a' },
                ],
                60, { parallel => 1 },
            );
        },
    );
    like($out, qr/1 ok, 0 failed, 0 skipped, 1 total/, 'a duplicate target is one target');
    like($out, qr/=== position 1 of 1: CT 201 \(first-a\) ===/, 'and one position of one');

    # A skip decided inside a child has to come back as a skip, not as a failure:
    # "nothing stored to run here" is an answer and it belongs on the row.
    ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 299, name => 'no-script' }],
                60, { parallel => 1 },
            );
        },
    );
    like(
        $out,
        qr/--- CT 299 \(no-script\): SKIPPED \(no update script stored\)/,
        'a skip travels back from the child as a skip',
    );
    like($out, qr/0 ok, 0 failed, 1 skipped, 1 total/, 'and is counted as one');
    is(
        PVE::UpdateManager::Config::last_run('lxc', 299)->{last_state},
        'skipped',
        'with the row written by the child that decided it',
    );

    # And a run of nothing is a run of nothing rather than a division by zero or
    # a die. The endpoints refuse an empty selection, so this is the belt.
    my ($empty, $eerr) = capture(
        sub { PVE::UpdateManager::Job::run_all([], 60, { parallel => 1 }) },
    );
    ok(!defined($eerr), 'no targets is not a failure');
    like($empty, qr/0 ok, 0 failed, 0 skipped, 0 total/, 'and says so');
}

# The output ceiling is per target and enforced inside the child, so the note it
# produces has to survive the trip back - otherwise a log that simply stops
# mid-sentence is the only sign anything was dropped.
{
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::UpdateManager::Job::MAX_OUTPUT_BYTES = 64;
    local $PVE::Tools::RUN_OUTPUT = [map { "line $_ of a chatty script" } (1 .. 20)];

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 201, name => 'first-a' }],
                60, { parallel => 1 },
            );
        },
    );

    like($out, qr/output limit of/, 'the child says in the log that it stopped writing');
    like(
        $out,
        qr/--- CT 201 \(first-a\): OK \(exit 0 after \d+s, \d+ further output lines not logged\)/,
        'and the count comes back through the pipe onto the verdict line',
    );
}

# ── the facts a failed target hands back ───────────────────────────────────
#
# The notification puts each of these on a line of its own, so each of them has
# to arrive: which snapshot there is, whether the run went back to it, and how
# long the target ran before it failed. In a parallel run they travel from a
# forked child through a pipe, which is the half that can silently lose them.
for my $mode ('serial', 'parallel') {
    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC = 0;
    # Only the UPDATE fails. Without this, the `pct start` that puts the
    # container back after the rollback fails too, and the claim below would be
    # about the fixture rather than about what the notification says.
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return ($cmd->[1] // '') eq 'exec' ? 100 : 0;
    };
    local @PVE::Notify::SENT = ();
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    # PVE stops a container to roll it back and leaves it stopped, and the stub is
    # faithful about it - so without this the second pass through this loop finds
    # the container the first pass rolled back and skips it, and every claim below
    # would be about a run that never happened.
    local $PVE::LXC::RUNNING{101} = 4711;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60,
                {
                    parallel => ($mode eq 'parallel' ? 1 : 0),
                    snapshot_before => 1, snapshot_keep => 3,
                    rollback_on_failure => 1, notify_failure => 1,
                },
            );
        },
    );

    is(scalar(@PVE::Notify::SENT), 1, "$mode: the failure was notified");

    my $block = $PVE::Notify::SENT[0]->{data}->{'failed-targets'}->[0];
    is($block->{target}, 'CT 101 (nextcloud)', "$mode: the target is named");
    is($block->{exit}, 100, "$mode: with the exit code its script gave");
    like($block->{snapshot}, qr/\Aupdmgr-\d{8}-\d{6}\z/, "$mode: and the snapshot by name");
    like(
        $block->{rollback},
        qr/\Ayes - the update was taken back/,
        "$mode: and the fact that the run already went back to it",
    );
    like($block->{finished}, qr/\A\d+\z/, "$mode: with a time the renderer can print");
    like($block->{ran}, qr/\A\d+\z/, "$mode: and a duration");

    # The one that cannot be seen any other way: a snapshot name that never made
    # it across the pipe would leave the operator with a mail that says a
    # rollback point exists and does not say which.
    like(
        $out,
        qr/rolled back to updmgr-\d{8}-\d{6}/,
        "$mode: and the task log says the same thing",
    );
    like($err // '', qr/1 of 1 update targets failed/, "$mode: the job goes red");
}

# ── the log a run leaves behind ────────────────────────────────────────────
#
# Per target, kept beside the script, with the retention count the node's
# settings carry. It has to be written on EVERY exit of run_one - the target that
# was skipped is exactly the one somebody wonders about later - and it has to be
# written by the forked child in a parallel wave, which is the half that can
# silently lose it.
for my $mode ('serial', 'parallel') {
    my $logdir = "$dir/runlogs-$mode";
    local $PVE::UpdateManager::Logs::LOG_DIR = $logdir;

    local $PVE::Tools::RUN_HOOK = undef;
    local $PVE::Tools::RUN_RC_HOOK = undef;
    local $PVE::Tools::RUN_RC = 100;
    local $PVE::Tools::RUN_OUTPUT = ['Reading package lists...', 'E: broken'];
    local $PVE::LXC::RUNNING{101} = 4711;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                    { type => 'lxc', id => 102, name => 'gitea' },
                ],
                60,
                { parallel => ($mode eq 'parallel' ? 1 : 0), run_logs => 3 },
            );
        },
    );

    # CT 102 has no script and is skipped, so this is both cases at once.
    my $ran = PVE::UpdateManager::Logs::list_logs('lxc', 101);
    my $skipped = PVE::UpdateManager::Logs::list_logs('lxc', 102);
    is(scalar(@$ran), 1, "$mode: the target that ran left a log");
    is(scalar(@$skipped), 1, "$mode: and so did the one that was skipped");

    # Defensively, so a claim that fails does not take the rest of them with it:
    # load_log dies on an undefined stamp, and a mutation probe that kills the
    # script hides every assertion after the first one it broke.
    my $text = scalar(@$ran)
        ? PVE::UpdateManager::Logs::load_log('lxc', 101, $ran->[0]->{log})
        : '';
    like($text, qr/^target:\s+CT 101 \(nextcloud\)$/m, "$mode: the log says which target");
    like($text, qr/^result:\s+FAILED \(exit 100 after \d+s\)$/m, "$mode: and how it went");
    like($text, qr/^started:\s+\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/m, "$mode: and when it started");
    like($text, qr/^Reading package lists\.\.\.$/m, "$mode: with what the command printed");
    like($text, qr/^E: broken$/m, 'including the line that says why it broke');
    # The prefix belongs to the shared task log, not to a file about one target.
    unlike($text, qr/\[CT 101\]/, "$mode: and without the task log's per-target prefix");

    my $skiptext = scalar(@$skipped)
        ? PVE::UpdateManager::Logs::load_log('lxc', 102, $skipped->[0]->{log})
        : '';
    like(
        $skiptext,
        qr/^result:\s+SKIPPED \(no update script stored\)$/m,
        "$mode: a skip is logged as a skip, with the reason",
    );
}

# Switched off, nothing is written - and the run is not otherwise different.
{
    my $logdir = "$dir/runlogs-off";
    local $PVE::UpdateManager::Logs::LOG_DIR = $logdir;
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::RUNNING{101} = 4711;

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60, { run_logs => 0 },
            );
        },
    );

    is_deeply(
        PVE::UpdateManager::Logs::list_logs('lxc', 101),
        [],
        'a retention of 0 keeps no run logs',
    );
    ok(!-d $logdir, 'and the directory is not even created');
    like($out, qr/1 ok, 0 failed, 0 skipped, 1 total/, 'while the run itself is unchanged');
}

# A log that cannot be written must not turn a run that happened into a failure.
{
    local $PVE::UpdateManager::Logs::LOG_DIR = "/proc/cannot/write/here";
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::RUNNING{101} = 4711;

    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60, { run_logs => 3 },
            );
        },
    );

    ok(!defined($err), 'the run succeeds even though its log could not be kept');
    like($out, qr/1 ok, 0 failed, 0 skipped, 1 total/, 'and is reported as it happened');
    like($warned, qr/cannot create|unable to keep/, 'with the reason in the syslog, not swallowed');
}
