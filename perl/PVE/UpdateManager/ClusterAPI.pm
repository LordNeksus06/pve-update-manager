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
use PVE::UpdateManager::Templates;

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
        return [{ name => 'settings' }, { name => 'targets' }, { name => 'templates' }];
    },
});

# ── settings for every node at once ─────────────────────────────────────────
#
# The per-node settings stay where they are and stay authoritative - a run
# always follows the settings of the node that owns the target. What this adds
# is the way to stop maintaining twelve copies of the same four answers by hand.
#
# It really does overwrite: there is no merging and no "only where unset". That
# is what the confirmation in the web interface warns about, and it is the whole
# point of the button.
#
# No proxyto: every node's settings file lives in /etc/pve, which is the same
# filesystem everywhere, so one write reaches them all. Sending twelve HTTP
# requests to twelve nodes would only add twelve ways to half-succeed.

# Every node this user is allowed to see, from the same index the sidebar tree
# is built from.
my $visible_nodes = sub {
    my $resources = PVE::API2::Cluster->resources({});

    return [
        sort
        map { $_->{node} }
        grep { ($_->{type} // '') eq 'node' && defined($_->{node}) }
        @$resources
    ];
};

__PACKAGE__->register_method({
    name => 'get_global_settings',
    path => 'settings',
    method => 'GET',
    protected => 1,
    description => "The settings a datacenter-wide save would write, prefilled from the"
        . " first node, plus whether the nodes currently agree.",
    permissions => {
        description => "Reads only the nodes the user may see - a node needs Sys.Audit on"
            . " /nodes/{node}.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'object',
        properties => {
            %{ PVE::UpdateManager::Config::global_settings_schema() },
            nodes => {
                type => 'integer',
                description => "How many nodes a save would write to.",
            },
            uniform => {
                type => 'boolean',
                description => "True when every one of those nodes already has these values."
                    . " False means saving will change at least one of them - which is what"
                    . " the warning in the web interface is about.",
            },
        },
    },
    code => sub {
        my $nodes = $visible_nodes->();

        my $keys = [sort keys %{ PVE::UpdateManager::Config::global_settings_schema() }];

        # The first node alphabetically, so the same cluster always prefills the
        # same way. Any choice here is arbitrary; a choice that moves around
        # between reloads would be worse than arbitrary.
        my $first = scalar(@$nodes)
            ? PVE::UpdateManager::Config::load_settings($nodes->[0])
            : PVE::UpdateManager::Config::default_settings();

        my $res = { nodes => scalar(@$nodes), uniform => 1 };
        $res->{$_} = $first->{$_} for @$keys;

        for my $node (@$nodes) {
            my $settings = PVE::UpdateManager::Config::load_settings($node);
            next if !scalar(grep { ($settings->{$_} // '') ne ($first->{$_} // '') } @$keys);
            $res->{uniform} = 0;
            last;
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'set_global_settings',
    path => 'settings',
    method => 'PUT',
    protected => 1,
    description => "Write these settings to EVERY node, overwriting what each of them has."
        . " Each node keeps its own list of scheduled containers and its own last-run"
        . " stamp - those name things that exist on one node only.",
    permissions => {
        description => "Sys.Console on every node it would write to, checked before anything"
            . " is written: a half-applied datacenter-wide save is worse than a refused one,"
            . " because nothing on screen would say which half.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            (map { $_ => { %{ PVE::UpdateManager::Config::global_settings_schema()->{$_} }, optional => 1 } }
                keys %{ PVE::UpdateManager::Config::global_settings_schema() }),
        },
    },
    returns => {
        type => 'array',
        items => { type => 'string' },
        description => "The nodes that were written.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $nodes = $visible_nodes->();

        die "no node to write to\n" if !scalar(@$nodes);

        # ALL of them first, then write. Raises on the first node the user may
        # not touch, before a single file has been changed.
        $rpcenv->check($authuser, "/nodes/$_", ['Sys.Console']) for @$nodes;

        # Only what was actually sent. save_settings merges over what is stored,
        # so an unsent key keeps that node's value instead of being reset to a
        # default nobody asked for - which is what makes leaving a field out of
        # this request mean "do not touch it".
        my $settings = { map { $_ => $param->{$_} } grep { defined($param->{$_}) } keys %$param };

        PVE::UpdateManager::Config::save_settings($_, { %$settings }) for @$nodes;

        return $nodes;
    },
});

# ── the Templates menu ──────────────────────────────────────────────────────
#
# Cluster-wide, like everything else that lives in /etc/pve: a starting point
# somebody wrote on one node is in the menu on every node. That is also why this
# hangs off /cluster and not off a node - there is one list, not one per server,
# and a per-node list would mean the same container offered different templates
# depending on which node you happened to be logged into.
#
# No proxyto. /etc/pve is the same filesystem on every node, so the write lands
# in the same place wherever it is made.

my $template_properties = {
    name => {
        type => 'string',
        maxLength => $PVE::UpdateManager::Templates::MAX_NAME_LENGTH,
        description => "What the entry is called in the Templates menu.",
    },
    script => {
        type => 'string',
        maxLength => $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE,
        description => "The commands this template pastes into the editor.",
    },
};

__PACKAGE__->register_method({
    name => 'templates',
    path => 'templates',
    method => 'GET',
    protected => 1,
    description => "List the starting points offered by the Templates menu.",
    permissions => {
        description => "Anybody who can open an Update Manager tab sees the same menu, so"
            . " reading the list needs nothing beyond being logged in - a user with"
            . " VM.Audit on a single container can read every template. Treat the menu as"
            . " world-readable and keep credentials and internal hostnames out of it."
            . " Changing it needs Sys.Modify on /.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'object',
        properties => {
            custom => {
                type => 'boolean',
                description => "True when this list is stored. False means it is the built-in"
                    . " set, and there is nothing for a reset to undo.",
            },
            templates => {
                type => 'array',
                items => {
                    type => 'object',
                    properties => { %$template_properties },
                },
            },
        },
    },
    code => sub {
        my ($templates, $custom) = PVE::UpdateManager::Templates::load();

        return { custom => $custom ? 1 : 0, templates => $templates };
    },
});

__PACKAGE__->register_method({
    name => 'set_template',
    path => 'templates',
    method => 'PUT',
    protected => 1,
    description => "Add a template, or replace the one that is already called this."
        . " The first change writes the whole set out, built-ins included, so the menu"
        . " stops following the shipped defaults from then on.",
    permissions => {
        description => "The list is one menu for the whole cluster, and its entries are"
            . " commands somebody will run as root - so it takes the privilege that"
            . " datacenter-wide settings take.",
        check => ['perm', '/', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            %$template_properties,
            oldname => {
                type => 'string',
                optional => 1,
                maxLength => $PVE::UpdateManager::Templates::MAX_NAME_LENGTH,
                description => "Rename this entry to 'name' instead of adding a new one."
                    . " Without it a name that does not exist yet is appended.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::UpdateManager::Templates::store_one(
            $param->{name}, $param->{script}, $param->{oldname},
        );

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete_template',
    path => 'templates',
    method => 'DELETE',
    protected => 1,
    description => "Remove one template from the menu.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            # Required, and throwing the whole list away lives at its own path
            # below rather than behind an absent name here. A parameter that
            # fails to arrive - a client that puts it in the body of a DELETE
            # where this server wants a query string - would otherwise turn
            # "remove this one entry" into "reset everything", which is the one
            # direction a lost parameter must never fail in.
            name => {
                type => 'string',
                maxLength => $PVE::UpdateManager::Templates::MAX_NAME_LENGTH,
                description => "The entry to remove.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $name = $param->{name} // '';

        die "no template named '$name'\n"
            if !PVE::UpdateManager::Templates::remove_one($name);

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'reset_templates',
    path => 'templates/reset',
    method => 'POST',
    protected => 1,
    description => "Throw the stored template list away and go back to the built-in set."
        . " Every entry added or edited here is lost.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'null' },
    code => sub {
        PVE::UpdateManager::Templates::reset_to_defaults();

        return undef;
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
