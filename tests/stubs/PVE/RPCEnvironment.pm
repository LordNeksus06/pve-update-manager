package PVE::RPCEnvironment;

# Test stub.

use strict;
use warnings;

sub get { return bless {}, __PACKAGE__; }

# The schedule tool sets up a CLI environment before it forks its worker.
sub setup_default_cli_env { return; }
# Who is asking. root@pam unless a test says otherwise (#63-#65).
our $USER = 'root@pam';
sub get_user { return $USER; }

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

# Like the real one (PVE::RPCEnvironment::check_any, read on PVE 9.2.4): one of
# the privileges is enough. $CHECK is asked one privilege at a time.
sub check_any {
    my ($self, $user, $path, $privs, $noerr) = @_;

    return 1 if !$CHECK;
    for my $p (@$privs) {
        return 1 if $CHECK->($path, [$p]);
    }

    return undef if $noerr;

    die "Permission check failed ($path, " . join('|', @$privs) . ")\n";
}

# Every worker an endpoint asked for, so a test can tell "started a task" from
# "answered without starting one" - which is the difference between a run and a
# skip, and is invisible in the return value alone once a skip returns a string
# too.
our @FORKED;

sub fork_worker {
    my ($self, $dtype, $id, $user, $code, $background) = @_;

    # $background is recorded because the schedule tool depends on it: in a
    # 'cli' environment the real fork_worker runs the code synchronously unless
    # it is set - see the comment at the call in tools/pve-update-manager-schedule.
    push @FORKED, { type => $dtype, id => $id, user => $user, code => $code, background => $background };

    return 'UPID:test:00000000:00000000:00000000:test::root@pam:';
}

1;
