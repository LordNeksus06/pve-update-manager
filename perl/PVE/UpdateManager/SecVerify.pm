package PVE::UpdateManager::SecVerify;

# After a run: are the security updates that were pending before it installed
# now (#73)? Decided by the owner on 2026-10-23:
#
# - A run is OK only when every security update pending before it is installed
#   afterwards - for every run, from the button, the schedule or the immediate
#   update, as long as the security check is switched on.
# - "Pending before" is the stored result of the last check, which already
#   leaves out excluded and below-threshold packages; one that appears during
#   the run is the next round's.
# - When one is not installed the run is NOT FIXED: red, but not a failure -
#   no rollback, that stays for a script that exits non-zero.
# - A guest that cannot be read afterwards is asked 3 times, 30 s apart; then
#   the run is NOT FIXED with that reason.
#
# Before, nothing looked: a script that exited 0 was OK even when openssl
# stayed old, and with security_notify_once the package was never reported
# again.

use strict;
use warnings;

use PVE::UpdateManager::SecCompare;

our $TRIES = 3;
our $WAIT = 30;

# Replaced by the tests.
our $READ = sub {
    require PVE::UpdateManager::SecRead;
    require PVE::UpdateManager::SecScan;
    no warnings 'once';
    return PVE::UpdateManager::SecRead::read_target($_[0], {
        timeout => $PVE::UpdateManager::SecScan::TARGET_TIMEOUT - 5,
        max_file => $PVE::UpdateManager::SecScan::MAX_FILE,
        max_total => $PVE::UpdateManager::SecScan::MAX_TOTAL,
    });
};
our $SLEEP = sub { sleep($_[0]) };

# The security updates pending for $target before its run, from the stored
# result of the last check - [] when the check is off or has nothing.
sub expected {
    my ($target, $opts) = @_;

    return [] if !$opts->{security_verify};

    require PVE::UpdateManager::SecScan;
    my $r = eval { PVE::UpdateManager::SecScan::load_result($target) } // return [];
    return [] if ($r->{status} // '') ne 'ok';

    return [
        map { { name => $_->{name}, arch => $_->{arch}, installed => $_->{installed}, fixed => $_->{fixed} } }
        grep {
            PVE::UpdateManager::SecCompare::valid_name($_->{name})
            && PVE::UpdateManager::SecCompare::valid_arch($_->{arch})
            && PVE::UpdateManager::SecCompare::valid_version($_->{fixed})
        } @{ $r->{pending} // [] }
    ];
}

# Which of $expected are still not installed. Returns { missing => [...] } and,
# when the guest could not be read, reason - then every expected one counts as
# missing, because "not shown" is not "installed".
sub verify {
    my ($target, $expected, $logfunc) = @_;

    return { missing => [] } if !@$expected;

    my $status;
    my $why = 'no answer';
    for my $try (1 .. $TRIES) {
        my $r = eval { $READ->($target) } // { status => 'error', reason => ($@ || 'reader died') };
        if (($r->{status} // '') eq 'ok' && defined($r->{files}->{'/var/lib/dpkg/status'})) {
            $status = $r->{files}->{'/var/lib/dpkg/status'};
            last;
        }
        $why = $r->{reason} // $r->{status} // 'no answer';
        chomp($why);
        last if $try == $TRIES;
        $logfunc->("the package list could not be read for the security check after the run"
            . " ($why) - trying again in ${WAIT}s ($try of $TRIES)") if $logfunc;
        $SLEEP->($WAIT);
    }

    if (!defined($status)) {
        return { missing => [@$expected], reason => "verification not possible: $why" };
    }

    my ($installed) = PVE::UpdateManager::SecCompare::installed_packages($status);
    my %now = map { ("$_->{name}:$_->{arch}" => $_->{version}) } @$installed;

    my @missing;
    for my $p (@$expected) {
        my $v = $now{"$p->{name}:$p->{arch}"};
        # Removed counts as done: a package that is gone cannot be exploited.
        next if !defined($v);
        next if PVE::UpdateManager::SecCompare::version_compare($v, $p->{fixed}) >= 0;
        push @missing, { %$p, installed => $v };
    }

    return { missing => \@missing, now => \%now };
}

# After the verification, the stored result of the last check is told what
# the run installed (#76): every pending entry installed at or above its fixed
# version now is dropped, a partly upgraded one keeps its new installed
# version. Before, the result stayed as the check had left it - the UI listed
# the 51 updates a run had just installed until the next round, and on a node
# with the check switched off for good.
#
# Only from a read that worked: "not shown" is not "installed". Not a new
# check either: what became pending since is the next round's, which is why
# `computed` and `checked` stay and only `refreshed` is set. The cache key goes,
# so the next round compares afresh instead of reusing an answer this edited.
our $NOW = sub { time() };

sub record {
    my ($target, $res, $logfunc) = @_;

    # A guest that could not be read has no `now` - verify returns before it.
    return if !$res->{now};
    my $now = $res->{now};
    my ($before, $after);

    my $done = eval {
        require PVE::UpdateManager::SecScan;
        PVE::UpdateManager::SecScan::update_result($target, sub {
            my ($r) = @_;
            return undef if ($r->{status} // '') ne 'ok';

            my @old = @{ $r->{pending} // [] };
            my ($changed, @kept) = (0);
            for my $p (@old) {
                my $v = $now->{"$p->{name}:$p->{arch}"};
                # An entry this cannot compare is left as the check wrote it.
                if (!PVE::UpdateManager::SecCompare::valid_version($p->{fixed})) {
                    push @kept, $p;
                    next;
                }
                if (!defined($v) || PVE::UpdateManager::SecCompare::version_compare($v, $p->{fixed}) >= 0) {
                    $changed = 1;
                    next;
                }
                $changed = 1 if ($p->{installed} // '') ne $v;
                push @kept, { %$p, installed => $v };
            }
            return undef if !$changed;

            ($before, $after) = (scalar(@old), scalar(@kept));
            my %r = (%$r, pending => \@kept, refreshed => $NOW->());
            delete $r{cache};
            # A warning about a source is only shown where something is pending.
            delete $r{warning} if !@kept;
            return \%r;
        });
    };

    return if !$logfunc;
    if (!defined($done)) {
        my $err = $@ || 'unknown error';
        chomp($err);
        $logfunc->("the stored security check result could not be updated: $err");
    } elsif ($done eq 'busy') {
        $logfunc->('a security check is running right now - it writes this target\'s result itself');
    } elsif ($done eq 'written') {
        $logfunc->("the stored security check result now lists $after pending update(s), was $before");
    }

    return;
}

# One line for the row, the log and the notification: "openssl 3.5.1-1,
# expected >= 3.5.1-1+deb13u1; libc6 ...". Facts travel as one line of at most
# 256 characters from a parallel run's child (Job.pm), so this is cut to fit.
sub describe {
    my ($res) = @_;

    my $text = join('; ', map { "$_->{name} $_->{installed}, expected >= $_->{fixed}" } @{ $res->{missing} });
    $text = "$res->{reason}: $text" if $res->{reason};
    $text = substr($text, 0, 240) . ' ...' if length($text) > 244;

    return $text;
}

1;
