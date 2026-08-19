package PVE::RPCEnvironment;

# Test stub.

use strict;
use warnings;

sub get { return bless {}, __PACKAGE__; }
sub get_user { return 'root@pam'; }

# Allows everything unless a test says otherwise. $CHECK gets ($path, $privs)
# and returns true to allow; the real one RAISES when the third argument is not
# set, which is the behaviour the datacenter-wide save depends on - it checks
# every node before writing any of them, and a check that only returned false
# would let it write anyway.
our $CHECK;

sub check {
    my ($self, $user, $path, $privs, $noerr) = @_;

    return 1 if !$CHECK;
    return 1 if $CHECK->($path, $privs);

    return undef if $noerr;

    die "Permission check failed ($path, " . join(',', @$privs) . ")\n";
}

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
