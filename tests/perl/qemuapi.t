#!/usr/bin/perl
# PVE::UpdateManager::QemuAPI - the per-VM tab: the same methods as the
# container tab, bound to 'qemu'.
#
# What is worth pinning is the binding, not the methods again - lxcapi.t covers
# those. One set of methods registered twice is only right if each copy reads
# and writes ITS kind: a VM's script saved as lxc-200.conf would be read back as
# a container's, and a VM run forked as a container task would be run with pct.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 23;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::QemuConfig;
use PVE::QemuServer::Helpers;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::LXCAPI;
use PVE::UpdateManager::QemuAPI;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Settings;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# See run-tests.sh: every test naming Job pins the cgroup it would read.
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

%PVE::QemuConfig::CONFIGS = (
    200 => { name => 'vm-web', agent => '1' },
    201 => { name => 'vm-off', agent => '1' },
    202 => { name => 'vm-tpl', agent => '1', template => 1 },
);
%PVE::QemuServer::Helpers::RUNNING = (200 => 1, 201 => 0, 202 => 0);
$PVE::LXC::Config::NO_CONFIG{$_} = 1 for 200 .. 202;
$PVE::LXC::Config::CONFIGS{101} = { hostname => 'ct' };
$PVE::LXC::RUNNING{101} = 1;

my %api = map { $_ => PVE::RESTHandler::registered('PVE::UpdateManager::QemuAPI', $_) }
    qw(get_script set_script run delete_script logs set_order script_versions);

ok(ref($api{$_}) eq 'CODE', "the VM tab has '$_'") for sort keys %api;

ok(
    PVE::RESTHandler::registered('PVE::UpdateManager::LXCAPI', 'run')
        != $api{run},
    'and it is its own handler, not the container one registered under a second name',
);

sub call_run {
    my (%param) = @_;

    local @PVE::RPCEnvironment::FORKED = ();
    my $res = eval { $api{run}->({ node => 'pve', %param }) };

    return { result => $res, error => $@, forked => [@PVE::RPCEnvironment::FORKED] };
}

# ── the script is the VM's ──────────────────────────────────────────────────
{
    $api{set_script}->({ node => 'pve', vmid => 200, script => "apt-get -y upgrade\n" });

    ok(-f "$dir/store/qemu-200.conf", "a VM's script is stored as qemu-<vmid>.conf");
    ok(!-e "$dir/store/lxc-200.conf", 'and not as a container script');
    is($api{get_script}->({ node => 'pve', vmid => 200 })->{script}, "apt-get -y upgrade\n",
        'and is read back from there');
}

# ── a run ───────────────────────────────────────────────────────────────────
{
    my $call = call_run(vmid => 200);

    is($call->{error}, '', 'a running VM with a script starts a run');
    is($call->{forked}->[0]->{type}, 'vmupdate', 'typed vmupdate, so the task list says VM');

    my $handed;
    {
        no warnings 'redefine';
        local *PVE::UpdateManager::Job::run_all = sub { $handed = $_[0] };
        $call->{forked}->[0]->{code}->();
    }
    is_deeply($handed, [{ type => 'qemu', id => 200, name => 'vm-web' }], 'and hands the job a VM target');
}

{
    PVE::UpdateManager::Config::save_script('qemu', 201, "true\n");
    PVE::UpdateManager::Settings::save_settings('pve', { start_stopped => 1 });

    my $call = call_run(vmid => 201);
    is($call->{error}, '', 'with "start stopped" on, a stopped VM starts a run - one switch for both kinds');
    is(scalar(@{ $call->{forked} }), 1, 'and a task is forked for it');

    PVE::UpdateManager::Settings::save_settings('pve', { start_stopped => 0 });

    $call = call_run(vmid => 201);
    like($call->{error}, qr/\AVM 201 is not running \(enable 'start stopped guests' in the node's/,
        'with it off the VM is refused, with the same advice a container gets');
    is(scalar(@{ $call->{forked} }), 0, 'and nothing is started');
}

{
    PVE::UpdateManager::Config::save_script('qemu', 202, "true\n");
    my $call = call_run(vmid => 202);
    like($call->{error}, qr/VM 202 is a template/, 'a VM template is refused as one');
}

# A container's vmid sent to the VM path: answered as what it is not, rather than
# run through the agent of a VM that does not exist.
{
    my $call = call_run(vmid => 101);
    like($call->{error}, qr/VM 101 is not a VM on node pve/, "a container's vmid on the VM path is refused");
    is(scalar(@{ $call->{forked} }), 0, 'and nothing is started');
}

# ── the purge in the destroy dialog takes the VM's files ────────────────────
{
    PVE::UpdateManager::Config::save_state('qemu', 200, { state => 'ok', finished => 1 });
    $api{delete_script}->({ node => 'pve', vmid => 200, purge => 1 });

    ok(!-e "$dir/store/qemu-200.conf", 'a purge removes the VM script');
    ok(!defined(PVE::UpdateManager::Config::load_state('qemu', 200)), "and the VM's last run");
}
