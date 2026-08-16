package PVE::RPCEnvironment;

# Test stub.

use strict;
use warnings;

sub get { return bless {}, __PACKAGE__; }
sub get_user { return 'root@pam'; }
sub check { return 1; }

# Every worker an endpoint asked for, so a test can tell "started a task" from
# "answered without starting one" - which is the difference between a run and a
# skip, and is invisible in the return value alone once a skip returns a string
# too.
our @FORKED;

sub fork_worker {
    my ($self, $dtype, $id, $user, $code) = @_;

    push @FORKED, { type => $dtype, id => $id, code => $code };

    return 'UPID:test:00000000:00000000:00000000:test::root@pam:';
}

1;
