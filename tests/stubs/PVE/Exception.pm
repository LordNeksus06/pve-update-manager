package PVE::Exception;

# Test stub.

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(raise_param_exc raise raise_perm_exc);

sub raise_param_exc { my ($errors) = @_; die "parameter verification failed\n"; }
sub raise { my ($msg) = @_; die $msg; }
# The real one dies with an exception object whose text starts so.
sub raise_perm_exc { my ($what) = @_; die "Permission check failed" . (defined($what) ? " ($what)" : '') . "\n"; }

1;
