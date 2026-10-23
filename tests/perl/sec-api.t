#!/usr/bin/perl
# The security check in the API (#41): the target lists of the node tab and
# the datacenter tab carry the summary the background round wrote, and
# "Check now" starts a worker task instead of doing the work in the call.
#
# What is NOT claimed here, because a stub cannot show it: that the web UI
# stays usable while a guest hangs. That is a property of the call doing no
# work at all, which is what the last section pins - and was watched on the
# lab PVE separately.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

use PVE::API2::Cluster;
use PVE::LXC;
use PVE::LXC::Config;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::UpdateManager::ClusterAPI;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::NodeAPI;
use PVE::UpdateManager::SecSummary;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

%PVE::LXC::CONFIG_LIST = (101 => {}, 102 => {});
$PVE::LXC::Config::CONFIGS{101} = { hostname => 'db' };
$PVE::LXC::Config::CONFIGS{102} = { hostname => 'web' };

PVE::UpdateManager::SecSummary::write('pve-test', [
    { type => 'node', id => 'pve-test', status => 'ok', checked => 1000,
        pending => [{ name => 'bash' }] },
    { type => 'lxc', id => '101', status => 'ok', checked => 1000,
        pending => [map { { name => "p$_" } } 1 .. 7], warning => 'package files answer HTTP 404' },
    { type => 'lxc', id => '102', status => 'unsupported', reason => 'no dpkg', checked => 1000, pending => [] },
]);

my $targets = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'targets');
my %row = map { ("$_->{type}-$_->{id}" => $_) } @{ $targets->({ node => 'pve-test' }) };

# ── the node tab ────────────────────────────────────────────────────────────
is($row{'lxc-101'}->{security_count}, 7, 'a guest row carries its count of pending security updates');
is($row{'lxc-101'}->{security_packages}, 'p1,p2,p3,p4,p5', 'and the first five names');
is($row{'lxc-101'}->{security_status}, 'ok', 'and the status of its check');
is($row{'lxc-101'}->{security_warning}, 'package files answer HTTP 404',
    'and the warning that they cannot be installed from its source (#53)');
ok(!exists($row{'node-pve-test'}->{security_warning}), 'control: a row without one carries none');
is($row{'node-pve-test'}->{security_count}, 1, 'the host row as well');
is($row{'lxc-102'}->{security_status}, 'unsupported', 'a target that could not be checked says so');
is($row{'lxc-102'}->{security_reason}, 'no dpkg', 'and why');
is($row{'lxc-102'}->{security_count}, 0, 'with 0 beside it, which the grid shows as "-" because of the status');

PVE::UpdateManager::Config::save_script('lxc', 103, "x\n");
%PVE::LXC::CONFIG_LIST = (101 => {}, 102 => {}, 103 => {});
%row = map { ("$_->{type}-$_->{id}" => $_) } @{ $targets->({ node => 'pve-test' }) };
ok(!exists($row{'lxc-103'}->{security_status}), 'a guest no check has seen yet carries no security fields at all');

# ── the datacenter tab ──────────────────────────────────────────────────────
@PVE::API2::Cluster::RESOURCES = (
    { type => 'node', node => 'pve-test' },
    { type => 'node', node => 'pve-other' },
    { type => 'lxc', vmid => 101, node => 'pve-test' },
    { type => 'lxc', vmid => 201, node => 'pve-other' },
);
PVE::UpdateManager::SecSummary::write('pve-other', [
    { type => 'lxc', id => '201', status => 'ok', checked => 1000, pending => [{ name => 'curl' }] },
]);
my $dc = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'targets');
my %drow = map { ("$_->{type}-$_->{id}" => $_) } @{ $dc->({}) };
is($drow{'lxc-101'}->{security_count}, 7, 'the datacenter list reads the summary of the node that owns a guest');
is($drow{'lxc-201'}->{security_packages}, 'curl', 'for a guest on another node, from that node\'s summary');

# ── "Check now" ─────────────────────────────────────────────────────────────
my $scan = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'security_scan');
local @PVE::RPCEnvironment::FORKED = ();
my $upid = $scan->({ node => 'pve-test' });
like($upid, qr/\AUPID:/, 'it answers with a task id');
is(scalar(@PVE::RPCEnvironment::FORKED), 1, 'having started one worker task');
is($PVE::RPCEnvironment::FORKED[0]->{type}, 'updmgrscan', 'of its own task type');
is(ref($PVE::RPCEnvironment::FORKED[0]->{code}), 'CODE', 'and the work is the task\'s, not the call\'s');

done_testing();
