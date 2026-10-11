package PVE::QemuServer::Monitor;

# Test stub. Every call is recorded with its arguments, and what it returns is
# up to the test: $HANDLER gets (vmid, command, %args) and either returns the
# agent's answer or dies the way the real one does on a timeout.

use strict;
use warnings;

use base 'Exporter';
our @EXPORT_OK = qw(mon_cmd);

our @CALLS;
our $HANDLER = sub { die "no agent handler in this test\n" };

sub mon_cmd {
    my ($vmid, $execute, %params) = @_;

    push @CALLS, { vmid => $vmid, cmd => $execute, args => {%params} };

    return $HANDLER->($vmid, $execute, %params);
}

1;
