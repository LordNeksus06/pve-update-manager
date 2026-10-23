package PVE::UpdateManager::SecAddress;

# Whether the node may fetch from an address a guest configured (#37). Its own
# module because SecSources.pm would otherwise pass the 500-line target (#21);
# SecSources::uri_allowed is the name callers use.

use strict;
use warnings;

use Socket qw(getaddrinfo unpack_sockaddr_in unpack_sockaddr_in6 inet_pton
    AF_INET AF_INET6 SOCK_STREAM);

our $MAX_URI = 2048;

# ── may the node fetch from here ────────────────────────────────────────────
#
# Refused: anything but http/https, credentials in the address, and any host
# that resolves to loopback, link-local, multicast, "this host", or an address
# of the node itself. Allowed: public and private addresses - a mirror on the
# LAN is the normal case for a cluster (owner, 2026-10-22, accepting that a
# taken-over guest can make the node ask internal addresses the guest itself
# cannot reach).
#
# Checked on the RESOLVED addresses, never on the text: "127.1", "2130706433",
# "0x7f.1", "localhost" and "[::ffff:127.0.0.1]" are all loopback, and a name
# can point anywhere. Every address a name resolves to has to pass, because
# apt may connect to any of them.
#
# What this does not close: apt resolves the name again when it connects, so a
# name whose DNS answer changes in between (rebinding) gets past this check.
# Pinning the address would break https, whose certificate names the host.

our $FIB_TRIE = '/proc/net/fib_trie';
our $IF_INET6 = '/proc/net/if_inet6';

# Host name -> list of [AF_INET|AF_INET6, packed address]. A variable so the
# tests can answer without DNS.
our $RESOLVE = sub {
    my ($host) = @_;
    my ($err, @res) = getaddrinfo($host, undef, { socktype => SOCK_STREAM });
    return () if $err;
    my @out;
    for my $r (@res) {
        if ($r->{family} == AF_INET) {
            push @out, [AF_INET, (unpack_sockaddr_in($r->{addr}))[1]];
        } elsif ($r->{family} == AF_INET6) {
            push @out, [AF_INET6, (unpack_sockaddr_in6($r->{addr}))[1]];
        }
    }
    return @out;
};

# The node's own addresses, read where the kernel lists them: /32 host LOCAL
# entries of the IPv4 routing trie, and every line of if_inet6. Read on each
# call - an address added since the last round counts at once.
sub local_addresses {
    my %own;

    if (open(my $fh, '<', $FIB_TRIE)) {
        my $ip;
        while (defined(my $l = <$fh>)) {
            if ($l =~ m/\|--\s+(\d{1,3}(?:\.\d{1,3}){3})\s*$/) {
                $ip = $1;
            } elsif (defined($ip) && $l =~ m{/32 host LOCAL}) {
                my $p = inet_pton(AF_INET, $ip);
                $own{$p} = 1 if defined($p);
            }
        }
        close($fh);
    }
    if (open(my $fh, '<', $IF_INET6)) {
        while (defined(my $l = <$fh>)) {
            my ($hex) = $l =~ m/\A([0-9a-f]{32})\s/ or next;
            $own{pack('H32', $hex)} = 1;
        }
        close($fh);
    }

    return \%own;
}

sub _v4_reason {
    my ($p) = @_;
    my ($a, $b) = unpack('CC', $p);
    return 'a loopback address' if $a == 127;
    return "a 'this host' address" if $a == 0;
    return 'a link-local address' if $a == 169 && $b == 254;
    return 'a multicast or reserved address' if $a >= 224;
    return undef;
}

# The category first, "an address of this node" last: 127.0.0.1 is both, and
# "loopback" is the more useful thing to read.
sub _addr_reason {
    my ($fam, $p, $own) = @_;

    my $why;
    if ($fam == AF_INET) {
        $why = _v4_reason($p);
    } else {
        my ($b0, $b1) = unpack('CC', $p);
        if ($p eq inet_pton(AF_INET6, '::1')) {
            $why = 'a loopback address';
        } elsif ($p eq inet_pton(AF_INET6, '::')) {
            $why = "a 'this host' address";
        } elsif ($b0 == 0xfe && ($b1 & 0xc0) == 0x80) {
            $why = 'a link-local address';
        } elsif ($b0 == 0xff) {
            $why = 'a multicast address';
        } elsif (substr($p, 0, 10) eq "\0" x 10 && substr($p, 10, 2) =~ m/\A(?:\xff\xff|\0\0)\z/) {
            # ::ffff:a.b.c.d and the old ::a.b.c.d reach the IPv4 address inside.
            my $v4 = substr($p, 12, 4);
            $why = _v4_reason($v4) // ($own->{$v4} ? 'an address of this node' : undef);
        }
    }

    return $why // ($own->{$p} ? 'an address of this node' : undef);
}

# (1) or (0, reason). The reason is a sentence fragment for a log line or the
# grid: "not fetched: <reason>".
sub uri_allowed {
    my ($uri) = @_;

    return (0, 'not a usable address') if !defined($uri) || length($uri) > $MAX_URI || $uri =~ m/[\x00-\x20\x7f-\xff]/;
    # The authority runs to the first "/" and nothing else, because that is
    # where apt (URI::CopyFrom, apt 3.0.3) ends it, splitting user and host at
    # the last "@" before it. Ending it at "?" or "#" as RFC 3986 does made
    # "http://deb.debian.org?@127.0.0.1/" pass here as deb.debian.org while
    # apt connected to 127.0.0.1 (#58). With the "/" rule the "@" is seen as
    # the credentials apt takes it for, and a "?" or "#" without one fails the
    # host pattern below.
    my ($scheme, $auth) = $uri =~ m{\A([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)};
    return (0, 'only http and https addresses are fetched') if !defined($scheme) || lc($scheme) !~ m/\Ahttps?\z/;
    return (0, 'an address with credentials is not fetched') if $auth =~ m/@/;

    my ($host, $port);
    if ($auth =~ m/\A\[([0-9A-Fa-f:.]{2,45})\](?::(\d{1,5}))?\z/) {
        ($host, $port) = ($1, $2);
    } elsif ($auth =~ m/\A([A-Za-z0-9][A-Za-z0-9.-]{0,252})(?::(\d{1,5}))?\z/) {
        ($host, $port) = ($1, $2);
    } else {
        return (0, 'not a usable host name');
    }
    return (0, 'not a usable port') if defined($port) && ($port < 1 || $port > 65535);

    my @addrs = $RESOLVE->($host);
    return (0, "'$host' does not resolve") if !@addrs;

    my $own = local_addresses();
    for my $a (@addrs) {
        my $why = _addr_reason(@$a, $own);
        return (0, "'$host' is $why") if defined($why);
    }

    return (1);
}

1;
