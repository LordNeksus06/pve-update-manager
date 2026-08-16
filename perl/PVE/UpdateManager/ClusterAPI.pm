package PVE::UpdateManager::ClusterAPI;

# API below /cluster/updatemgr - what the Datacenter tab needs to show every
# node and every container of the cluster in one list.
#
# Read-only on purpose. Running is still done per node through
# /nodes/{node}/updatemgr/run, which is proxied to the node that owns the
# target - the Datacenter panel groups its selection by node and fires one
# request per node, so several servers really do update at the same time
# instead of queueing behind each other in a single worker.
#
# Everything here comes out of /etc/pve, which is the same on every node: the
# scripts, the state files, and the guest configs. That is what makes a
# cluster-wide view possible without asking each node in turn - and why a
# container's last update state is visible from whichever node you happen to be
# logged into.

use strict;
use warnings;

use PVE::API2::Cluster;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;

use PVE::UpdateManager::Config;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Update manager index.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {},
        },
        links => [{ rel => 'child', href => '{name}' }],
    },
    code => sub {
        return [{ name => 'targets' }];
    },
});

__PACKAGE__->register_method({
    name => 'targets',
    path => 'targets',
    method => 'GET',
    protected => 1,
    description => "List every update target in the cluster: every node and every container.",
    permissions => {
        description => "Lists only what the user may see: a node needs Sys.Audit on"
            . " /nodes/{node}, a container VM.Audit on /vms/{vmid}.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                type => { type => 'string', enum => ['node', 'lxc'] },
                id => { type => 'string', description => "Node name for a node, vmid for a container." },
                vmid => { type => 'integer', optional => 1 },
                node => { type => 'string', description => "The node that owns this target." },
                name => { type => 'string' },
                status => { type => 'string' },
                template => { type => 'boolean', optional => 1 },
                stored => { type => 'boolean', description => "An update script is stored for this target." },
                parallel_manual => {
                    type => 'boolean',
                    optional => 1,
                    description => "Node rows only: whether manual runs on that node start all"
                        . " targets at once. A datacenter-wide run honours each node's own"
                        . " setting for the targets that node owns.",
                },
                %{ PVE::UpdateManager::Config::last_run_schema() },
            },
        },
    },
    code => sub {
        # The cluster resource index is where the web interface itself gets its
        # tree from: every node and guest, with live status, already filtered by
        # what this user may see. Rebuilding that from /etc/pve would mean
        # guessing at the status of a guest on another node - this way the list
        # is exactly the one the user already sees in the sidebar, with our own
        # columns added.
        my $resources = PVE::API2::Cluster->resources({});

        my $nodes = [];
        my $guests = [];

        for my $r (@$resources) {
            my $type = $r->{type} // '';

            if ($type eq 'node') {
                my $node = $r->{node};
                push @$nodes, {
                    type => 'node',
                    id => $node,
                    node => $node,
                    name => $node,
                    status => $r->{status} // 'unknown',
                    stored => PVE::UpdateManager::Config::has_script('node', $node) ? 1 : 0,
                    parallel_manual =>
                        PVE::UpdateManager::Config::load_settings($node)->{parallel_manual} ? 1 : 0,
                    %{ PVE::UpdateManager::Config::last_run('node', $node) },
                };
            } elsif ($type eq 'lxc') {
                my $vmid = $r->{vmid};
                push @$guests, {
                    type => 'lxc',
                    id => "$vmid",
                    vmid => int($vmid),
                    node => $r->{node},
                    name => $r->{name} // "CT$vmid",
                    status => $r->{status} // 'unknown',
                    template => $r->{template} ? 1 : 0,
                    stored => PVE::UpdateManager::Config::has_script('lxc', $vmid) ? 1 : 0,
                    %{ PVE::UpdateManager::Config::last_run('lxc', $vmid) },
                };
            }
        }

        # Nodes first, then containers by id - the same order the node tab uses,
        # so switching between the two views does not rearrange the world.
        my $res = [
            (sort { $a->{name} cmp $b->{name} } @$nodes),
            (sort { $a->{vmid} <=> $b->{vmid} } @$guests),
        ];

        return $res;
    },
});

1;
