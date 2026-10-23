#!/usr/bin/perl
# Who may make the addon run what (#63, #64, #65) - decided by the owner on
# 2026-10-23: the host's script is root@pam's alone, as PVE keeps its own root
# shell; a guest run needs the privileges PVE asks for the same actions; a
# schedule or an immediate update may only cover what its author may run.
#
# The endpoints are called as a user that is not root@pam, with exactly the
# privileges a test grants - the declared "permissions" of an endpoint are
# enforced by PVE's REST layer, which these tests do not have, so every rule
# here has to be checked in the code itself.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

use PVE::LXC;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::UpdateManager::ClusterAPI;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::LXCAPI;
use PVE::UpdateManager::NodeAPI;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Settings;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

%PVE::LXC::CONFIG_LIST = (301 => {}, 302 => {});
$PVE::LXC::RUNNING{301} = 4711;
$PVE::LXC::RUNNING{302} = 4712;
PVE::UpdateManager::Config::save_script('lxc', $_, "apt-get update\n", 'root@pam') for 301, 302;

my $node_set_script = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'set_script');
my $node_run = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'run');
my $set_settings = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'set_settings');
my $set_global = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'set_global_settings');
my $ct_run = PVE::RESTHandler::registered('PVE::UpdateManager::LXCAPI', 'run');

# The privileges a test hands out: { path => [privs] }.
my %grant;
$PVE::RPCEnvironment::CHECK = sub {
    my ($path, $privs) = @_;
    my %have = map { $_ => 1 } @{ $grant{$path} // [] };
    return !grep { !$have{$_} } @$privs;
};

sub as {
    my ($user, $grants, $code) = @_;
    local $PVE::RPCEnvironment::USER = $user;
    local @PVE::RPCEnvironment::FORKED = ();
    %grant = %$grants;
    my $res = eval { $code->() };
    return { ok => !$@, error => $@ // '', forked => scalar(@PVE::RPCEnvironment::FORKED) };
}

sub reset_settings {
    my (%s) = @_;
    my $file = PVE::UpdateManager::Settings::settings_file('pve');
    unlink($file);
    PVE::UpdateManager::Settings::save_settings('pve', { %s }) if %s;
}

my $node_all = { '/nodes/pve' => [qw(Sys.Audit Sys.Modify Sys.Console)] };
my $ct_all = [qw(VM.Console VM.Config.Options VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback VM.Audit)];

# ── #63: the host's script is root@pam's ────────────────────────────────────
{
    reset_settings();
    my $r = as('admin@pve', $node_all, sub { $node_set_script->({ node => 'pve', script => "id\n" }) });
    ok(!$r->{ok}, 'a user with Sys.Modify and Sys.Console cannot store the host script (it runs as root)');
    like($r->{error}, qr/root\@pam/, 'and is told who may');
    ok(!PVE::UpdateManager::Config::has_script('node', 'pve'), 'premise: nothing was stored');

    $r = as('root@pam!tok', $node_all, sub { $node_set_script->({ node => 'pve', script => "id\n" }) });
    ok(!$r->{ok}, 'nor an API token of root@pam - PVE gives its root shell to root@pam alone');

    $r = as('root@pam', {}, sub { $node_set_script->({ node => 'pve', script => "apt-get update\n" }) });
    ok($r->{ok}, 'control: root@pam stores it') or diag($r->{error});

    $r = as('admin@pve', $node_all, sub { $node_run->({ node => 'pve', host => 1 }) });
    ok(!$r->{ok} && !$r->{forked}, 'a user who is not root@pam cannot run the host script');
    $r = as('admin@pve', { %$node_all, '/vms/301' => $ct_all }, sub { $node_run->({ node => 'pve', vmids => '301' }) });
    ok($r->{ok} && $r->{forked}, 'control: the same user runs a guest he may run') or diag($r->{error});

    $r = as('admin@pve', $node_all, sub {
        $set_settings->({ node => 'pve', schedule_enabled => 1, schedule_host => 1 }) });
    ok(!$r->{ok}, 'nor schedule the host script to run unattended');
    $r = as('admin@pve', { %$node_all, '/vms' => $ct_all }, sub {
        $set_settings->({ node => 'pve', security_install => 1 }) });
    ok(!$r->{ok}, 'nor switch on immediate updates for every target, which include the host');
    $r = as('root@pam', {}, sub {
        $set_settings->({ node => 'pve', schedule_enabled => 1, schedule_host => 1 }) });
    ok($r->{ok}, 'control: root@pam does') or diag($r->{error});
}

# ── #64: a guest run needs what PVE asks for the same actions ──────────────
{
    reset_settings(snapshot_before => 1, rollback_on_failure => 0, start_stopped => 0);
    my $r = as('ops@pve', { '/vms/301' => ['VM.Console'] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok(!$r->{ok} && !$r->{forked}, 'VM.Console alone does not run a guest the run would snapshot');
    like($r->{error}, qr/VM\.Snapshot/, 'and the missing privilege is named');
    $r = as('ops@pve', { '/vms/301' => [qw(VM.Console VM.Snapshot)] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok($r->{ok} && $r->{forked}, 'with VM.Snapshot it does') or diag($r->{error});

    reset_settings(snapshot_before => 0, rollback_on_failure => 0, start_stopped => 0);
    $r = as('ops@pve', { '/vms/301' => ['VM.Console'] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok($r->{ok} && $r->{forked}, 'control: with no snapshot, start or rollback, VM.Console is enough') or diag($r->{error});

    reset_settings(snapshot_before => 1, rollback_on_failure => 1, start_stopped => 0);
    $r = as('ops@pve', { '/vms/301' => [qw(VM.Console VM.Snapshot)] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok($r->{ok}, 'a rollback takes VM.Snapshot or VM.Snapshot.Rollback, as in PVE - VM.Snapshot will do') or diag($r->{error});

    reset_settings(snapshot_before => 0, rollback_on_failure => 1, rollback_remove_newer => 0, start_stopped => 0);
    $r = as('ops@pve', { '/vms/301' => [qw(VM.Console VM.Snapshot.Rollback)] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok($r->{ok}, '- and so will VM.Snapshot.Rollback') or diag($r->{error});
    $r = as('ops@pve', { '/vms/301' => ['VM.Console'] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok(!$r->{ok}, '- but not neither');

    # Clearing the rollback's way deletes snapshots, which PVE asks VM.Snapshot for.
    reset_settings(snapshot_before => 0, rollback_on_failure => 1, rollback_remove_newer => 1, start_stopped => 0);
    $r = as('ops@pve', { '/vms/301' => [qw(VM.Console VM.Snapshot.Rollback)] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok(!$r->{ok}, 'a rollback that removes newer snapshots takes VM.Snapshot, Rollback alone is not enough');

    reset_settings(snapshot_before => 0, rollback_on_failure => 0, start_stopped => 1);
    $r = as('ops@pve', { '/vms/301' => ['VM.Console'] }, sub { $ct_run->({ node => 'pve', vmid => 301 }) });
    ok(!$r->{ok}, 'starting a stopped guest for the run takes VM.PowerMgmt');
    like($r->{error}, qr/VM\.PowerMgmt/, 'and says so');

    reset_settings(snapshot_before => 1, rollback_on_failure => 0, start_stopped => 0);
    $r = as('ops@pve', { '/vms/301' => ['VM.Console'], '/nodes/pve' => ['Sys.Console'] },
        sub { $node_run->({ node => 'pve', vmids => '301' }) });
    ok(!$r->{ok} && !$r->{forked}, 'the node tab\'s run asks the same of each guest');
}

# ── #65: a schedule covers only what its author may run ─────────────────────
{
    reset_settings(snapshot_before => 1);
    my $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'] }, sub {
        $set_settings->({ node => 'pve', schedule_enabled => 1, schedule_vmids => '301' }) });
    ok(!$r->{ok}, 'Sys.Console on the node does not schedule a guest the user has no privilege on');
    like($r->{error}, qr{/vms/301}, 'and the guest is named');
    is(PVE::UpdateManager::Settings::load_settings('pve')->{schedule_vmids} // '', '', 'premise: nothing was stored');

    $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'], '/vms/301' => [qw(VM.Console VM.Snapshot)] }, sub {
        $set_settings->({ node => 'pve', schedule_enabled => 1, schedule_vmids => '301' }) });
    ok($r->{ok}, 'with the privileges a run of that guest needs, it does') or diag($r->{error});

    $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'], '/vms/301' => [qw(VM.Console VM.Snapshot)] }, sub {
        $set_settings->({ node => 'pve', schedule_vmids => '301,302' }) });
    ok(!$r->{ok}, 'adding a second guest checks that one too');

    $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'], '/vms/301' => [qw(VM.Console VM.Snapshot)] }, sub {
        $set_settings->({ node => 'pve', security_install => 1, security_install_vmids => '301' }) });
    ok($r->{ok}, 'immediate updates for a listed guest the user may run') or diag($r->{error});
    $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'], '/vms/301' => [qw(VM.Console VM.Snapshot)] }, sub {
        $set_settings->({ node => 'pve', security_reboot => 1 }) });
    ok(!$r->{ok}, 'restarting those guests after an immediate update takes VM.PowerMgmt as well');

    reset_settings(snapshot_before => 1);
    local @PVE::API2::Cluster::RESOURCES = ({ type => 'node', node => 'pve' });
    $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'] }, sub { $set_global->({ timeout => 900 }) });
    ok($r->{ok}, 'premise: this user saves datacenter-wide what runs nothing new') or diag($r->{error});
    $r = as('ops@pve', { '/nodes/pve' => ['Sys.Console'], '/vms/301' => $ct_all, '/vms/302' => $ct_all }, sub {
        $set_global->({ security_install => 1 }) });
    ok(!$r->{ok}, 'a datacenter-wide save cannot switch immediate updates on for every target either');
    like($r->{error}, qr/root\@pam/, 'because every target includes the host');
    is(PVE::UpdateManager::Settings::load_settings('pve')->{security_install}, 0, 'and nothing was written');
}

done_testing();
