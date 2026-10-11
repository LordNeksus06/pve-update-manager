package PVE::UpdateManager::QemuAPI;

# API below /nodes/{node}/qemu/{vmid}/updatemgr - the per-VM tab.
#
# Registered into PVE::API2::Qemu at runtime by PVE::UpdateManager::Inject, so
# no file shipped by pve-manager carries a modified API tree. The methods
# themselves are PVE::UpdateManager::GuestAPI's, shared with the container tab.

use strict;
use warnings;

use PVE::RESTHandler;

use PVE::UpdateManager::GuestAPI;

use base qw(PVE::RESTHandler);

PVE::UpdateManager::GuestAPI::register_methods(__PACKAGE__, 'qemu');

1;
