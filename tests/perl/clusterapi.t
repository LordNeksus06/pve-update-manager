#!/usr/bin/perl
# PVE::UpdateManager::ClusterAPI - the two things the Datacenter tab writes.
#
# Settings for every node at once, and the Templates menu the whole cluster
# shares. Both are the kind of button whose whole risk is in what it touches
# that nobody asked it to, so that is what is pinned here: which keys a
# datacenter-wide save leaves alone, and that it refuses outright rather than
# applying to half a cluster.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 35;

use PVE::API2::Cluster;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::UpdateManager::ClusterAPI;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Templates;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

my $get_settings = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'get_global_settings');
my $set_settings = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'set_global_settings');
my $get_templates = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'templates');
my $set_template = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'set_template');
my $del_template = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'delete_template');
my $reset_templates = PVE::RESTHandler::registered('PVE::UpdateManager::ClusterAPI', 'reset_templates');

@PVE::API2::Cluster::RESOURCES = (
    { type => 'node', node => 'pve-b' },
    { type => 'node', node => 'pve-a' },
    { type => 'lxc', vmid => 101, node => 'pve-a' },
);

# ── what a datacenter-wide save must NOT touch ──────────────────────────────
#
# A vmid lives on exactly one node. Broadcasting one node's schedule selection
# would point every other node at containers it does not have - and un-tick the
# ones it does.
{
    PVE::UpdateManager::Config::save_settings('pve-a', { schedule_vmids => '101,102', timeout => 600 });
    PVE::UpdateManager::Config::save_settings('pve-b', { schedule_vmids => '201', timeout => 900 });
    PVE::UpdateManager::Config::mark_schedule_run('pve-b', 12345);

    my $written = $set_settings->({ timeout => 7200, parallel_manual => 1 });

    is_deeply($written, ['pve-a', 'pve-b'], 'both nodes were written, and it says which');

    my $a = PVE::UpdateManager::Config::load_settings('pve-a');
    my $b = PVE::UpdateManager::Config::load_settings('pve-b');

    is($a->{timeout}, 7200, 'the first node took the new timeout');
    is($b->{timeout}, 7200, 'and so did the second, overwriting what it had');
    is($a->{parallel_manual}, 1, 'and the other value that was sent');

    is($a->{schedule_vmids}, '101,102', 'the first node kept its own scheduled containers');
    is($b->{schedule_vmids}, '201', 'and the second kept its own, which are different ones');
    is($b->{last_run}, 12345, 'the schedule clock was not moved either');
}

# Sending one key must not reset the others to their defaults - that is the
# difference between "apply these" and "reset everything and apply these".
{
    PVE::UpdateManager::Config::save_settings('pve-a', { start_stopped => 1, snapshot_keep => 7 });

    $set_settings->({ timeout => 3600 });

    my $a = PVE::UpdateManager::Config::load_settings('pve-a');
    is($a->{timeout}, 3600, 'the sent key is written');
    is($a->{start_stopped}, 1, 'an unsent key keeps the value that node had');
    is($a->{snapshot_keep}, 7, 'including the ones this dialog does not show');
}

# ── all or nothing ──────────────────────────────────────────────────────────
#
# Applying to half a cluster is worse than refusing: nothing on screen would say
# which half, and the operator would have to open every node to find out.
{
    PVE::UpdateManager::Config::save_settings('pve-a', { timeout => 1111 });
    PVE::UpdateManager::Config::save_settings('pve-b', { timeout => 1111 });

    local $PVE::RPCEnvironment::CHECK = sub {
        my ($path) = @_;
        return $path ne '/nodes/pve-b';
    };

    ok(
        !defined(eval { $set_settings->({ timeout => 2222 }); 1 }),
        'one node the user may not touch refuses the whole save',
    );

    is(
        PVE::UpdateManager::Config::load_settings('pve-a')->{timeout},
        1111,
        'and the node that WOULD have been allowed was not written either',
    );
}

# ── reporting what a save would do ──────────────────────────────────────────
{
    # From the same starting point on both nodes: the blocks above left them
    # differing in keys this one is not about, and "uniform" means all of them.
    my $same = { %{ PVE::UpdateManager::Config::default_settings() }, timeout => 4444 };
    PVE::UpdateManager::Config::save_settings('pve-a', { %$same });
    PVE::UpdateManager::Config::save_settings('pve-b', { %$same });

    my $res = $get_settings->({});

    is($res->{nodes}, 2, 'it counts the nodes a save would reach');
    is($res->{uniform}, 1, 'and says so when they already agree');
    is($res->{timeout}, 4444, 'prefilled with what they agree on');
    ok(!exists($res->{schedule_vmids}), 'and it does not offer the per-node key at all');
    ok(!exists($res->{last_run}), 'nor the schedule clock');

    PVE::UpdateManager::Config::save_settings('pve-b', { timeout => 5555 });

    $res = $get_settings->({});
    is($res->{uniform}, 0, 'a node that differs is reported, which is what the warning is for');
    is($res->{timeout}, 4444, 'and the prefill stays the first node, so a reload does not wander');
}

# A cluster of one still works - and it is the common case.
{
    local @PVE::API2::Cluster::RESOURCES = ({ type => 'node', node => 'pve-a' });

    my $res = $get_settings->({});
    is($res->{nodes}, 1, 'one node is a cluster too');
    is($res->{uniform}, 1, 'and it agrees with itself');
}

# Nothing to write to is an error, not a silent success.
{
    local @PVE::API2::Cluster::RESOURCES = ();

    ok(
        !defined(eval { $set_settings->({ timeout => 60 }); 1 }),
        'a save with no visible node refuses instead of reporting that it wrote nowhere',
    );
}

# ── the shared Templates menu ───────────────────────────────────────────────
{
    PVE::UpdateManager::Templates::reset_to_defaults();

    my $res = $get_templates->({});
    is($res->{custom}, 0, 'nothing stored yet');
    is(
        scalar(@{ $res->{templates} }),
        scalar(@{ PVE::UpdateManager::Templates::defaults() }),
        'and the built-in set is what is offered',
    );

    $set_template->({ name => 'House style', script => "#!/bin/sh\napt-get update\n" });

    $res = $get_templates->({});
    is($res->{custom}, 1, 'adding one makes the list a stored one');
    is($res->{templates}->[-1]->{name}, 'House style', 'and the new entry is in it');

    $set_template->({ name => 'House rules', script => "#!/bin/sh\napt-get update\n", oldname => 'House style' });
    $res = $get_templates->({});
    is($res->{templates}->[-1]->{name}, 'House rules', 'renaming goes through the same endpoint');

    ok(
        !defined(eval { $del_template->({ name => 'never existed' }); 1 }),
        'removing something that is not there is an error, not a quiet success',
    );

    $del_template->({ name => 'House rules' });
    $res = $get_templates->({});
    is($res->{custom}, 1, 'the list stays stored after a removal');
    is(
        scalar(@{ $res->{templates} }),
        scalar(@{ PVE::UpdateManager::Templates::defaults() }),
        'with the built-ins still in it',
    );

    # Throwing the whole list away is its OWN call, at its own path. It used to
    # be "a DELETE with the name left off", and a name that failed to reach the
    # server - a client putting it in the body of a DELETE where this API wants
    # a query string - would have turned "remove this one entry" into "reset
    # everything". A lost parameter must not fail in that direction.
    $set_template->({ name => 'temporary', script => "echo\n" });

    ok(
        !defined(eval { $del_template->({}); 1 }),
        'a DELETE with no name is refused rather than read as a reset',
    );
    my $still = $get_templates->({});
    is($still->{custom}, 1, 'and it changed nothing');

    my $def = PVE::RESTHandler::registered_def('PVE::UpdateManager::ClusterAPI', 'delete_template');
    ok(!$def->{parameters}->{properties}->{name}->{optional}, 'the name is required, not optional');

    $reset_templates->({});
    $res = $get_templates->({});
    is($res->{custom}, 0, 'a delete with no name resets the whole menu');
    is(
        scalar(@{ $res->{templates} }),
        scalar(@{ PVE::UpdateManager::Templates::defaults() }),
        'back to the built-ins',
    );
}
