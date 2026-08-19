package PVE::Storage;

# Test stub. Only what the snapshot capability check asks for: the real
# storage.cfg is never read here, and PVE::LXC::Config's stub decides the answer
# instead - which is the decision the tests are actually about.

use strict;
use warnings;

our $CONFIG = { ids => {} };

sub config { return $CONFIG; }

1;
