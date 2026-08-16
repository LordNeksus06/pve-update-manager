package PVE::UpdateManager::Inject;

# Hooks the two API subtrees into Proxmox' route table.
#
# pvedaemon and pveproxy load this module (one `eval { require ... }` line added
# to each by the install hook). Doing it here instead of patching PVE::API2::LXC
# keeps every Proxmox-owned Perl module byte-identical - the only edit is that
# single require, which the hook re-applies after a pve-manager upgrade.
#
# Both daemons need it, not just pvedaemon: pveproxy resolves the route itself
# and only forwards the call once it sees the handler is `protected`. Without
# the registration there, the request is a 501 before pvedaemon is ever asked.
#
# Nothing in here may die. A broken addon must cost the operator a missing tab,
# never a Proxmox API that refuses to start - so the whole registration runs
# inside eval and a failure is reported to syslog and then dropped.

use strict;
use warnings;

use PVE::SafeSyslog;

my $registered = 0;

sub register {
    return 1 if $registered;

    # One eval PER subtree, not one around all three. Sharing an eval means a
    # single unloadable module takes every tab down with it - lose the cluster
    # resource index and the container tab disappears too, for no reason. Each
    # subtree now fails on its own and says which one.
    my $ok = 0;

    $ok += _register_one(
        'container',
        sub {
            require PVE::API2::LXC;
            require PVE::UpdateManager::LXCAPI;

            PVE::API2::LXC->register_method({
                subclass => "PVE::UpdateManager::LXCAPI",
                path => '{vmid}/updatemgr',
            });
        },
    );

    $ok += _register_one(
        'node',
        sub {
            require PVE::API2::Nodes;
            require PVE::UpdateManager::NodeAPI;

            PVE::API2::Nodes::Nodeinfo->register_method({
                subclass => "PVE::UpdateManager::NodeAPI",
                path => 'updatemgr',
            });
        },
    );

    $ok += _register_one(
        'cluster',
        sub {
            require PVE::API2::Cluster;
            require PVE::UpdateManager::ClusterAPI;

            PVE::API2::Cluster->register_method({
                subclass => "PVE::UpdateManager::ClusterAPI",
                path => 'updatemgr',
            });
        },
    );

    $registered = 1;

    return $ok;
}

sub _register_one {
    my ($what, $code) = @_;

    eval {
        $code->();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        chomp($err);
        eval { syslog('err', "pve-update-manager: %s API registration failed: %s", $what, $err); };
        warn "pve-update-manager: $what API registration failed: $err\n";
        return 0;
    };

    return 1;
}

register();

1;
