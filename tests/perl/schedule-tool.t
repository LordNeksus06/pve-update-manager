#!/usr/bin/perl
# tools/pve-update-manager-schedule, run for real against the stubs.
#
# Until this file the script was only compiled (`perl -c`), so an option it
# forgot to hand to the job reddened nothing: dropping schedule_parallel_max from
# its run_opts call left `make test` green, and so did a mutant that handed VMs
# over as containers (#26). This runs the script's own code - its `run` and
# `status` paths - with the worker's code captured instead of forked, and checks
# what it would have given the job.
#
# The script ends with exit(); CORE::GLOBAL::exit is replaced before the script
# is compiled, so each exit comes back here as a die with its code.

use strict;
use warnings;

use File::Temp qw(tempdir);
use IO::Handle;
use Test::More tests => 31;

BEGIN {
    *CORE::GLOBAL::exit = sub { die sprintf("EXIT %d\n", $_[0] // 0) };
}

use PVE::INotify;
use PVE::LXC::Config;
use PVE::QemuConfig;
use PVE::RPCEnvironment;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Settings;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

my $SCRIPT = 'tools/pve-update-manager-schedule';
my $NODE = $PVE::INotify::NODENAME;

# A container and a VM, so the hand-over can show each arrives as what it is.
$PVE::LXC::Config::CONFIGS{101} = { hostname => 'db' };
$PVE::LXC::Config::NO_CONFIG{200} = 1;
$PVE::QemuConfig::CONFIGS{200} = { name => 'vm-web', agent => '1' };

# Runs the script with these arguments; returns its exit code, what it printed,
# and the job's arguments if a worker was forked and its code was run.
sub run_script {
    my (@args) = @_;

    local @PVE::RPCEnvironment::FORKED = ();
    local @ARGV = @args;

    my $path = "$dir/out.txt";
    open(my $saved, '>&', \*STDOUT) or die "dup: $!";
    close(STDOUT);
    open(STDOUT, '>', $path) or die "redirect: $!";
    STDOUT->autoflush(1);
    # The usage line goes to STDERR; kept out of the test output.
    open(my $saved_err, '>&', \*STDERR) or die "dup: $!";
    open(STDERR, '>>', "$dir/err.txt") or die "redirect: $!";

    my $rc;
    my $err;
    {
        # The script is a file of top-level code; `do` compiles it afresh each
        # time, so every call sees the settings saved just before it.
        local $@;
        # Its sub is defined again on every `do`.
        local $SIG{__WARN__} = sub {
            warn @_ if $_[0] !~ m/Subroutine (?:collect_targets|cli_env|run_schedule|run_security) redefined/;
        };
        do "./$SCRIPT";
        $err = $@;
    }

    close(STDOUT);
    open(STDOUT, '>&', $saved) or die "restore: $!";
    open(STDERR, '>&', $saved_err) or die "restore: $!";

    ($rc) = ($err // '') =~ m/\AEXIT (\d+)/;
    die "the script died: $err" if !defined($rc) && length($err // '');
    $rc //= 0;

    open(my $fh, '<', $path) or die "read: $!";
    my $out = do { local $/; <$fh> } // '';
    close($fh);

    my ($handed, $forked);
    if (($forked) = @PVE::RPCEnvironment::FORKED) {
        no warnings 'redefine';
        local *PVE::UpdateManager::Job::run_all = sub { $handed = [@_] };
        $forked->{code}->();
    }

    return { rc => $rc, out => $out, forked => $forked, handed => $handed };
}

# save_settings keeps last_run to itself (a save from the interface must not
# reset the clock), so the stamp is set the way the scheduler sets it. 1 is a
# second into 1970: the 03:00 after it has long passed, so the schedule is due.
sub settings {
    my (%over) = @_;

    my $last_run = delete($over{last_run}) // 1;
    PVE::UpdateManager::Settings::save_settings($NODE, {
        schedule_enabled => 1,
        schedule_time => '03:00',
        schedule_host => 1,
        schedule_vmids => '101,200',
        %over,
    });
    PVE::UpdateManager::Settings::mark_schedule_run($NODE, $last_run);
}

# ── premise ─────────────────────────────────────────────────────────────────
{
    my $r = run_script('bogus');
    is($r->{rc}, 2, 'premise: the script really runs here - an unknown command exits 2');
}

# ── a due run hands the job what the settings say ───────────────────────────
{
    settings(
        schedule_parallel => 1, schedule_parallel_max => 3, timeout => 1234,
        start_stopped => 1, reboot_vms => 1, snapshot_before => 1, snapshot_keep => 5,
        snapshot_shutdown => 1, rollback_on_failure => 1, rollback_remove_newer => 0,
        notify_failure => 0, run_logs => 7,
    );
    my $r = run_script('run');

    is($r->{rc}, 0, 'a due schedule exits 0');
    ok($r->{forked}, 'and starts a worker');
    is($r->{forked}->{background}, 1,
        'in the background - in a cli environment the worker runs synchronously otherwise');
    is($r->{forked}->{type}, 'updatemgr', 'as an updatemgr task');
    is($r->{forked}->{user}, 'root@pam', 'owned by root@pam');

    my ($targets, $timeout, $opts) = @{ $r->{handed} // [] };
    is_deeply(
        [map { "$_->{type}:$_->{id}" } @{ $targets // [] }],
        ["node:$NODE", 'lxc:101', 'qemu:200'],
        'the host first, then the selected guests - the VM handed over as a VM',
    );
    is($timeout, 1234, 'with the node\'s timeout');

    my $expected = PVE::UpdateManager::Settings::run_opts(
        PVE::UpdateManager::Settings::load_settings($NODE), 1, 3,
    );
    is_deeply($opts, $expected, 'and exactly the options a manual run builds from the same settings');
    is($opts->{parallel}, 1, 'the scheduled parallel switch, not the manual one');
    is($opts->{parallel_max}, 3, 'with the scheduled cap');
    is($opts->{reboot_vms}, 1, 'reboot_vms included');
    is($opts->{start_stopped}, 1, 'start_stopped included');
    is($opts->{snapshot_keep}, 5, 'snapshot_keep included');
    is($opts->{rollback_remove_newer}, 0, 'and a switch that defaults to on, turned off, stays off');

    ok(PVE::UpdateManager::Settings::load_settings($NODE)->{last_run} > 1,
        'the run is stamped, so the next tick does not start it again');
}

{
    settings(schedule_parallel => 0, schedule_parallel_max => 4, parallel_manual => 1, parallel_manual_max => 9);
    my $r = run_script('run');
    my $opts = $r->{handed}->[2];
    is($opts->{parallel}, 0, 'a serial schedule is serial, whatever the manual switch says');
    # run_opts: a cap means nothing without its switch, so a serial run carries none.
    is($opts->{parallel_max}, 0, 'and carries no cap - neither its own nor the manual one');
}

# ── when it does not run ────────────────────────────────────────────────────
{
    settings(schedule_enabled => 0);
    my $r = run_script('run');
    is($r->{rc}, 0, 'a disabled schedule exits 0');
    ok(!$r->{forked}, 'and starts nothing');
}

{
    settings(last_run => time());
    my $r = run_script('run');
    ok(!$r->{forked}, 'a schedule that already ran today starts nothing');
}

{
    settings(schedule_host => 0, schedule_vmids => '');
    my $r = run_script('run');
    ok(!$r->{forked}, 'a due schedule with no targets starts nothing');
    ok(PVE::UpdateManager::Settings::load_settings($NODE)->{last_run} > 1,
        'but is stamped, so it does not report the same every tick');
}

{
    settings();
    no warnings 'redefine';
    local *PVE::UpdateManager::Config::any_target_running = sub { return { type => 'lxc', id => 101 } };
    use warnings 'redefine';
    my $r = run_script('run');
    ok(!$r->{forked}, 'a run whose target is still updating starts nothing');
    is(PVE::UpdateManager::Settings::load_settings($NODE)->{last_run}, 1,
        'and leaves the stamp alone, so the next tick tries again');
}

# ── status ──────────────────────────────────────────────────────────────────
{
    settings(schedule_parallel => 1, schedule_parallel_max => 2);
    my $r = run_script('status');
    like($r->{out}, qr/^mode:\s+parallel, at most 2 at once$/m, 'status names the mode and its cap');
}

# ── the security check shares the timer (#40) ───────────────────────────────
{
    no warnings qw(once redefine);
    $PVE::UpdateManager::SecScan::STATE_DIR = "$dir/security";
    # Only the START is this test's business; run_script runs a forked task's
    # code, and a real round here would read this machine's packages.
    local *PVE::UpdateManager::SecReact::worker = sub { };
    use warnings qw(once redefine);
    settings(schedule_enabled => 0, security_scan => 1, security_interval => 30);

    my $r = run_script('run');
    is($r->{forked} && $r->{forked}->{type}, 'updmgrscan', 'a due security check starts its task');
    is($r->{forked} && $r->{forked}->{background}, 1, 'in the background, so this service does not wait for it');

    mkdir("$dir/security");
    open(my $lk, '>>', "$dir/security/scan.lock") or die;
    flock($lk, 2) or die;
    $r = run_script('run');
    ok(!$r->{forked}, 'while a check is still running, no second task is started');
    close($lk);

    PVE::Tools::file_set_contents("$dir/security/scan.state", '{"last_scan":' . time() . '}');
    $r = run_script('run');
    ok(!$r->{forked}, 'a check that ran a minute ago is not due again');

    $r = run_script('status');
    like($r->{out}, qr/^security:\s+every 30 min$/m, 'status names the check and its interval');
}
