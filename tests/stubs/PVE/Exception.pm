package PVE::Exception;

# Test stub.

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(raise_param_exc raise);

sub raise_param_exc { my ($errors) = @_; die "parameter verification failed\n"; }
sub raise { my ($msg) = @_; die $msg; }

1;
