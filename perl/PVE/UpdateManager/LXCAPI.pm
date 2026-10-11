package PVE::UpdateManager::LXCAPI;

# API below /nodes/{node}/lxc/{vmid}/updatemgr - the per-container tab.
#
# Registered into PVE::API2::LXC at runtime by PVE::UpdateManager::Inject, so
# no file shipped by pve-manager carries a modified API tree. The methods
# themselves are PVE::UpdateManager::GuestAPI's, shared with the VM tab.

use strict;
use warnings;

use PVE::RESTHandler;

use PVE::UpdateManager::GuestAPI;

use base qw(PVE::RESTHandler);

PVE::UpdateManager::GuestAPI::register_methods(__PACKAGE__, 'lxc');

1;
