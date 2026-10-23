package PVE::UpdateManager::SecSources;

# Which package sources a target has configured, which proxy it uses for them,
# and whether the node may fetch from such an address at all (#37).
#
# Everything parsed here was read out of a guest. Root in the guest writes
# these files, so they are input from the other side: every field is checked
# against what it may look like, a line that fails is skipped and counted
# rather than guessed at, and nothing here reads a file, follows an include or
# runs a command named in one. The texts come in as strings; reading them out
# of the guest (bounded, without following symlinks) is the caller's job.
#
# And the address a guest names is fetched by the NODE, which is root on the
# management network. uri_allowed() is the line between "fetch what the guest
# configured" (decided by the owner, 2026-10-22) and "let a guest make the node
# talk to itself".

use strict;
use warnings;

use PVE::UpdateManager::SecAddress;

# A real sources file is a few hundred bytes, a large apt.conf.d a few KiB.
# Anything longer than this is not configuration and is skipped whole.
our $MAX_FILE = 1024 * 1024;
# More entries than any real system has, so a file that repeats one line a
# million times costs one bounded list rather than one fetch each.
our $MAX_ENTRIES = 1024;
our $MAX_URI = $PVE::UpdateManager::SecAddress::MAX_URI;    # one limit for both checks

# ── /etc/os-release ─────────────────────────────────────────────────────────

# { id, version_codename }, each undef when missing or not a plain word. The
# codename picks the security suite a target is compared against, and it ends
# up in a file name further on - so "trixie" passes and "../x" does not.
sub parse_os_release {
    my ($text) = @_;

    my %v;
    return { id => undef, version_codename => undef }
        if !defined($text) || length($text) > $MAX_FILE;

    for my $line (split(/\n/, $text)) {
        my ($k, $raw) = $line =~ m/\A([A-Z][A-Z0-9_]{0,63})=(.*)\z/ or next;
        next if $k ne 'ID' && $k ne 'VERSION_CODENAME';
        my $val = $raw;
        # os-release(5): shell-style, optionally in single or double quotes.
        # Escapes are not interpreted: the two values wanted here never need
        # one, and an escape in them fails the word check below anyway.
        $val = $1 if $raw =~ m/\A"(.*)"\z/ || $raw =~ m/\A'(.*)'\z/;
        # The first assignment wins, like for dpkg fields (#39): a second ID=
        # appended by hand must not override the one the distribution wrote.
        $v{$k} //= $val;
    }

    my $word = sub {
        my ($x) = @_;
        return defined($x) && $x =~ m/\A[a-z0-9][a-z0-9._-]{0,63}\z/ ? $x : undef;
    };

    return { id => $word->($v{ID}), version_codename => $word->($v{VERSION_CODENAME}) };
}

# ── fields of a source entry ────────────────────────────────────────────────

# A suite like "trixie-security", or the old "buster/updates". A suite ending
# in "/" is a flat repository, which no security archive is; it is skipped.
sub _valid_suite {
    my ($s) = @_;
    return 0 if !defined($s) || $s =~ m/\.\./;
    return $s =~ m{\A[A-Za-z0-9][A-Za-z0-9._~+-]{0,127}(?:/[A-Za-z0-9._~+-]{1,64})?\z} ? 1 : 0;
}

sub _valid_component {
    my ($c) = @_;
    return defined($c) && $c !~ m/\.\./ && $c =~ m{\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}(?:/[A-Za-z0-9._+-]{1,64})?\z} ? 1 : 0;
}

# Any scheme is kept here and judged by uri_allowed(), so that a target whose
# only security source is "file:/srv/mirror" can be told so instead of being
# told it has none. What is refused here is only what cannot be a URI at all.
sub _norm_uri {
    my ($u) = @_;
    return undef if !defined($u) || length($u) > $MAX_URI;
    return undef if $u !~ m/\A[A-Za-z][A-Za-z0-9+.-]{0,31}:[\x21-\x7e]+\z/;
    # A quote or backslash is never part of a mirror address, and would break
    # the quoting of the apt.conf a proxy address is written into.
    return undef if $u =~ m/["\\]/;
    # "http://deb.debian.org/debian-security/" and the same without the slash
    # are one source to apt, and must be one fetch here.
    if ($u =~ m{\A([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(.*)\z}) {
        my ($scheme, $auth, $path) = (lc($1), lc($2), $3);
        $path =~ s{/+\z}{};
        return "$scheme://$auth$path";
    }
    return $u;
}

# Signed-By is honoured only as a list of absolute file names; whether the node
# has those files is SecFetch's question. An inline key or a fingerprint is
# not used - an inline key would be the GUEST choosing the key the node trusts
# for an index - and the entry says so, so it can be shown.
sub _signed_by {
    my ($val, $multiline) = @_;

    return (undef, 'inline key') if $multiline;
    return (undef, undef) if !defined($val) || $val eq '';

    my @parts = grep { length } split(/[\s,]+/, $val);
    return (undef, undef) if !@parts;
    for my $p (@parts) {
        return (undef, 'fingerprint') if $p !~ m{\A/};
        return (undef, 'unusable key path') if $p !~ m{\A(?:/[A-Za-z0-9._+-]{1,255}){1,16}\z} || $p =~ m{/\.\.?(?:/|\z)};
    }

    return (join(',', @parts), undef);
}

sub _entry {
    my ($file, $uri, $suite, $comps, $signed_by, $mark) = @_;

    my $u = _norm_uri($uri);
    return undef if !defined($u) || !_valid_suite($suite);
    return undef if !@$comps || grep { !_valid_component($_) } @$comps;

    return {
        uri => $u, suite => $suite, components => [@$comps],
        signed_by => $signed_by, signed_by_ignored => $mark, file => $file,
    };
}

# ── one-line format, sources.list(5) ────────────────────────────────────────

sub _parse_list {
    my ($file, $text, $out) = @_;

    my $skipped = 0;
    for my $line (split(/\n/, $text)) {
        # A # starts a comment anywhere on the line, as apt reads it.
        $line =~ s/#.*\z//s;
        next if $line =~ m/\A\s*\z/;

        # Not "(.*?)\s*\z": its cost grows with the square of a run of blanks
        # (#69). Trailing blanks need no trim - split below drops the empty
        # fields they would make.
        my ($type, $opts, $rest) = $line =~ m/\A\s*(deb|deb-src)(?:\s+\[([^\]]*)\])?\s+(.*)\z/;
        if (!defined($type)) {
            $skipped++;
            next;
        }
        next if $type eq 'deb-src';    # not a package index, nothing to compare with

        my ($uri, $suite, @comps) = split(/\s+/, $rest);
        my ($signed_by, $mark);
        for my $o (split(/\s+/, $opts // '')) {
            next if $o eq '';
            my ($k, $v) = $o =~ m/\A([A-Za-z-]+)=(.*)\z/ or next;
            ($signed_by, $mark) = _signed_by($v, 0) if lc($k) eq 'signed-by';
        }

        my $e = _entry($file, $uri, $suite, \@comps, $signed_by, $mark);
        if (!$e) {
            $skipped++;
            next;
        }
        push @$out, $e;
    }

    return $skipped;
}

# ── deb822 format, the *.sources files ──────────────────────────────────────

# Not SecCompare::parse_stanzas: that one drops continuation lines, and here a
# continuation line is what tells an inline key from a path.
sub _deb822 {
    my ($text) = @_;

    my @res;
    my ($cur, $last) = ({}, undef);
    for my $line (split(/\n/, $text, -1)) {
        next if $line =~ m/\A#/;
        if ($line =~ m/\A\s*\z/) {
            push @res, $cur if %$cur;
            ($cur, $last) = ({}, undef);
            next;
        }
        if ($line =~ m/\A[ \t]/) {
            $cur->{"$last+"} = 1 if defined($last);
            next;
        }
        # Same split of match and trim as in SecCompare::parse_stanzas (#69).
        my ($f, $v) = $line =~ m/\A([A-Za-z0-9][A-Za-z0-9-]{0,63}):[ \t]*(.*)\z/;
        if (!defined($f)) {
            $cur->{'?'} = 1;    # a line that is no field: the stanza is suspect
            $last = undef;
            next;
        }
        $v =~ s/[ \t]+\z//;
        # deb822 field names are case-insensitive; the first occurrence wins.
        $last = lc($f);
        $cur->{$last} //= $v;
    }
    push @res, $cur if %$cur;

    return \@res;
}

sub _parse_sources822 {
    my ($file, $text, $out) = @_;

    my $skipped = 0;
    for my $s (@{ _deb822($text) }) {
        if ($s->{'?'} || !defined($s->{types}) || !defined($s->{uris}) || !defined($s->{suites})) {
            $skipped++;
            next;
        }
        next if defined($s->{enabled}) && lc($s->{enabled}) eq 'no';

        my @types = split(/\s+/, $s->{types});
        next if !grep { $_ eq 'deb' } @types;

        my ($signed_by, $mark) = _signed_by($s->{'signed-by'}, $s->{'signed-by+'});
        my @comps = split(/\s+/, $s->{components} // '');
        for my $uri (split(/\s+/, $s->{uris})) {
            for my $suite (split(/\s+/, $s->{suites})) {
                my $e = _entry($file, $uri, $suite, \@comps, $signed_by, $mark);
                if (!$e) {
                    $skipped++;
                    next;
                }
                push @$out, $e;
            }
        }
    }

    return $skipped;
}

# (\@entries, $skipped) for all files of one target, keyed by absolute path.
# A file is read as one-line format when it is sources.list or ends in .list,
# as deb822 when it ends in .sources - the rule apt applies - and any other
# name is ignored, as apt ignores it. Sorted by path so the result does not
# depend on hash order.
sub parse_sources {
    my ($files) = @_;

    my (@entries, $skipped);
    $skipped = 0;
    for my $path (sort keys %{ $files // {} }) {
        my $text = $files->{$path};
        next if !defined($text);
        if (length($text) > $MAX_FILE) {
            $skipped++;
            next;
        }
        if ($path =~ m{/sources\.list\z} || $path =~ m{\.list\z}) {
            $skipped += _parse_list($path, $text, \@entries);
        } elsif ($path =~ m{\.sources\z}) {
            $skipped += _parse_sources822($path, $text, \@entries);
        }
    }

    if (@entries > $MAX_ENTRIES) {
        $skipped += @entries - $MAX_ENTRIES;
        splice(@entries, $MAX_ENTRIES);
    }

    return (\@entries, $skipped);
}

# A security suite by name: "<codename>-security" since bullseye and on
# Ubuntu, "<codename>/updates" before. Only these are fetched - the main
# archive's Packages is tens of MB per target release, and nothing in it is a
# security fix that the security suite does not also carry. Whether an index
# really IS the security archive is decided by its Release file afterwards
# (SecFetch), not by this name.
sub is_security_suite {
    my ($suite) = @_;
    return defined($suite) && $suite =~ m{(?:-security|/updates)\z} ? 1 : 0;
}

# ── proxy, from apt.conf and apt.conf.d ─────────────────────────────────────

# apt reads apt.conf.d/* in lexical order, then apt.conf; it skips names with
# characters outside [A-Za-z0-9_.-] and backup suffixes. Same order here, so
# the value that wins in the guest wins here.
sub _conf_order {
    my ($files) = @_;

    my (@parts, @main);
    for my $p (keys %$files) {
        if ($p =~ m{/apt\.conf\z}) {
            push @main, $p;
            next;
        }
        my ($base) = $p =~ m{/([^/]+)\z} or next;
        next if $base !~ m/\A[A-Za-z0-9_.-]+\z/;
        next if $base =~ m/(?:~|\.disabled|\.bak|\.dpkg-[a-z]+|\.ucf-[a-z]+|\.save|\.orig)\z/;
        push @parts, $p;
    }

    return ((sort { ($a =~ m{([^/]+)\z})[0] cmp ($b =~ m{([^/]+)\z})[0] } @parts), sort @main);
}

# Key/value pairs of an apt.conf text, keys lowercased and joined with "::".
# Handles both "Acquire::http::Proxy "x";" and the scoped form
# "Acquire { http { Proxy "x"; }; };", and the three comment styles. #include
# is NOT followed: it would read a file of the node on the guest's say-so.
sub _conf_pairs {
    my ($text) = @_;

    my (@pairs, @scope, $name);
    pos($text) = 0;
    while (pos($text) < length($text)) {
        if ($text =~ m{\G\s+}gc || $text =~ m{\G//[^\n]*}gc || $text =~ m{\G/\*.*?(?:\*/|\z)}gcs) {
            next;
        }
        if ($text =~ m{\G#[^\n]*}gc) {    # comment, #clear, #include - all skipped
            next;
        }
        if ($text =~ m{\G"([^"\n]*)"?}gc) {
            push @pairs, [join('::', @scope, $name), $1] if defined($name);
            $name = undef;
            next;
        }
        if ($text =~ m{\G\{}gc) {
            push @scope, lc($name // '') if @scope < 16;
            $name = undef;
            next;
        }
        if ($text =~ m{\G\}}gc) {
            pop @scope;
            $name = undef;
            next;
        }
        if ($text =~ m{\G;}gc) {
            $name = undef;
            next;
        }
        if ($text =~ m{\G([A-Za-z0-9_:./+-]{1,512})}gc) {
            my $w = $1;
            if (defined($name)) {    # an unquoted value
                push @pairs, [join('::', @scope, $name), $w];
                $name = undef;
            } else {
                $name = lc($w);
            }
            next;
        }
        $text =~ m{\G.}gcs;    # anything else: one character further, never die
    }

    return \@pairs;
}

sub _proxy_value {
    my ($v) = @_;
    return '' if $v eq '';
    return 'DIRECT' if uc($v) eq 'DIRECT';
    return _norm_uri($v);
}

# { http => uri|undef, https => uri|undef, hosts => { host => uri|'DIRECT' } }
#
# Only the Proxy keys are taken. Proxy-Auto-Detect is ignored on purpose: its
# value is a command, and the node would run it. A per-host entry for https
# and one for http land in the same map; apt looks a host up in the map of
# the scheme and the guests seen do not set both differently.
sub parse_proxy {
    my ($files) = @_;

    my %res = (http => undef, https => undef, hosts => {});
    $files //= {};
    for my $path (_conf_order($files)) {
        my $text = $files->{$path};
        next if !defined($text) || length($text) > $MAX_FILE;
        for my $pair (@{ _conf_pairs($text) }) {
            my ($k, $v) = @$pair;
            my $val = _proxy_value($v);
            next if !defined($val);
            if ($k =~ m/\Aacquire::(https?)::proxy\z/) {
                $res{$1} = $val eq '' ? undef : $val;
            } elsif ($k =~ m/\Aacquire::https?::proxy::([a-z0-9][a-z0-9.-]{0,252})\z/) {
                if ($val eq '') {
                    delete $res{hosts}->{$1};
                } elsif (keys %{ $res{hosts} } < 256) {
                    $res{hosts}->{$1} = $val;
                }
            }
        }
    }

    return \%res;
}

# ── may the node fetch from here ────────────────────────────────────────────

# (1) or (0, reason) - see SecAddress.pm, where the rules and their reasons are.
sub uri_allowed {
    return PVE::UpdateManager::SecAddress::uri_allowed(@_);
}

1;
