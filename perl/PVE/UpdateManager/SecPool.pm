package PVE::UpdateManager::SecPool;

# A small process pool for the security scan (#40): runs a piece of work per
# item in a child, at most N at once, each with a deadline the parent enforces
# without ever waiting past it.
#
# Out of SecScan.pm, which went past 500 lines with it in.

use strict;
use warnings;

use POSIX ();
use Time::HiRes ();

# How often the parent looks at its children. A round of 10 000 targets at 4
# at once waits this long at most per slot freed.
our $POLL = 0.05;

# ── the pool ────────────────────────────────────────────────────────────────
#
# Runs $work->($item) in a child per item, at most $max at once. A child that
# is still alive at its deadline gets SIGKILL on its whole process group and is
# then NOT waited for: it is reaped with WNOHANG when it finally goes, and
# reported as 'timeout' now. Returns { index => exit status or 'timeout' }.
#
# The result travels through a file the child writes, not through the exit
# status: a child cannot say much in eight bits.
our $FORK = sub { fork() };

# How a child past its deadline is signalled. A test sets this to a no-op to
# stand in for a reader stuck in the kernel, which SIGKILL does not end
# (#36 V9) - the round has to finish anyway.
our $KILL = sub { my ($sig, $pid) = @_; kill($sig, $pid) };

sub run {
    my ($items, $max, $timeout, $round_deadline, $work) = @_;

    my %done;
    my %running;    # pid => [index, deadline]
    my @queue = (0 .. $#$items);

    my $reap = sub {
        while ((my $pid = waitpid(-1, POSIX::WNOHANG())) > 0) {
            my $slot = delete $running{$pid} or next;
            $done{ $slot->[0] } //= $? >> 8;
        }
    };

    while (@queue || %running) {
        $reap->();

        my $now = Time::HiRes::time();

        for my $pid (keys %running) {
            my ($idx, $deadline) = @{ $running{$pid} };
            next if $now < $deadline;
            $KILL->('KILL', -$pid);
            $KILL->('KILL', $pid);
            $done{$idx} = 'timeout';
            # Not waited for. A child stuck in the kernel survives SIGKILL; the
            # next _reap or the end of the worker process takes it.
            delete $running{$pid};
        }

        while (@queue && scalar(keys %running) < $max) {
            if ($now >= $round_deadline) {
                $done{$_} = 'round-deadline' for splice(@queue);
                last;
            }
            my $idx = shift @queue;
            my $pid = $FORK->();
            die "fork failed: $!\n" if !defined($pid);
            if (!$pid) {
                POSIX::setpgid(0, 0);
                # Said out loud: an error in here is otherwise only a missing
                # result, which the round reports as "did not finish in time" -
                # a sentence that sends whoever reads it looking for a hang.
                my $rc = eval { $work->($items->[$idx]); 0 };
                if (!defined($rc)) {
                    my $err = $@ // 'unknown error';
                    chomp($err);
                    print STDERR "security scan: item $idx failed: $err\n";
                    $rc = 1;
                }
                POSIX::_exit($rc);
            }
            $running{$pid} = [$idx, $now + $timeout];
        }

        Time::HiRes::sleep($POLL) if %running;
    }

    return \%done;
}

1;
