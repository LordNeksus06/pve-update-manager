#!/usr/bin/perl
# The parsers of what a guest hands over take time in proportion to its size
# (#69).
#
# The claim: a line padded with a long run of blanks - written by root in the
# guest into its dpkg status file or its apt sources - is parsed in well under
# a second, not in time that grows with the square of the run. Before, a
# "value" of 160 000 blanks took 16.5 s, and 1 MiB (the sources limit) or
# 16 MiB (the status limit) far longer than the 60 s a target has: the reader
# child was killed, the target came out as a timeout, and its slot in the
# round's pool was held for the full minute in both passes.
#
# Each parse runs in a child that is killed after $LIMIT seconds, so a
# regression is a red line here, not a suite that hangs.

use strict;
use warnings;

use POSIX ();
use Test::More;
use Time::HiRes ();

use PVE::UpdateManager::SecCompare;
use PVE::UpdateManager::SecSources;

my $LIMIT = 10;
my $RUN = ' ' x 400_000;

# (seconds, the child's answer) - or undef seconds when it ran out of time.
sub timed {
    my ($code) = @_;
    pipe(my $r, my $w) or die "pipe: $!\n";
    my $t0 = Time::HiRes::time();
    my $pid = fork() // die "fork: $!\n";
    if (!$pid) {
        close($r);
        print {$w} $code->();
        close($w);
        POSIX::_exit(0);
    }
    close($w);
    # The child writes only once it is done, so a readable pipe means done; the
    # exit itself is waited for, a WNOHANG right after the read can race it.
    my $rin = '';
    vec($rin, fileno($r), 1) = 1;
    if (!select(my $rout = $rin, undef, undef, $LIMIT)) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        return (undef, '');
    }
    my $out = do { local $/; <$r> } // '';
    my $took = Time::HiRes::time() - $t0;
    waitpid($pid, 0);
    return ($took, $out);
}

sub fast {
    my ($what, $code, $want) = @_;
    my ($took, $out) = timed($code);
    ok(defined($took) && $took < $LIMIT,
        defined($took) ? sprintf('%s is parsed in %.2f s', $what, $took) : "$what is parsed within $LIMIT s");
    is($out, $want, "and still to the same result: $what");
}

# Premise: the runs are within the size limits these parsers apply, so they
# are parsed at all rather than refused for their length.
cmp_ok(2 * length($RUN) + 100, '<', $PVE::UpdateManager::SecSources::MAX_FILE, 'premise: within the sources limit');

fast('a dpkg status value padded with blanks', sub {
    my ($pkgs) = PVE::UpdateManager::SecCompare::installed_packages(
        "Package: a${RUN}b\nStatus: install ok installed\nArchitecture: amd64\nVersion: 1.0\n");
    return scalar(@$pkgs);
}, '0');

fast('a sources.list line padded with blanks', sub {
    my ($e, $skipped) = PVE::UpdateManager::SecSources::parse_sources(
        { '/etc/apt/sources.list' => "deb http://m.example/debian-security${RUN}trixie-security main${RUN}x\n" });
    return join(' ', scalar(@$e), $e->[0] ? @{ $e->[0]->{components} } : ());
}, '1 main x');

fast('a deb822 field padded with blanks', sub {
    my ($e) = PVE::UpdateManager::SecSources::parse_sources({ '/etc/apt/sources.list.d/a.sources' =>
        "Types: deb${RUN}deb-src\nURIs: http://m.example/debian-security\nSuites: trixie-security${RUN}\n"
        . "Components: main\n" });
    return join(' ', map { $_->{suite} } @$e);
}, 'trixie-security');

# Controls: trailing blanks are still not part of a value, in all three.
my ($pkgs) = PVE::UpdateManager::SecCompare::installed_packages(
    "Package: openssl \t\nStatus: install ok installed  \nArchitecture: amd64\nVersion: 3.5.1-1 \n");
is_deeply([map { "$_->{name}=$_->{version}" } @$pkgs], ['openssl=3.5.1-1'],
    'control: trailing blanks of a status field are not part of its value');
my ($e) = PVE::UpdateManager::SecSources::parse_sources(
    { '/etc/apt/sources.list' => "deb http://m.example/x trixie-security main  \t \n" });
is_deeply($e->[0]->{components}, ['main'], 'control: nor of a sources.list line');
($e) = PVE::UpdateManager::SecSources::parse_sources({ '/etc/apt/sources.list.d/a.sources' =>
    "Types: deb \nURIs: http://m.example/x\t\nSuites: trixie-security  \nComponents: main \n" });
is(scalar(@$e) && $e->[0]->{suite}, 'trixie-security', 'control: nor of a deb822 field');
($e) = PVE::UpdateManager::SecSources::parse_sources({ '/etc/apt/sources.list.d/a.sources' =>
    "Types: deb\nURIs: http://m.example/x\nSuites: trixie-security\nComponents: main\nEnabled: no \t\n" });
is(scalar(@$e), 0, 'control: "Enabled: no" followed by blanks still disables the entry');

done_testing();
