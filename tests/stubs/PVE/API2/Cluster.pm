package PVE::API2::Cluster;

# Test stub. ClusterAPI.pm calls PVE::API2::Cluster->resources to get the same
# node/guest list the web interface builds its tree from; the tests only need
# the class to exist and be settable.

use strict;
use warnings;

our @RESOURCES;

sub resources { return [@RESOURCES]; }

1;
