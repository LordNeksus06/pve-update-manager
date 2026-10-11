package PVE::QemuServer::Helpers;

# Test stub.

use strict;
use warnings;

our %RUNNING;

sub vm_running_locally { my ($vmid) = @_; return $RUNNING{$vmid}; }

1;
