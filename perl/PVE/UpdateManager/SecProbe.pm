package PVE::UpdateManager::SecProbe;

# Does a security source still hand out its packages (#53)?
#
# A list can outlive its packages: on 2026-10-22 security.debian.org still
# served bullseye-security's InRelease and Packages, while every package file
# in it answered 404 - they had moved to archive.debian.org. The check then
# reported pending updates that no update run could install, and the run
# failed with "404 Not Found" on the guest. So after the lists are fetched,
# one package file per list is asked for with HEAD, through the proxy the
# guest's apt would use, and a 404 or 410 marks the list.
#
# The guest's sources are not rewritten (owner, 2026-10-23: "Nein aber
# Warnung sichtbar inkl benachrichtigung") - the check only says so.

use strict;
use warnings;

use PVE::Tools;

use PVE::UpdateManager::SecCompare;
use PVE::UpdateManager::SecFetch;

# Per request, and for all of a round: a source that does not answer must not
# hold the round, and "could not ask" is not a finding - only a 404 or 410 is.
our $TIMEOUT = 8;
our $BUDGET = 60;
# The same files the compare step reads, so the same limit (#62).
our $MAX_FILE = $PVE::UpdateManager::SecCompare::MAX_INDEX;

# Replaced by the tests: ($url, $proxy, $timeout) -> HTTP status, or undef
# when there was no answer.
our $HEAD = \&_head;

# The first package file a Packages index names, or undef. Its path is
# relative to the archive root and comes from the network: only the
# characters a pool path has, and no step out of it.
sub first_filename {
    my ($files) = @_;

    for my $f (@{ $files // [] }) {
        my $text = eval { PVE::Tools::file_get_contents($f, $MAX_FILE) } // next;
        my ($fn) = $text =~ m/^Filename:[ \t]*(\S+)[ \t]*$/m or next;
        next if $fn !~ m{\A[A-Za-z0-9][A-Za-z0-9._+~%/-]{0,1023}\z} || $fn =~ m{(?:\A|/)\.\.?(?:/|\z)};
        return $fn;
    }
    return undef;
}

# Marks $lists->{key}->{pool_error} for every fetched security list whose
# package file is gone. $jobs maps the same keys to the jobs.
sub probe {
    my ($jobs, $lists, $log) = @_;

    my $end = time() + $BUDGET;
    for my $key (sort keys %$jobs) {
        my $l = $lists->{$key} // next;
        next if $l->{error} || !$l->{is_security};
        my $fn = first_filename($l->{packages}) // next;

        if (time() >= $end) {
            $log->("package files of the remaining sources not checked: $BUDGET s used up") if $log;
            last;
        }

        my $job = $jobs->{$key};
        (my $base = $job->{uri}) =~ s{/+\z}{};
        my $url = "$base/$fn";
        my $proxy = PVE::UpdateManager::SecFetch::effective_proxy({ uri => $url, proxy => $job->{proxy} });
        my $code = eval { $HEAD->($url, $proxy, $TIMEOUT) };
        next if !defined($code) || ($code != 404 && $code != 410);

        $l->{pool_error} = "$job->{uri} $job->{suite} lists updates, but its package files answer"
            . " HTTP $code (e.g. $url) - an update run will fail; the archive may have moved";
    }
    return;
}

sub _head {
    my ($url, $proxy, $timeout) = @_;

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
        agent => 'pve-update-manager',
        timeout => $timeout,
        max_redirect => 0,
        protocols_allowed => ['http', 'https'],
    );
    $ua->proxy(['http', 'https'], $proxy) if defined($proxy);
    my $res = $ua->head($url);
    # LWP reports its own failures (no connection, timeout) as 500 with a
    # Client-Warning header: no answer from the server, so no finding.
    return undef if ($res->header('Client-Warning') // '') eq 'Internal response';
    return $res->code;
}

1;
