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
use Test::More tests => 92;

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
