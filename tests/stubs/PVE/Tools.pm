package PVE::Tools;

# Test stub. Enough of PVE::Tools for `perl -c` and for the unit tests to do
# real file I/O against a tmpdir - not a reimplementation, and never installed.

use strict;
use warnings;

# Enough of a UPID parser for the staleness check: UPID:node:pid:pstart:...
sub upid_decode {
    my ($upid, $noerr) = @_;

    if ($upid =~ m/\AUPID:([^:\s]+):([0-9A-Fa-f]+):([0-9A-Fa-f]+):/) {
        return { node => $1, pid => hex($2), pstart => hex($3) };
    }

    die "unable to parse worker upid '$upid'\n" if !$noerr;
    return undef;
}

sub file_get_contents {
    my ($filename, $max) = @_;

    open(my $fh, '<', $filename)
        or die "unable to open '$filename' - $!\n";
    local $/ = undef;
    my $data = <$fh>;
    close($fh);

    # An EMPTY file reads back as the empty string, not as undef. A slurp of
    # nothing returns undef in Perl, and the real file_get_contents does not -
    # it builds its answer with sysread and hands back ''. A stub that returned
    # undef here would make every "the file exists but is empty" path in the
    # callers untestable, because they all check defined() first.
    $data //= '';

    # The real one dies here rather than truncating, and a stub that quietly
    # returned the whole file would make the tests for oversized scripts prove
    # nothing. Same message, so the tests read like the production failure.
    die "file '$filename' too long - aborting\n"
        if defined($max) && defined($data) && length($data) > $max;

    return $data;
}

sub file_set_contents {
    my ($filename, $data, $perm) = @_;

    open(my $fh, '>', $filename)
        or die "unable to open '$filename' - $!\n";
    print $fh $data;
    close($fh)
        or die "unable to write '$filename' - $!\n";

    return;
}

# Recorded rather than executed: a test that actually ran `pct exec` would need
# a container. The unit tests read @PVE::Tools::RUN_CALLS to check what would
# have been run.
our $RUN_OUTPUT;
our $RUN_HOOK;

our @RUN_CALLS;
our $RUN_RC = 0;
our $RUN_DIE;

# Lets one test give different answers to different commands, which starting a
# stopped container needs: `pct start` and the readiness probe have to succeed
# while the update itself fails, or the test cannot check that the container is
# still put back afterwards. Returns undef to fall through to $RUN_RC.
our $RUN_RC_HOOK;

# The real one takes an flock. The tests care about what the guarded code does,
# not about flock itself, so this just runs it - and $LOCK_DIE lets a test take
# the path where the lock cannot be had.
our $LOCK_DIE;

sub lock_file {
    my ($filename, $timeout, $code, @param) = @_;

    die "$LOCK_DIE\n" if defined($LOCK_DIE);

    return $code->(@param);
}

sub run_command {
    my ($cmd, %param) = @_;

    push @RUN_CALLS, { cmd => $cmd, param => \%param };

    # Lets a test look at the world WHILE a target is running - which is the
    # only way to check that the "running" state is written before the command
    # rather than after it.
    $RUN_HOOK->($cmd, \%param) if $RUN_HOOK;

    # Lets a test take the path a timeout takes: run_command dies there no
    # matter what `noerr` says.
    die "$RUN_DIE\n" if defined($RUN_DIE);

    if (my $outfunc = $param{outfunc}) {
        $outfunc->($_) for @{ $RUN_OUTPUT // [] };
    }

    if ($RUN_RC_HOOK) {
        my $rc = $RUN_RC_HOOK->($cmd);
        return $rc if defined($rc);
    }

    return $RUN_RC;
}

1;
