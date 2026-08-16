package PVE::LXC;

# Test stub. The lists are settable so a test can pretend containers exist.

use strict;
use warnings;

our %RUNNING;
our %CONFIG_LIST;

sub check_running { my ($vmid) = @_; return $RUNNING{$vmid}; }
sub config_list { return { %CONFIG_LIST }; }

1;
