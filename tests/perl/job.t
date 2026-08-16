#!/usr/bin/perl
# PVE::UpdateManager::Job - what the task log says, and when the task goes red.
#
# This is the part an operator reads at 2am, so the shape of the log is worth a
# test: a banner per target, a verdict per target, a summary that distinguishes
# "skipped" from "failed", and a die at the end if - and only if - something
# actually failed.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 66;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::ProcFSTools;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Runner;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# Returns (stdout, error). Job writes with print because inside a Proxmox worker
# STDOUT is the task log.
sub capture {
    my ($code) = @_;

    my $out = '';
    open(my $saved, '>&', \*STDOUT) or die "cannot dup STDOUT - $!";
    close(STDOUT);
    open(STDOUT, '>', \$out) or die "cannot redirect STDOUT - $!";

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
