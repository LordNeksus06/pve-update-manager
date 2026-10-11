#!/usr/bin/perl
# PVE::UpdateManager::Job with a VM as the target - every way a VM run can end
# before or after the agent is asked, and that a VM never takes a container's
# path (pct, a container snapshot, a container lock).
#
# The transport itself is QemuRunner's and is tested in qemu-runner.t; here it
# is replaced by a recorder, so what is checked is the decision about WHETHER
# and HOW a VM is run, and what its row and the task log say.

use strict;
use warnings;

use File::Temp qw(tempdir);
use IO::Handle;
use Test::More tests => 43;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Notify;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Helpers;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::QemuRunner;
use PVE::UpdateManager::Runner;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
$PVE::UpdateManager::Config::LOG_DIR = "$dir/logs";

# See job.t: no busctl and no systemd-inhibit in a unit test.
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";
{
    no warnings 'redefine';
    *PVE::UpdateManager::Runner::inhibit_shutdown = sub { return undef };
}

# The VM transport, recorded instead of run.
my @VM_RUNS;
our $VM_RC = 0;
our $AGENT_UP = 1;
{
    no warnings 'redefine';
    *PVE::UpdateManager::QemuRunner::run_vm = sub {
        my ($vmid, $script, $timeout, $logfunc) = @_;
        push @VM_RUNS, {
            vmid => $vmid, script => $script, timeout => $timeout,
            lock => PVE::QemuConfig->load_config($vmid)->{lock},
        };
        $logfunc->("output of VM $vmid");
        return $VM_RC;
    };
    *PVE::UpdateManager::QemuRunner::agent_running = sub { return $AGENT_UP };
}

# Same capture as job.t: into a real file, because the worker writes with print.
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

sub run_vm_target {
    my ($vmid, $opts) = @_;

    @VM_RUNS = ();
    local @PVE::Tools::RUN_CALLS = ();
    local @PVE::Notify::SENT = ();

    my ($out, $err) = capture(sub {
        PVE::UpdateManager::Job::run_all(
            [PVE::UpdateManager::Guest::target($vmid)], 60, { notify_failure => 1, %{ $opts // {} } },
        );
    });

    my $state = PVE::UpdateManager::Config::load_state('qemu', $vmid) // {};

    return {
        out => $out, err => $err, state => $state,
        vm_runs => [@VM_RUNS], pct => [@PVE::Tools::RUN_CALLS], sent => [@PVE::Notify::SENT],
    };
}

%PVE::QemuConfig::CONFIGS = (
    200 => { name => 'web-vm', agent => '1' },
    201 => { name => 'tpl-vm', agent => '1', template => 1 },
    202 => { name => 'off-vm', agent => '1' },
    203 => { name => 'no-agent', agent => 'enabled=0,fstrim_cloned_disks=1' },
    204 => { name => 'backup-vm', agent => '1', lock => 'backup' },
);
%PVE::QemuServer::Helpers::RUNNING = (200 => 1, 201 => 0, 202 => 0, 203 => 1, 204 => 1);
# The container stub answers for every vmid unless told otherwise; the real
# load_config dies for a vmid that is a VM, and that is what type_of relies on.
$PVE::LXC::Config::NO_CONFIG{$_} = 1 for 200 .. 204;
PVE::UpdateManager::Config::save_script('qemu', $_, "apt-get update\n") for 200 .. 204;

# ── which kind a vmid is ────────────────────────────────────────────────────
is(PVE::UpdateManager::Guest::type_of(200), 'qemu', 'a vmid with a VM config here is a VM');
is_deeply(
    PVE::UpdateManager::Guest::target(200),
    { type => 'qemu', id => '200', name => 'web-vm' },
    'and its target carries the VM name',
);
{
    local $PVE::LXC::Config::NO_CONFIG{999} = 1;
    is(PVE::UpdateManager::Guest::type_of(999), undef, 'a vmid with no config here is neither');
    is(PVE::UpdateManager::Guest::target(999)->{type}, 'lxc', 'and stays a container target, as before VMs');
}
ok(PVE::UpdateManager::Guest::agent_enabled({ agent => '1' }), "'agent: 1' is on");
ok(PVE::UpdateManager::Guest::agent_enabled({ agent => 'enabled=1,freeze-fs=0' }), "'enabled=1,...' is on");
ok(!PVE::UpdateManager::Guest::agent_enabled({ agent => '0' }), "'agent: 0' is off");
ok(!PVE::UpdateManager::Guest::agent_enabled({}), 'no agent line is off');

# ── a running VM with an agent ──────────────────────────────────────────────
{
    my $r = run_vm_target(200);

    ok(!defined($r->{err}), 'a VM that updates fine does not fail the task');
    is(scalar(@{ $r->{vm_runs} }), 1, 'it is run through the guest agent');
    is($r->{vm_runs}->[0]->{script}, "apt-get update\n", "with the VM's own stored script");
    is(scalar(@{ $r->{pct} }), 0, 'and pct is never called for it');
    like($r->{out}, qr/=== \[1\/1\] VM 200 \(web-vm\) ===/, 'the banner calls it a VM, not a CT');
    is(
        PVE::UpdateManager::Job::_short_desc({ type => 'qemu', id => 200 }),
        'VM 200',
        'the prefix of its lines in a parallel run calls it a VM too',
    );
    like($r->{out}, qr/--- VM 200 \(web-vm\): OK/, 'and its verdict too');
    is($r->{state}->{state}, 'ok', 'its row is stored under the VM, not under a container');
    is($r->{vm_runs}->[0]->{lock}, 'backup', 'while it runs the VM carries the lock PVE checks before a shutdown');
    ok(!defined(PVE::QemuConfig->load_config(200)->{lock}), 'and the lock is gone afterwards');
    ok(!defined(PVE::UpdateManager::Config::load_state('lxc', 200)), 'and nothing under lxc-200');
}

{
    local $VM_RC = 100;
    my $r = run_vm_target(200);

    ok($r->{err}, 'a failing VM update fails the task');
    is($r->{state}->{state}, 'failed', 'and its row');
    ok(!defined(PVE::QemuConfig->load_config(200)->{lock}), 'a failed update gives the lock back too');
    is(scalar(@{ $r->{sent} }), 1, 'and the failure notification goes out');
}

# ── a VM that is not run ────────────────────────────────────────────────────
{
    my $r = run_vm_target(201);
    like($r->{out}, qr/SKIPPED \(this is a template, not a VM\)/, 'a template is skipped, and called a VM');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and not run');
}

{
    my $r = run_vm_target(202);
    like($r->{out}, qr/SKIPPED \(VM is not running\)/, 'a stopped VM is skipped');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and not run');
}

{
    my $r = run_vm_target(202, { start_stopped => 1 });
    like(
        $r->{out},
        qr/SKIPPED \(VM is not running - starting stopped VMs for their update is not supported yet\)/,
        'with "start stopped" on it is still skipped, and the row says that the setting did not apply',
    );
    is(scalar(@{ $r->{vm_runs} }), 0, 'nothing tries to start it');
}

# The owner's decision: no agent is RED and notifies, not a quiet skip.
{
    my $r = run_vm_target(203);
    ok($r->{err}, 'a VM without the agent enabled fails the task');
    like($r->{out}, qr/FAILED \(the QEMU guest agent is not enabled in the options of this VM\)/,
        'and says where to switch it on');
    is(scalar(@{ $r->{sent} }), 1, 'the failure notification goes out');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and nothing is run');
}

{
    local $AGENT_UP = 0;
    my $r = run_vm_target(200);
    ok($r->{err}, 'a VM whose agent does not answer fails the task');
    like($r->{out}, qr/FAILED \(the QEMU guest agent is not answering/, 'and says so');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and nothing is run');
}

{
    my $r = run_vm_target(204);
    like($r->{out}, qr/SKIPPED \(another task holds the lock \(backup\)\)/,
        'a VM that is being backed up is left alone, like a container');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and not run');
    is(PVE::QemuConfig->load_config(204)->{lock}, 'backup', "and the backup's own lock is left where it is");
}

# The check above and set_lock are two steps. A lock that appears between them
# is refused by set_lock itself - and that refusal must be a skip, not a run.
{
    no warnings 'redefine';
    local *PVE::UpdateManager::QemuRunner::lock_vm = sub { die "VM is locked (migrate)\n" };
    my $r = run_vm_target(200);
    like($r->{out}, qr/SKIPPED \(another task holds the lock \(VM is locked \(migrate\)\)\)/,
        'a lock taken in the gap is a skip');
    is(scalar(@{ $r->{vm_runs} }), 0, 'and nothing is run');
}

# ── what a VM does not have yet ─────────────────────────────────────────────
{
    local %PVE::LXC::Config::LOCKS = ();
    my $r = run_vm_target(200, { snapshot_before => 1, snapshot_keep => 3 });
    like($r->{out}, qr/snapshots of VMs are not supported yet - updating without one/,
        'with snapshots on, the log says the VM gets none');
    is(scalar(@{ $r->{vm_runs} }), 1, 'and the update still runs');
}
