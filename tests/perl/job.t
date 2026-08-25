#!/usr/bin/perl
# PVE::UpdateManager::Job - what the task log says, and when the task goes red.
#
# This is the part an operator reads at 2am, so the shape of the log is worth a
# test: a banner per target, a verdict per target, a summary that distinguishes
# "skipped" from "failed", and a die at the end if - and only if - something
# actually failed.

use strict;
use warnings;

use File::Path ();
use File::Temp qw(tempdir);
use IO::Handle;
use Test::More tests => 201;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Notify;
use PVE::ProcFSTools;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Runner;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

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

# ── a mixed run: one works, one has no script, one is stopped ───────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                    { type => 'lxc', id => 102, name => 'gitea' },
                    { type => 'lxc', id => 103, name => 'stopped-one' },
                ],
                60,
            );
        },
    );

    ok(!defined($err), 'nothing failed, so the task does not die');
    like($out, qr/=== \[1\/3\] CT 101 \(nextcloud\) ===/, 'a banner names the target and its place');
    like($out, qr/--- CT 101 \(nextcloud\): OK/, 'the one that ran is reported OK');
    like($out, qr/--- CT 102 \(gitea\): SKIPPED \(no update script stored\)/, 'no script is a skip');
    like(
        $out,
        qr/--- CT 103 \(stopped-one\): SKIPPED \(container is not running\)/,
        'a stopped container is a skip, and says which kind',
    );
    like($out, qr/1 ok, 0 failed, 2 skipped, 3 total/, 'the summary counts all three states');
    is(scalar(@PVE::Tools::RUN_CALLS), 1, 'only the runnable target was executed');
}

# ── a failing target ────────────────────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 100;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60,
            );
        },
    );

    like($out, qr/--- CT 101 \(nextcloud\): FAILED \(exit 100/, 'the failure is in the log');
    like($out, qr/0 ok, 1 failed, 0 skipped, 1 total/, 'and in the summary');
    like($err // '', qr/1 of 1 update targets failed/, 'and the task itself goes red');
}

# ── a failure must not stop the batch ───────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    $PVE::LXC::RUNNING{104} = 4712;
    PVE::UpdateManager::Config::save_script('lxc', 104, "apt-get update\n");

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                    { type => 'lxc', id => 104, name => 'later-one' },
                ],
                60,
            );
        },
    );

    is(scalar(@PVE::Tools::RUN_CALLS), 2, 'the target after the failing one still runs');
    like($out, qr/0 ok, 2 failed, 0 skipped, 2 total/, 'both are counted');
    like($err // '', qr/2 of 2 update targets failed/, 'the task reports how many');
}

# ── the host is a target like any other ─────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'node', id => 'pve-test' }], 60);
        },
    );

    ok(!defined($err), 'the host run succeeds');
    like($out, qr/=== \[1\/1\] Host pve-test ===/, 'and is labelled Host, not CT');
    unlike(
        $PVE::Tools::RUN_CALLS[0]->{cmd}->[0],
        qr/pct/,
        'the host script is not run through pct',
    );
}

# ── what the grids read: the state file per target ──────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $0 = 'task UPID:pve-test:0000AAAA:00000001:6A80A49D:updatemgr:pve-test:root@pam:';

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                    { type => 'lxc', id => 102, name => 'gitea' },
                    { type => 'lxc', id => 103, name => 'stopped-one' },
                ],
                60,
            );
        },
    );

    my $ok = PVE::UpdateManager::Config::load_state('lxc', 101);
    is($ok->{state}, 'ok', 'a target that ran is recorded as ok');
    is(
        $ok->{upid},
        'UPID:pve-test:0000AAAA:00000001:6A80A49D:updatemgr:pve-test:root@pam:',
        'with the upid of the task that ran it, so the row can link to that log',
    );
    ok($ok->{finished} >= $ok->{started}, 'and a finished timestamp');

    is(
        PVE::UpdateManager::Config::load_state('lxc', 102)->{note},
        'no update script stored',
        'a target with no script records WHY it was skipped',
    );
    is(
        PVE::UpdateManager::Config::load_state('lxc', 103)->{note},
        'container is not running',
        'and a stopped one records its own reason',
    );
}

# ── the spinner: "running" has to be on disk BEFORE the command, not after ──
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    my $seen;
    local $PVE::Tools::RUN_HOOK = sub {
        $seen = PVE::UpdateManager::Config::load_state('lxc', 101);
    };

    capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    is($seen->{state}, 'running', 'while the command runs, the row shows running');
}

# ── current_upid ────────────────────────────────────────────────────────────
{
    local $0 = 'task UPID:pve-test:0000AAAA:00000001:6A80A49D:ctupdate:101:root@pam:';
    is(
        PVE::UpdateManager::Job::current_upid(),
        'UPID:pve-test:0000AAAA:00000001:6A80A49D:ctupdate:101:root@pam:',
        'the worker finds its own upid in $0, which is where fork_worker puts it',
    );
}
{
    local $0 = '/usr/bin/pvedaemon';
    ok(
        !defined(PVE::UpdateManager::Job::current_upid()),
        'and outside a worker there simply is none - no log link, no crash',
    );
}

# ── the task log cannot grow without bound ──────────────────────────────────
#
# Regression guard for a measured bug. A worker's STDOUT is the task log file
# itself, Proxmox never rotates those files, and a script printing in a loop
# wrote 103 MB in 3 seconds on the test node - straight onto the root
# filesystem. The cap cuts the log, not the run.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    # Fixed-width lines so the arithmetic is exact: 24 characters plus the
    # newline is 25 bytes, so exactly 4 of them fit under 100 and the remaining
    # 16 are dropped - including the one that crosses the line, which used to
    # go uncounted.
    local $PVE::UpdateManager::Job::MAX_OUTPUT_BYTES = 100;
    local $PVE::Tools::RUN_OUTPUT = [map { sprintf('%-24s', "line $_") } 1 .. 20];

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    like($out, qr/line 1\b/, 'output below the cap is logged as before');
    unlike($out, qr/line 20\b/, 'output past the cap is not');
    like($out, qr/output limit of .* reached/, 'and the log says it was cut rather than just stopping');
    is(scalar(() = $out =~ m/^line \d+\s*$/mg), 4, 'exactly what fits under the cap is logged');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/\b16 further output lines not logged/,
        'and every dropped line is counted, including the one that crossed the limit',
    );
}

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_OUTPUT = ['a short line', 'another one'];

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    like($out, qr/another one/, 'a normal run still logs everything');
    unlike($out, qr/output limit/, 'and says nothing about limits');
    ok(
        !defined(PVE::UpdateManager::Config::load_state('lxc', 101)->{note}),
        'a clean run leaves no note, so the grid keeps showing just the tick',
    );
}

# ── a timeout reads as a timeout, not as an exit code ───────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = $PVE::UpdateManager::Runner::TIMEOUT_RC;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    like($out, qr/timed out after \d+s/, 'the summary names the timeout');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/timed out/,
        'and so does the row',
    );
    is(PVE::UpdateManager::Config::load_state('lxc', 101)->{state}, 'failed', 'a timeout is a failure');
    like($err // '', qr/1 of 1/, 'and it turns the task red');
}

# ── one target, one run at a time ───────────────────────────────────────────
#
# Regression guard for a measured bug: two Update presses started two workers
# in the same container, both running apt, and the second one's UPID replaced
# the first one's in the row while the first was still going.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $0 = 'task UPID:pve-test:0000BBBB:00000002:6A80A49D:ctupdate:105:root@pam:';

    $PVE::LXC::RUNNING{105} = 4713;
    PVE::UpdateManager::Config::save_script('lxc', 105, "apt-get update\n");

    # Somebody else's run, still in flight, with a worker that is alive.
    PVE::UpdateManager::Config::save_state(
        'lxc', 105,
        {
            state => 'running',
            upid => "UPID:pve-test:" . sprintf('%08X', $$) . ":00000001:6A80A49D:ctupdate:105:root\@pam:",
            started => time(),
        },
    );

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 105, name => 'busy-one' }], 60);
        },
    );

    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'a target that is already updating is not started again');
    like($out, qr/SKIPPED \(already being updated/, 'and the log says why');
    ok(!defined($err), 'a target that was busy is a skip, not a failure');

    my $state = PVE::UpdateManager::Config::load_state('lxc', 105);
    is($state->{state}, 'running', 'the running row is left alone, not overwritten with our skip');
    like($state->{upid}, qr/:00000001:/, 'and still points at the task that is actually running');
}

# A lock that cannot be taken must refuse, not run anyway.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::LOCK_DIE = 'can\'t lock file - got timeout';

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'no lock, no run');
    like($out, qr/SKIPPED/, 'and it is reported rather than swallowed');
}

# The staleness rule still wins: a target whose worker is gone is not busy.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::ProcFSTools::ALIVE = 0;

    $PVE::LXC::RUNNING{106} = 4714;
    PVE::UpdateManager::Config::save_script('lxc', 106, "apt-get update\n");
    PVE::UpdateManager::Config::save_state(
        'lxc', 106,
        {
            state => 'running',
            upid => 'UPID:pve-test:0000FFFF:00000001:6A80A49D:ctupdate:106:root@pam:',
            started => time(),
        },
    );

    capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 106, name => 'stale-one' }], 60);
        },
    );

    is(
        scalar(@PVE::Tools::RUN_CALLS),
        1,
        'a killed worker does not make a container un-updatable for ever',
    );
}

# ── starting a stopped container for its update, then putting it back ────────
#
# Off by default and opt-in per node. What matters here is the shape of the
# sequence - start, update, stop - and that the last step happens even when the
# middle one fails, because a container left running is a change to the system
# that outlives the task nobody reads afterwards.

# Which pct verb a recorded call was. The update and the readiness probe are
# both `pct exec`, so they are told apart by the script they carry.
sub pct_verbs {
    return map {
        my $c = $_->{cmd};
        my $verb = $c->[1] // '';
        if ($verb eq 'exec') {
            $verb = ($c->[6] // '') eq $PVE::UpdateManager::Runner::ONLINE_PROBE
                ? 'probe'
                : 'update';
        }
        $verb;
    } @PVE::Tools::RUN_CALLS;
}

$PVE::LXC::RUNNING{110} = undef;
PVE::UpdateManager::Config::save_script('lxc', 110, "apt-get update\n");

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 110, name => 'off-one' }], 60);
        },
    );

    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'without the setting a stopped container is still skipped');
    like($out, qr/SKIPPED \(container is not running\)/, 'and says so, exactly as before');
}

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 110, name => 'off-one' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    is_deeply(
        [pct_verbs()],
        ['start', 'probe', 'update', 'shutdown'],
        'with the setting: started, waited for, updated, and shut down again',
    );
    ok(!defined($err), 'and the run succeeds');
    is(
        PVE::UpdateManager::Config::load_state('lxc', 110)->{state},
        'ok',
        'the row records the update, not the starting',
    );
}

{
    local @PVE::Tools::RUN_CALLS = ();
    # Everything works except the update itself.
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return 1 if ($cmd->[1] // '') eq 'exec'
            && ($cmd->[6] // '') ne $PVE::UpdateManager::Runner::ONLINE_PROBE;
        return 0;
    };

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 110, name => 'off-one' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    is(
        (pct_verbs())[-1],
        'shutdown',
        'a FAILED update still puts the container back - the one outcome nobody asked for'
            . ' is leaving it running',
    );
    is(
        PVE::UpdateManager::Config::load_state('lxc', 110)->{state},
        'failed',
        'and the failure is still recorded as one',
    );
}

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return 1 if ($cmd->[1] // '') eq 'start';
        return 0;
    };

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 110, name => 'off-one' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    is_deeply([pct_verbs()], ['start'], 'a container that will not start is not then updated');
    like($out, qr/FAILED \(could not be started/, 'and it is a failure, not a skip - it was asked for');
    is(PVE::UpdateManager::Config::load_state('lxc', 110)->{state}, 'failed', 'recorded as failed');
}

{
    local @PVE::Tools::RUN_CALLS = ();
    # Neither the graceful shutdown nor the hard stop works.
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        my $verb = $cmd->[1] // '';
        return 1 if $verb eq 'shutdown' || $verb eq 'stop';
        return 0;
    };

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 110, name => 'off-one' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    is((pct_verbs())[-1], 'stop', 'a graceful shutdown that fails falls back to a hard stop');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 110)->{note},
        qr/could NOT be stopped again/,
        'and a container left running says so on its row, not only in the log',
    );
}

# A container that was already up is left up: we put things back as found, and
# it was not found stopped.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 101, name => 'nextcloud' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    is_deeply(
        [pct_verbs()],
        ['update'],
        'a running container is neither started nor stopped by the setting',
    );
}

# ── nothing gets switched off in the middle of its own update ────────────────
#
# Proxmox refuses to stop, shut down, reboot or migrate a locked guest - every
# one of those paths calls check_lock - so the lock is the whole mechanism. What
# has to hold is that it is taken, and that it is always given back.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::Config::LOCKS = ();

    my $held;
    local $PVE::Tools::RUN_HOOK = sub {
        $held = $PVE::LXC::Config::LOCKS{101};
    };

    capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    is($held, 'mounted', 'the container is locked while its update runs');
    is_deeply(\%PVE::LXC::Config::LOCKS, {}, 'and unlocked again when it is over');
}

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::Config::LOCKS = ();

    capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    is_deeply(
        \%PVE::LXC::Config::LOCKS,
        {},
        'a FAILED update gives the lock back too - otherwise one bad run leaves a'
            . ' container nobody can stop',
    );
}

# Somebody else's lock is a reason not to update, not something to overwrite.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::Config::LOCKS = (101 => 'backup');

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nextcloud' }], 60);
        },
    );

    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'a container being backed up is not updated on top');
    like($out, qr/SKIPPED \(another task holds the lock/, 'and the log says whose lock stopped it');
    is($PVE::LXC::Config::LOCKS{101}, 'backup', 'the other task keeps its lock');
}

# The lock has to be gone before we try to stop the container ourselves - it is
# the same lock PVE checks in vm_shutdown, so holding it would block our own
# shutdown and the guard would defeat what it guards.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::Config::LOCKS = ();

    my $locked_at_shutdown;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        $locked_at_shutdown = $PVE::LXC::Config::LOCKS{110}
            if ($cmd->[1] // '') eq 'shutdown';
    };

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 110, name => 'off-one' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    ok(!$locked_at_shutdown, 'the lock is released before we shut the container down again');
    is_deeply(\%PVE::LXC::Config::LOCKS, {}, 'and nothing is left holding it');
}

# A container that cannot be started must not keep the lock either.
{
    local @PVE::Tools::RUN_CALLS = ();
    local %PVE::LXC::Config::LOCKS = ();
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return 1 if ($cmd->[1] // '') eq 'start';
        return 0;
    };

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 110, name => 'off-one' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    is_deeply(
        \%PVE::LXC::Config::LOCKS,
        {},
        'a container that would not start is not left locked and unstoppable',
    );
}

# ── the order a serial run walks its targets in ─────────────────────────────
#
# One place decides it - run_all - so the timer and the buttons cannot drift
# apart. What is checked here is that the decision reaches the log: the banners
# are the record of what was actually done first.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    for my $vmid (120, 121, 122) {
        $PVE::LXC::RUNNING{$vmid} = 4700 + $vmid;
        PVE::UpdateManager::Config::save_script('lxc', $vmid, "apt-get update\n");
    }

    my $targets = [
        { type => 'lxc', id => 120, name => 'web' },
        { type => 'lxc', id => 121, name => 'db' },
        { type => 'lxc', id => 122, name => 'cache' },
    ];

    my ($out) = capture(sub { PVE::UpdateManager::Job::run_all($targets, 60) });
    my @banners = $out =~ m/=== \[\d\/3\] CT (\d+)/g;
    is_deeply(\@banners, [120, 121, 122], 'with nothing set the list is walked as it arrived');

    PVE::UpdateManager::Config::save_order('lxc', 121, 1);
    PVE::UpdateManager::Config::save_order('lxc', 122, 2);

    ($out) = capture(sub { PVE::UpdateManager::Job::run_all($targets, 60) });
    @banners = $out =~ m/=== \[\d\/3\] CT (\d+)/g;
    is_deeply(
        \@banners,
        [121, 122, 120],
        'the database goes before the two that talk to it, and the one with no number goes last',
    );

    # The banner counts positions, not targets, so a reordered run still reads
    # as 1 of 3, 2 of 3, 3 of 3 in the order they actually happen.
    like($out, qr/=== \[1\/3\] CT 121/, 'and the numbering follows the new order');

    PVE::UpdateManager::Config::save_order('lxc', 121, 0);
    PVE::UpdateManager::Config::save_order('lxc', 122, 0);
}

# ── a container that is not on this node ────────────────────────────────────
#
# The scripts live in /etc/pve and are the same on every node, so a target that
# has migrated away is found here with its commands intact and nothing further
# down notices. What check_running() then answers is "not running" - true, it
# looks for a cgroup this node does not have, and wrong, because the container
# is running perfectly well somewhere else.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::Config::NO_CONFIG = (130 => 1);

    PVE::UpdateManager::Config::save_script('lxc', 130, "apt-get update\n");

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 130, name => 'moved-away' }],
                60,
                { start_stopped => 1 },
            );
        },
    );

    ok(!defined($err), 'it is a skip, not a failure - nothing is broken');
    like(
        $out,
        qr/SKIPPED \(not a container on this node\)/,
        'and the reason names what is actually the case',
    );
    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'nothing was run against it');
    is(
        PVE::UpdateManager::Config::load_state('lxc', 130)->{note},
        'not a container on this node',
        'the row says the same, so a schedule that keeps skipping it can be understood',
    );
}

# ── the run leaves pvedaemon's control group before it starts ──────────────
#
# A package whose postinst restarts pvedaemon kills every process in that unit,
# and until the worker has moved out, this job and its dist-upgrade are two of
# them. So the move has to happen BEFORE the first target is touched - a worker
# that detaches after it started apt-get has protected nothing.
{
    my @asked;
    no warnings 'redefine';
    local *PVE::UpdateManager::Runner::detach_from_daemon = sub {
        push @asked, scalar(@PVE::Tools::RUN_CALLS);
        return 1;
    };
    use warnings 'redefine';

    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'nc' }], 600);
        },
    );

    is(scalar(@asked), 1, 'a run asks once to be moved out of the daemon it was forked by');
    is($asked[0], 0, 'and it asks before it has run a single command');
}

# ── the node is held for as long as the run can actually take ───────────────
#
# The inhibitor is what stops `systemctl poweroff` while an update is running,
# and it is given a deadline rather than being trusted to be killed. A deadline
# that is too short is worse than none: it lets go silently, halfway through a
# batch, and nothing says so.
{
    my @budgets;
    no warnings 'redefine';
    local *PVE::UpdateManager::Runner::inhibit_shutdown = sub {
        my ($seconds) = @_;
        push @budgets, $seconds;
        return undef;
    };
    use warnings 'redefine';

    local $PVE::Tools::RUN_RC = 0;
    my $two = [
        { type => 'lxc', id => 101, name => 'nextcloud' },
        { type => 'lxc', id => 104, name => 'later-one' },
    ];

    capture(sub { PVE::UpdateManager::Job::run_all($two, 600) });
    is(
        $budgets[0],
        600 * 2 + $PVE::UpdateManager::Runner::OUTER_GRACE,
        'a plain run is held for the sum of its timeouts',
    );

    capture(sub { PVE::UpdateManager::Job::run_all($two, 600, { start_stopped => 1 }) });
    is(
        $budgets[1],
        (600 + $PVE::UpdateManager::Runner::PER_TARGET_GRACE) * 2
            + $PVE::UpdateManager::Runner::OUTER_GRACE,
        'a run that starts stopped containers is held for the starting too',
    );

    capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                $two, 600, { snapshot_before => 1, snapshot_shutdown => 1 },
            );
        },
    );
    is($budgets[2], $budgets[1], 'and so is one that shuts them down for their snapshot');

    capture(
        sub {
            PVE::UpdateManager::Job::run_all($two, 600, { snapshot_shutdown => 1 });
        },
    );
    is(
        $budgets[3],
        $budgets[0],
        'but not one where the setting cannot fire, because snapshots are off',
    );
}

# ── a template is not a container that happens to be off ────────────────────
#
# PVE refuses to start one and refuses to snapshot one, so with 'start stopped
# containers' on it came out of a run as a FAILED target - for something there
# was never anything to do for. Select All picks templates up, which is how one
# gets into a run at all.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    $PVE::LXC::RUNNING{140} = undef;
    $PVE::LXC::Config::CONFIGS{140} = { template => 1 };
    PVE::UpdateManager::Config::save_script('lxc', 140, "apt-get update\n");

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [{ type => 'lxc', id => 140, name => 'debian-tpl' }],
                60,
                { start_stopped => 1, snapshot_before => 1, snapshot_keep => 3 },
            );
        },
    );

    ok(!defined($err), 'the run does not go red over it');
    like($out, qr/SKIPPED \(this is a template, not a container\)/, 'and says what it is');
    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'nothing was started and nothing was run');
    is_deeply(
        [sort keys %{ $PVE::LXC::Config::CONFIGS{140}->{snapshots} // {} }],
        [],
        'and it was not snapshotted either',
    );

    delete $PVE::LXC::Config::CONFIGS{140};
}

# ── the same target twice is one target ─────────────────────────────────────
#
# A hand-edited schedule_vmids of '101,101' would otherwise update it twice and
# take two snapshots - and the second create fails outright when both land in
# the same second, because the name carries a whole-second timestamp.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                    { type => 'lxc', id => 101, name => 'nextcloud' },
                ],
                60,
                { snapshot_before => 1, snapshot_keep => 3 },
            );
        },
    );

    ok(!defined($err), 'the run succeeds instead of failing on its own snapshot');
    like($out, qr/1 ok, 0 failed, 0 skipped, 1 total/, 'the duplicate is not a second target');
    is(scalar(@PVE::Tools::RUN_CALLS), 1, 'and the container is updated once');
    is(
        scalar(keys %{ $PVE::LXC::Config::CONFIGS{101}->{snapshots} // {} }),
        1,
        'with one snapshot, not two',
    );
}

# ── what a script prints, as the task viewer will show it ───────────────────
#
# Proxmox' log viewer html-encodes every line and joins them with <br>: it
# cannot render a colour, so an escape sequence arrives as visible text and a
# coloured line reads "[0;31m!! Fehler". Colour would take a change to
# Proxmox' own JavaScript, which this addon does not make - so the words are
# made readable instead.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_OUTPUT = [
        "\e[0;31m!! Fehler aufgetreten\e[0m",
        "\e[1;32m>>\e[0m Betriebssystem aktualisiert",
        "\e]0;a title\a done",
        "plain line",
    ];

    my ($out) = capture(
        sub {
            PVE::UpdateManager::Job::run_all([{ type => 'lxc', id => 101, name => 'db' }], 60);
        },
    );

    unlike($out, qr/\e/, 'no escape character survives into the log');
    unlike($out, qr/\[0;31m/, 'and none of the text a viewer would show instead');
    like($out, qr/^!! Fehler aufgetreten$/m, 'what is left is the line the script meant');
    like($out, qr/^>> Betriebssystem aktualisiert$/m, 'markers and all');
    like($out, qr/^plain line$/m, 'a line without any of it is untouched');
}

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
    local $PVE::UpdateManager::Config::LOG_DIR = $logdir;

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
    my $ran = PVE::UpdateManager::Config::list_logs('lxc', 101);
    my $skipped = PVE::UpdateManager::Config::list_logs('lxc', 102);
    is(scalar(@$ran), 1, "$mode: the target that ran left a log");
    is(scalar(@$skipped), 1, "$mode: and so did the one that was skipped");

    # Defensively, so a claim that fails does not take the rest of them with it:
    # load_log dies on an undefined stamp, and a mutation probe that kills the
    # script hides every assertion after the first one it broke.
    my $text = scalar(@$ran)
        ? PVE::UpdateManager::Config::load_log('lxc', 101, $ran->[0]->{log})
        : '';
    like($text, qr/^target:\s+CT 101 \(nextcloud\)$/m, "$mode: the log says which target");
    like($text, qr/^result:\s+FAILED \(exit 100 after \d+s\)$/m, "$mode: and how it went");
    like($text, qr/^started:\s+\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/m, "$mode: and when it started");
    like($text, qr/^Reading package lists\.\.\.$/m, "$mode: with what the command printed");
    like($text, qr/^E: broken$/m, 'including the line that says why it broke');
    # The prefix belongs to the shared task log, not to a file about one target.
    unlike($text, qr/\[CT 101\]/, "$mode: and without the task log's per-target prefix");

    my $skiptext = scalar(@$skipped)
        ? PVE::UpdateManager::Config::load_log('lxc', 102, $skipped->[0]->{log})
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
    local $PVE::UpdateManager::Config::LOG_DIR = $logdir;
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
        PVE::UpdateManager::Config::list_logs('lxc', 101),
        [],
        'a retention of 0 keeps no run logs',
    );
    ok(!-d $logdir, 'and the directory is not even created');
    like($out, qr/1 ok, 0 failed, 0 skipped, 1 total/, 'while the run itself is unchanged');
}

# A log that cannot be written must not turn a run that happened into a failure.
{
    local $PVE::UpdateManager::Config::LOG_DIR = "/proc/cannot/write/here";
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
