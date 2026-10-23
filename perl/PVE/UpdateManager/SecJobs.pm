package PVE::UpdateManager::SecJobs;

# What the security scan (#40) fetches for a target, and through which proxy:
# the jobs for its security suites (#37, #47) and the proxies for the
# severity download (#49).
#
# Out of SecScan.pm, which went past 500 lines with them in (#55).

use strict;
use warnings;

# security_source=debian: the target's own security suite, fetched from the
# distribution instead of the mirror it names, and without its proxy.
our %DIRECT = (
    debian => 'http://deb.debian.org/debian-security',
    ubuntu => 'http://security.ubuntu.com/ubuntu',
);

# The key an Ubuntu source without Signed-By is checked against (#47). Such a
# source - the one-line form an Ubuntu container ships - relies on the GUEST's
# trusted.gpg.d; on the node apt would check it against the node's, which
# holds Debian and Proxmox keys only, and answer "is not signed". Installing
# ubuntu-keyring on the node did not change that (measured on PVE 9.2.4: CT 102
# stayed "source unreachable"); naming its archive key does. Debian needs no
# entry: the node's own trusted.gpg.d is Debian's.
our %DEFAULT_KEY = (
    ubuntu => '/usr/share/keyrings/ubuntu-archive-keyring.gpg',
);

# The proxies to try for the severity download (#49): the one each guest's apt
# would use for the tracker's address - the per-host entry, the https one,
# the http one, as apt picks them (SecFetch::effective_proxy). Distinct ones,
# sorted; a direct connection last, and only if some guest has no proxy. With
# security_source=debian the guests' proxies are not used for their lists
# either, so not here. An empty list means direct.
sub severity_proxies {
    my ($metas, $settings) = @_;

    return [] if ($settings->{security_source} // 'configured') eq 'debian';
    require PVE::UpdateManager::SecFetch;
    require PVE::UpdateManager::SecSources;
    # SecSeverity is loaded lazily by the scan; read without loading it here.
    no warnings 'once';
    my $url = $PVE::UpdateManager::SecSeverity::URL
        // 'https://security-tracker.debian.org/tracker/data/json';

    my (%seen, $direct);
    for my $meta (@$metas) {
        # Only a guest whose apt configuration was read says anything about
        # its proxy; one that could not be read is not "direct".
        next if !exists($meta->{proxy});
        my $p = PVE::UpdateManager::SecFetch::effective_proxy({ uri => $url, proxy => $meta->{proxy} });
        if (!defined($p)) {
            $direct = 1;
        } elsif (defined(PVE::UpdateManager::SecSources::_norm_uri($p))) {
            $seen{$p} //= 1;
        }
    }
    # The guest names this address and the NODE connects to it, so it passes
    # the rule a source passes (#56): no loopback, no address of the node, no
    # credentials - as SecFetch checks the proxy of a list. Once per distinct
    # proxy, and only those: resolving a name can take seconds.
    for my $p (keys %seen) {
        my ($ok) = PVE::UpdateManager::SecSources::uri_allowed($p);
        delete $seen{$p} if !$ok;
    }
    return [] if !%seen;
    return [sort(keys %seen), ($direct ? (undef) : ())];
}

# The fetch jobs of one target: its security entries, or the distribution's
# own address with security_source=debian. $is_security says which suite is
# one - the scan passes its hook, so its tests decide that too.
sub security_jobs {
    my ($entries, $os, $proxy, $settings, $is_security) = @_;

    my @jobs;
    for my $e (@$entries) {
        next if !$is_security->($e->{suite});
        my $job = { uri => $e->{uri}, suite => $e->{suite},
            components => $e->{components}, signed_by => $e->{signed_by}, proxy => $proxy };
        if (($settings->{security_source} // 'configured') eq 'debian' && $DIRECT{$os}) {
            $job = { %$job, uri => $DIRECT{$os}, signed_by => undef, proxy => {} };
        }
        $job->{signed_by} //= $DEFAULT_KEY{$os};
        push @jobs, $job;
    }
    return \@jobs;
}

1;
