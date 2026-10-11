package PVE::QemuServer;

# Test stub: the VMs this node pretends to have.

use strict;
use warnings;

our %CONFIG_LIST;

sub config_list { return { map { $_ => { exists => 1 } } keys %CONFIG_LIST }; }

1;
