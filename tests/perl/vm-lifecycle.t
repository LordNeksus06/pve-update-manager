#!/usr/bin/perl
# A VM's update and what happens around it: the snapshot before it, the rollback
# after a failure, the pruning, starting a stopped VM and shutting it down again,
# and the reboot an update asks for.
#
# The owner's decisions these defend (2026-10-11): a VM is snapshotted with the
# same settings as a container, disk only; the switch that starts stopped
# containers starts stopped VMs too; "Reboot VMs when required" is off by
# default, and a VM counts as updated only once its agent answers after the
# reboot.
#
# vm-job.t has the paths that decide WHETHER a VM is run; the transport is
# replaced by a recorder here as there.

use strict;
use warnings;

use File::Temp qw(tempdir);
use IO::Handle;
use Test::More tests => 79;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Notify;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor;
use PVE::Storage;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::QemuPower;
use PVE::UpdateManager::QemuRunner;
use PVE::UpdateManager::Runner;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
# The target lock directory is root's below /run (#71); a test user cannot make it.
$PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";
$PVE::UpdateManager::Logs::LOG_DIR = "$dir/logs";
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

# No waiting in a unit test: one look at the agent, then the verdict.
$PVE::UpdateManager::QemuPower::AGENT_WAIT = 0;

my $QM = $PVE::UpdateManager::QemuPower::QM;

my @BUDGETS;
my @VM_RUNS;
our $VM_RC = 0;
our $AGENT_UP = 1;
our $REBOOT_WANTED = 0;
our $REBOOT_ASKED = 0;
# Kept before it is replaced below, so its own test at the end runs the real one.
my $REAL_REBOOT_REQUIRED = \&PVE::UpdateManager::QemuPower::reboot_required;
{
    no warnings 'redefine';
    *PVE::UpdateManager::Runner::inhibit_shutdown = sub { push @BUDGETS, $_[0]; return undef };
    *PVE::UpdateManager::QemuRunner::run_vm = sub {
        my ($vmid, $script, $timeout, $logfunc) = @_;
        push @VM_RUNS, { vmid => $vmid, lock => PVE::QemuConfig->load_config($vmid)->{lock} };
        $logfunc->("output of VM $vmid");
        return $VM_RC;
    };
    *PVE::UpdateManager::QemuRunner::agent_running = sub { return $AGENT_UP };
    *PVE::UpdateManager::QemuPower::reboot_required = sub { $REBOOT_ASKED++; return $REBOOT_WANTED };
}

sub capture {
    my ($code) = @_;

    my $path = "$dir/capture.log";
    unlink($path);

    open(my $saved, '>&', \*STDOUT) or die "cannot dup STDOUT - $!";
    close(STDOUT);
    open(STDOUT, '>', $path) or die "cannot redirect STDOUT - $!";
    STDOUT->autoflush(1);

    my $err;
    eval { $code->(); 1 } or do { $err = $@ };

    close(STDOUT);
    open(STDOUT, '>&', $saved) or die "cannot restore STDOUT - $!";
    close($saved);

    open(my $fh, '<', $path) or return ('', $err);
    my $out = do { local $/; <$fh> } // '';
    close($fh);

    return ($out, $err);
}

# The qm calls of a run, as "start 200", "shutdown 200 --timeout 120" ...
sub qm_calls {
    return [
        map { join(' ', @{ $_->{cmd} }[1 .. $#{ $_->{cmd} }]) }
        grep { ref($_->{cmd}) eq 'ARRAY' && $_->{cmd}->[0] eq $QM }
        @PVE::Tools::RUN_CALLS
    ];
}

# What qm does with a locked VM, measured on the lab host: start, shutdown, stop
# and reboot all refuse while any lock is set - "VM is locked (backup)" - unless
# --skiplock is given. Without this the stub accepted a start the real qm refused,
# and the first live run of a stopped VM failed where every test here was green.
sub qm_check_lock {
    my ($cmd) = @_;

    return undef if ref($cmd) ne 'ARRAY' || $cmd->[0] ne $QM;
    return undef if !grep { $cmd->[1] eq $_ } qw(start shutdown stop reboot);
    return undef if grep { $_ eq '--skiplock' } @$cmd;

    my $conf = eval { PVE::QemuConfig->load_config($cmd->[2]) } // {};

    return $conf->{lock} ? 1 : undef;
}

sub run_vm_target {
    my ($vmid, $opts) = @_;

    # A test's own hook wins; the lock rule applies wherever none is set.
    local $PVE::Tools::RUN_RC_HOOK = $PVE::Tools::RUN_RC_HOOK // \&qm_check_lock;

    @VM_RUNS = ();
    @PVE::Tools::RUN_CALLS = ();
    @PVE::Notify::SENT = ();
    @PVE::QemuConfig::CREATE_CALLS = ();
    @PVE::QemuConfig::FEATURE_CALLS = ();
    $REBOOT_ASKED = 0;

    my ($out, $err) = capture(sub {
        PVE::UpdateManager::Job::run_all(
            [PVE::UpdateManager::Guest::target($vmid)], 60, { notify_failure => 1, %{ $opts // {} } },
        );
    });

    return {
        out => $out, err => $err,
        state => PVE::UpdateManager::Config::load_state('qemu', $vmid) // {},
        vm_runs => [@VM_RUNS], qm => qm_calls(), sent => [@PVE::Notify::SENT],
        created => [@PVE::QemuConfig::CREATE_CALLS],
    };
}

%PVE::QemuConfig::CONFIGS = (
    200 => { name => 'web-vm', agent => '1' },
    202 => { name => 'off-vm', agent => '1' },
    203 => { name => 'off-no-agent', agent => '0' },
);
%PVE::QemuServer::Helpers::RUNNING = (200 => 1, 202 => 0, 203 => 0);
$PVE::LXC::Config::NO_CONFIG{$_} = 1 for 200 .. 203;
PVE::UpdateManager::Config::save_script('qemu', $_, "apt-get update\n") for 200 .. 203;

my $SNAP = { snapshot_before => 1, snapshot_keep => 3, rollback_remove_newer => 1 };

# ── #28: the snapshot before the update ─────────────────────────────────────
{
    my $r = run_vm_target(200, $SNAP);

    is(scalar(@{ $r->{created} }), 1, 'with snapshots on, a running VM is snapshotted');
    like($r->{created}->[0]->{name}, qr/\Aupdmgr-\d{8}-\d{6}\z/, 'under a name the pruning knows as ours');
    is($r->{created}->[0]->{vmstate}, 0, 'and without its memory - disk only, as decided');
    is($PVE::QemuConfig::FEATURE_CALLS[0]->{running}, 1,
        'the storage is asked with the true running state, which QemuConfig hands on');
    is(scalar(@{ $r->{vm_runs} }), 1, 'the update runs after it');
    is($r->{state}->{state}, 'ok', 'and the row is green');
    ok(!defined($r->{state}->{note}), 'with no snapshot named on a row that went well');
    unlike($r->{out}, qr/not supported yet/, 'and nothing says VM snapshots are missing');
    is(scalar(@{ $r->{qm} }), 0, 'a running VM is neither stopped nor started for a warm snapshot');
}

{
    local $PVE::QemuConfig::NO_SNAPSHOT{200} = 1;
    my $r = run_vm_target(200, $SNAP);

    like($r->{out}, qr/the storage of this VM cannot snapshot - updating without one/,
        'a VM whose storage cannot snapshot is said to be updated without one');
    is(scalar(@{ $r->{created} }), 0, 'no snapshot is attempted');
    is(scalar(@{ $r->{vm_runs} }), 1, 'and the update still runs');
}

{
    local $PVE::QemuConfig::SNAPSHOT_DIE = 'thin pool full';
    my $r = run_vm_target(200, $SNAP);

    like($r->{out}, qr/FAILED \(could not be snapshotted before the update - thin pool full\)/,
        'a snapshot the storage promised and did not deliver fails the VM');
    is(scalar(@{ $r->{vm_runs} }), 0, 'before anything is updated');
    ok(!defined(PVE::QemuConfig->load_config(200)->{lock}), 'and leaves no lock behind');
}

# The CD-ROM is never handed to a storage plugin - QemuConfig's own has_feature
# skips it the same way.
{
    my @asked;
    no warnings 'redefine';
    local *PVE::Storage::volume_rollback_is_possible = sub {
        my ($cfg, $volid) = @_;
        push @asked, $volid;
        return 1;
    };
    use warnings 'redefine';

    my $blockers = PVE::UpdateManager::Snapshot::rollback_blockers(
        200, (sort keys %{ PVE::QemuConfig->load_config(200)->{snapshots} })[0],
    );
    is_deeply(\@asked, ['teststore:vm-200-disk-0'], 'a rollback check asks about the disk and not the ISO');
    is_deeply($blockers, {}, 'and finds nothing in the way when nothing is');
}

# ── #28: a failed update, with and without the rollback ─────────────────────
{
    delete $PVE::QemuConfig::CONFIGS{200}->{snapshots};
    local $VM_RC = 100;
    my $r = run_vm_target(200, $SNAP);

    my $taken = $r->{created}->[0]->{name};
    ok($r->{err}, 'a failed VM update fails the task');
    like($r->{state}->{note}, qr/exit 100 after \d+s, snapshot \Q$taken\E\z/,
        'and the row names the snapshot to go back to');
    is($PVE::QemuConfig::CONFIGS{200}->{rolled_back_to}, undef, 'without rollback_on_failure nothing is rolled back');
}

{
    delete $PVE::QemuConfig::CONFIGS{200}->{snapshots};
    local $VM_RC = 100;
    local $PVE::QemuServer::Helpers::RUNNING{200} = 1;
    my $r = run_vm_target(200, { %$SNAP, rollback_on_failure => 1 });

    my $taken = $r->{created}->[0]->{name};
    is($PVE::QemuConfig::CONFIGS{200}->{rolled_back_to}, $taken, 'with it on, the VM is rolled back to this run\'s snapshot');
    like($r->{out}, qr/the update failed - rolling the VM back to \Q$taken\E/, 'the log calls it a VM');
    is_deeply($r->{qm}, ['start 200'], 'and the VM, stopped by the rollback, is started again');
    like($r->{state}->{note}, qr/, rolled back to \Q$taken\E\z/, 'the row says it was rolled back');
    is(scalar(@{ $r->{sent} }), 1, 'and the failure is still notified');
    delete $PVE::QemuConfig::CONFIGS{200}->{rolled_back_to};
}

# A newer snapshot - a backup tool's, say - blocks a ZFS rollback; with the
# setting on it is removed first, as for containers.
{
    delete $PVE::QemuConfig::CONFIGS{200}->{snapshots};
    local $VM_RC = 100;
    # The rollback stops the VM, and the qm start after it is only recorded.
    local $PVE::QemuServer::Helpers::RUNNING{200} = 1;
    my $blocker_added;
    no warnings 'redefine';
    local *PVE::UpdateManager::QemuRunner::run_vm = sub {
        $PVE::QemuConfig::CONFIGS{200}->{snapshots}->{'auto-hourly'} = { snaptime => 999999 };
        $blocker_added = 1;
        return $VM_RC;
    };
    use warnings 'redefine';

    my $r = run_vm_target(200, { %$SNAP, rollback_on_failure => 1 });

    ok($blocker_added, 'premise: a newer snapshot appeared during the update');
    like($r->{out}, qr/removing the snapshot auto-hourly, which is newer than/, 'it is removed, and named');
    like($r->{state}->{note}, qr/rolled back to updmgr-/, 'and the rollback goes through');
    ok(!$PVE::QemuConfig::CONFIGS{200}->{snapshots}->{'auto-hourly'}, 'the blocker is gone');
    delete $PVE::QemuConfig::CONFIGS{200}->{rolled_back_to};
}

# ── #28: pruning ────────────────────────────────────────────────────────────
{
    $PVE::QemuConfig::CONFIGS{200}->{snapshots} = {
        'updmgr-20260101-030000' => { snaptime => 10 },
        'updmgr-20260102-030000' => { snaptime => 20 },
        'updmgr-20260103-030000' => { snaptime => 30 },
        'before-migration' => { snaptime => 5 },
    };
    my $r = run_vm_target(200, { %$SNAP, snapshot_keep => 2 });

    my @left = sort keys %{ $PVE::QemuConfig::CONFIGS{200}->{snapshots} };
    is(scalar(grep { m/\Aupdmgr-/ } @left), 2, 'only the newest of our VM snapshots are kept');
    ok(!$PVE::QemuConfig::CONFIGS{200}->{snapshots}->{'updmgr-20260101-030000'}, 'the oldest goes');
    ok($PVE::QemuConfig::CONFIGS{200}->{snapshots}->{'before-migration'}, 'and one somebody took by hand stays');
    ok(!defined(PVE::QemuConfig->load_config(200)->{lock}), 'and the VM is left unlocked');
}

# ── #28: a cold snapshot ────────────────────────────────────────────────────
{
    delete $PVE::QemuConfig::CONFIGS{200}->{snapshots};
    my $r = run_vm_target(200, { %$SNAP, snapshot_shutdown => 1 });

    is_deeply($r->{qm}, ['shutdown 200 --timeout 120', 'start 200'],
        'with "shut down for the snapshot" on, the VM is shut down and started again');
    is(scalar(@{ $r->{created} }), 1, 'and snapshotted in between');
    is(scalar(@{ $r->{vm_runs} }), 1, 'then updated');
}

{
    delete $PVE::QemuConfig::CONFIGS{200}->{snapshots};
    local $AGENT_UP = 0;
    no warnings 'redefine';
    # Up for the check before the row is claimed, then never again.
    my $pings = 0;
    local *PVE::UpdateManager::QemuRunner::agent_running = sub { return $pings++ == 0 ? 1 : 0 };
    use warnings 'redefine';

    my $r = run_vm_target(200, { %$SNAP, snapshot_shutdown => 1 });

    like($r->{out}, qr/FAILED \(came back up after its snapshot, but its guest agent did not answer\)/,
        'a VM whose agent does not come back after a cold snapshot fails');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and is not run');
}

# ── #29: starting a stopped VM ──────────────────────────────────────────────
{
    my $r = run_vm_target(202, { start_stopped => 1 });

    is_deeply($r->{qm}, ['start 202 --skiplock 1', 'shutdown 202 --timeout 120'],
        'with "start stopped" on, a stopped VM is started and shut down again');
    is(scalar(@{ $r->{vm_runs} }), 1, 'and updated in between');
    is($r->{vm_runs}->[0]->{lock}, 'backup', 'under the lock that keeps it from being shut down mid-dpkg');
    is($r->{state}->{state}, 'ok', 'the row is green');
    like($r->{out}, qr/VM is stopped - starting it for the update/, 'and the log calls it a VM');
    ok(!defined(PVE::QemuConfig->load_config(202)->{lock}), 'the lock is gone afterwards');
}

{
    local $AGENT_UP = 0;
    my $r = run_vm_target(202, { start_stopped => 1 });

    like($r->{out}, qr/FAILED \(was started for the update, but its guest agent did not answer\)/,
        'a started VM whose agent never answers fails');
    is(scalar(@{ $r->{vm_runs} }), 0, 'nothing is run in it');
    is_deeply($r->{qm}, ['start 202 --skiplock 1', 'shutdown 202 --timeout 120'], 'and it is shut down again');
    ok(!defined(PVE::QemuConfig->load_config(202)->{lock}),
        'with the lock given back first - qm shutdown refuses while one is set');
    is(scalar(@{ $r->{sent} }), 1, 'and the failure is notified');
}

{
    local $PVE::Tools::RUN_RC_HOOK = sub { return $_[0]->[1] eq 'start' ? 1 : undef };
    my $r = run_vm_target(202, { start_stopped => 1 });

    like($r->{out}, qr/FAILED \(could not be started for the update\)/, 'a VM that does not start fails');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and is not run');
}

{
    my $r = run_vm_target(203, { start_stopped => 1 });

    like($r->{out}, qr/FAILED \(the QEMU guest agent is not enabled in the options of this VM\)/,
        'a stopped VM without the agent enabled fails before it is started');
    is(scalar(@{ $r->{qm} }), 0, 'so it is not booted for nothing');
}

# ── #29: the reboot an update asks for ──────────────────────────────────────
{
    local $REBOOT_WANTED = 1;
    my $r = run_vm_target(200, { reboot_vms => 1 });

    is($REBOOT_ASKED, 1, 'with "reboot VMs" on, the VM is asked whether it needs one');
    is_deeply($r->{qm}, ['reboot 200 --timeout 120'], 'it does, so it is rebooted');
    is($r->{state}->{state}, 'ok', 'and counts as updated once its agent answers again');
    like($r->{state}->{note}, qr/\Aexit 0 after \d+s, rebooted\z/, 'the row says it was rebooted');
}

{
    local $REBOOT_WANTED = 0;
    my $r = run_vm_target(200, { reboot_vms => 1 });
    is(scalar(@{ $r->{qm} }), 0, 'a VM that does not ask for a reboot is not rebooted');
}

{
    local $REBOOT_WANTED = undef;
    my $r = run_vm_target(200, { reboot_vms => 1 });
    is(scalar(@{ $r->{qm} }), 0, 'nor one that could not be asked');
    like($r->{out}, qr/could not ask the VM whether it needs a reboot - not rebooting it/, 'which the log says');
}

{
    local $REBOOT_WANTED = 1;
    my $r = run_vm_target(200, {});
    is($REBOOT_ASKED, 0, 'with the setting off - the default - the VM is not even asked');
    is(scalar(@{ $r->{qm} }), 0, 'and not rebooted');
}

{
    local $REBOOT_WANTED = 1;
    local $PVE::Tools::RUN_RC_HOOK = sub { return $_[0]->[1] eq 'reboot' ? 1 : undef };
    my $r = run_vm_target(200, { reboot_vms => 1 });

    ok($r->{err}, 'a reboot that fails fails the task');
    is($r->{state}->{state}, 'failed', 'and the row, although the script exited 0');
    like($r->{state}->{note}, qr/\Aexit 0 after \d+s, but the reboot it needed FAILED\z/,
        "the note keeps the script's own exit code and says what failed");
    is(scalar(@{ $r->{sent} }), 1, 'and the failure is notified');
}

{
    local $REBOOT_WANTED = 1;
    local $VM_RC = 100;
    my $r = run_vm_target(200, { reboot_vms => 1 });
    is($REBOOT_ASKED, 0, 'a failed update is not rebooted');
}

{
    local $REBOOT_WANTED = 1;
    my $r = run_vm_target(202, { reboot_vms => 1, start_stopped => 1 });
    is($REBOOT_ASKED, 0, 'nor a VM that was started for its update');
    is_deeply($r->{qm}, ['start 202 --skiplock 1', 'shutdown 202 --timeout 120'], 'it is just shut down again');
}

# reboot_vm itself: the command returning is not the VM being back.
{
    @PVE::Tools::RUN_CALLS = ();
    local $AGENT_UP = 0;
    my @log;
    my $rc = PVE::UpdateManager::QemuPower::reboot_vm(200, sub { push @log, $_[0] });
    isnt($rc, 0, 'a reboot after which the agent does not answer is not a success');
    like(join("\n", @log), qr/the guest agent did not answer within \d+s of the reboot/, 'and says why');
}

# ── reboot_required, against the agent ──────────────────────────────────────
{
    my $exitcode;
    my @args;
    local $PVE::QemuServer::Monitor::HANDLER = sub {
        my ($vmid, $cmd, %a) = @_;
        if ($cmd eq 'guest-exec') {
            @args = @{ $a{arg} };
            return { pid => 7 };
        }
        return { exited => 1, exitcode => $exitcode } if $cmd eq 'guest-exec-status';
        die "unexpected $cmd\n";
    };

    my $real = $REAL_REBOOT_REQUIRED;
    $exitcode = 0;
    is($real->(200), 1, 'the flag file exists: a reboot is required');
    is_deeply(\@args, ['-c', 'test -e /var/run/reboot-required'], 'asked with test -e on the Debian flag file');
    $exitcode = 1;
    is($real->(200), 0, 'no flag file: no reboot');

    local $PVE::QemuServer::Monitor::HANDLER = sub { return { error => { desc => 'agent busy' } } };
    is($real->(200), undef, 'an agent error is "could not ask", not "no"');
}

# ── the shutdown budget ─────────────────────────────────────────────────────
{
    @BUDGETS = ();
    my $vm = [PVE::UpdateManager::Guest::target(200)];
    capture(sub { PVE::UpdateManager::Job::run_all($vm, 600, { start_stopped => 1 }) });
    capture(sub { PVE::UpdateManager::Job::run_all($vm, 600, { reboot_vms => 1 }) });
    capture(sub { PVE::UpdateManager::Job::run_all($vm, 600, {}) });

    my $grace = $PVE::UpdateManager::QemuPower::PER_TARGET_GRACE;
    is($BUDGETS[0], 600 + $grace + $PVE::UpdateManager::Runner::OUTER_GRACE,
        'a VM that may be started is held for the boot and the agent too');
    is($BUDGETS[1], $BUDGETS[0], 'and so is one that may be rebooted');
    is($BUDGETS[2], 600 + $PVE::UpdateManager::Runner::OUTER_GRACE, 'a plain VM run is not');
    ok($grace > $PVE::UpdateManager::Runner::PER_TARGET_GRACE, 'the VM figure is the larger one');
}
