#!/usr/bin/perl
# PVE::UpdateManager::NodeAPI - who is shown what, and who may start a run.
#
# Two of these endpoints declare `user => 'all'` and do their own checking in
# code, which is the arrangement that can go wrong quietly: the list would show
# a container somebody may not see, or a run would start on a host somebody may
# not touch. Both are checked here rather than inferred from the declaration,
# because for these two there IS no declaration to read.
#
# The rest declare a privilege and the REST layer enforces it before the code
# runs - a test can only pin what they ask for, so that is what it does. An
# endpoint that quietly asked for less than its neighbour is the failure that
# would not show up anywhere else.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 35;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::NodeAPI;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

my $targets = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'targets');
my $run = PVE::RESTHandler::registered('PVE::UpdateManager::NodeAPI', 'run');

%PVE::LXC::CONFIG_LIST = (101 => {}, 102 => {});
$PVE::LXC::RUNNING{101} = 4711;
$PVE::LXC::Config::CONFIGS{101} = { hostname => 'db' };
$PVE::LXC::Config::CONFIGS{102} = { hostname => 'web' };

PVE::UpdateManager::Config::save_script('node', 'pve-test', "apt-get update\n");
PVE::UpdateManager::Config::save_script('lxc', 101, "apt-get update\n");

sub ids_of {
    my ($res) = @_;
    return [map { "$_->{type}:$_->{id}" } @$res];
}

# ── the list shows what the user may see, and nothing else ──────────────────
{
    my $res = $targets->({ node => 'pve-test' });

    is_deeply(
        ids_of($res),
        ['node:pve-test', 'lxc:101', 'lxc:102'],
        'with every privilege: the host and both containers',
    );
}

{
    # Sys.Audit is what the host row needs. Without it the row is not there -
    # not there and disabled, which would still say a host exists.
    local $PVE::RPCEnvironment::CHECK = sub {
        my ($path) = @_;
        return $path ne '/nodes/pve-test';
    };

    my $res = $targets->({ node => 'pve-test' });

    is_deeply(ids_of($res), ['lxc:101', 'lxc:102'], 'without Sys.Audit the host row is gone');
}

{
    local $PVE::RPCEnvironment::CHECK = sub {
        my ($path) = @_;
        return $path ne '/vms/101';
    };

    my $res = $targets->({ node => 'pve-test' });

    is_deeply(
        ids_of($res),
        ['node:pve-test', 'lxc:102'],
        'a container the user may not audit is left out, and the others stay',
    );
}

# ── what the new columns carry ──────────────────────────────────────────────
{
    PVE::UpdateManager::Config::save_order('lxc', 101, 4);
    PVE::UpdateManager::Config::save_settings(
        'pve-test', { snapshot_before => 1, snapshot_shutdown => 1, parallel_manual => 1 },
    );

    my $res = $targets->({ node => 'pve-test' });
    my ($host) = grep { $_->{type} eq 'node' } @$res;
    my ($ct101) = grep { $_->{id} eq '101' } @$res;
    my ($ct102) = grep { $_->{id} eq '102' } @$res;

    is($ct101->{order}, 4, 'a container carries its place in a serial run');
    is($ct102->{order}, 0, 'and one without a number says 0 rather than leaving the field out');
    is($host->{order}, 0, 'the host has one too');
    is($host->{snapshot_shutdown}, 1, 'the host row says whether containers are stopped for their snapshot');
    is($host->{parallel_manual}, 1, 'and how a manual run is started');
    ok(!exists($ct101->{snapshot_shutdown}), 'a container row does not repeat a node setting');

    # It is a node setting about SNAPSHOTS: with snapshots off there is no
    # downtime to warn about, and the dialog must not promise any.
    PVE::UpdateManager::Config::save_settings('pve-test', { snapshot_before => 0 });
    ($host) = grep { $_->{type} eq 'node' } @{ $targets->({ node => 'pve-test' }) };
    is($host->{snapshot_shutdown}, 0, 'with snapshots off, nothing is shut down for one');

    PVE::UpdateManager::Config::save_settings('pve-test', { snapshot_before => 1 });
    PVE::UpdateManager::Config::save_order('lxc', 101, 0);
}

# ── starting a run ──────────────────────────────────────────────────────────
sub call_run {
    my (%param) = @_;

    local @PVE::RPCEnvironment::FORKED = ();

    my $res = eval { $run->({ node => 'pve-test', %param }) };
    my $err = $@;

    return { result => $res, error => $err, forked => [@PVE::RPCEnvironment::FORKED] };
}

{
    my $call = call_run(vmids => '101,102', host => 1);

    is($call->{error}, '', 'with every privilege the run starts');
    is(scalar(@{ $call->{forked} }), 1, 'as one worker for the whole selection');

    my $call2 = call_run();
    ok($call2->{error}, 'a run with no target selected is refused');
    is(scalar(@{ $call2->{forked} }), 0, 'and starts nothing');
}

{
    # Sys.Console, not Sys.Audit: this runs stored commands as root on the node.
    local $PVE::RPCEnvironment::CHECK = sub {
        my ($path, $privs) = @_;
        return !($path eq '/nodes/pve-test' && grep { $_ eq 'Sys.Console' } @$privs);
    };

    my $call = call_run(host => 1, vmids => '101');

    ok($call->{error}, 'the host cannot be updated without Sys.Console');
    is(
        scalar(@{ $call->{forked} }),
        0,
        'and the containers in the same request are not run either - the check is before the fork',
    );
}

{
    local $PVE::RPCEnvironment::CHECK = sub {
        my ($path) = @_;
        return $path ne '/vms/102';
    };

    my $call = call_run(vmids => '101,102');

    ok($call->{error}, 'one container the user may not run refuses the request');
    is(scalar(@{ $call->{forked} }), 0, 'and none of them is started');
}

# ── what each endpoint asks for ─────────────────────────────────────────────
#
# Read privileges for reading, write privileges for writing, and the same one
# for two endpoints that expose the same thing. A version of a script is the
# script, so it may not be cheaper to read than the script is.
{
    my $perm = sub {
        my ($name) = @_;
        my $def = PVE::RESTHandler::registered_def('PVE::UpdateManager::NodeAPI', $name);
        return $def->{permissions}->{check}
            ? join(',', @{ $def->{permissions}->{check}->[2] })
            : ($def->{permissions}->{user} // '?');
    };

    is($perm->('get_script'), 'Sys.Audit', 'reading the host script needs Sys.Audit');
    is($perm->('script_versions'), 'Sys.Audit', 'and so does listing its saved versions');
    is($perm->('script_version'), 'Sys.Audit', 'and reading one of them');
    is($perm->('set_script'), 'Sys.Modify', 'writing it needs Sys.Modify');
    is($perm->('set_order'), 'Sys.Modify', 'and so does its place in a run');
    is($perm->('delete_script'), 'Sys.Modify', 'as does removing it');
    is($perm->('get_settings'), 'Sys.Audit', 'the settings are readable with Sys.Audit');
    is(
        $perm->('set_settings'),
        'Sys.Console',
        'but writing them needs Sys.Console - a schedule runs commands as root unattended',
    );
    is($perm->('targets'), 'all', 'the list is open, and filters itself per row');
    is($perm->('run'), 'all', 'so is the run endpoint, which checks each target it is given');

    for my $name (qw(get_script set_script script_versions script_version set_order run targets)) {
        my $def = PVE::RESTHandler::registered_def('PVE::UpdateManager::NodeAPI', $name);
        # Without proxyto a request answered by another node would read its own
        # /etc/pve - which is the same file - but run the worker in the wrong
        # place, and check the privileges of the wrong node's path.
        is($def->{proxyto}, 'node', "$name is answered by the node it is about");
    }
}
