package PVE::UpdateManager::SecCompare;

# Which installed packages of a target have a pending security update: reading
# a dpkg status file and a security Packages index, and comparing the two (#39).
#
# Everything here reads text that belongs to somebody else. The status file
# comes out of a guest, where root can write anything into it; the index comes
# off a mirror the guest named. So every field goes through a strict check
# before it is used, an entry that fails one is skipped and counted rather than
# guessed at, and the amount read is bounded - a parser here may be handed a
# FIFO, a 10 GB file or random bytes, and none of those may cost more than the
# one target they came from.

use strict;
use warnings;

# ── comparing two versions ──────────────────────────────────────────────────
#
# AptPkg where it exists, Dpkg::Version where it does not.
#
# Measured on the lab PVE (#36 V4), the same 200 evaluations of a real status
# file against trixie-security: AptPkg 7.5 ms per target, Dpkg::Version 24.0 ms,
# Python's apt_pkg 7.7 ms. Same answers from all three over 548 372 pairs of
# real version strings, so the choice is speed and nothing else.
#
# pve-manager depends on libapt-pkg-perl and uses it itself (PVE/API2/APT.pm),
# so on a node AptPkg is always there. The fallback is for the test suite: the
# CI runner and a development machine have libdpkg-perl (dpkg-dev pulls it in)
# but not libapt-pkg-perl, and a test that only runs where the fast library is
# installed is a test that does not run.
our $BACKEND;
my $apt_versioning;

sub _init_backend {
    return if defined($BACKEND);

    if (eval {
        require AptPkg::Config;
        require AptPkg::System;
        no warnings 'once';
        $AptPkg::Config::_config->init;
        $AptPkg::System::_system = $AptPkg::Config::_config->system;
        $apt_versioning = $AptPkg::System::_system->versioning;
        1;
    }) {
        $BACKEND = 'AptPkg';
        return;
    }

    require Dpkg::Version;
    $BACKEND = 'Dpkg::Version';
}

# <0, 0 or >0, like the comparison of a sort. Only called with versions that
# passed valid_version(): both libraries accept malformed strings and answer
# something, and "something" is not what a security decision may rest on.
sub version_compare {
    my ($a, $b) = @_;

    _init_backend();

    return $apt_versioning->compare($a, $b) if $BACKEND eq 'AptPkg';

    return Dpkg::Version::version_compare($a, $b);
}

# ── what a field may look like ──────────────────────────────────────────────
#
# Debian policy 5.6.12: [epoch:]upstream[-revision], the upstream part starting
# with a digit, from [A-Za-z0-9.+~-] (a colon only after an epoch). The length
# cap is ours: the longest version among the 23 822 distinct ones on a trixie
# machine is far below it, and a 1 MB "version" is not one.
our $MAX_VERSION = 256;

sub valid_version {
    my ($v) = @_;

    return 0 if !defined($v) || length($v) > $MAX_VERSION;

    return $v =~ m/\A(?:[0-9]+:)?[0-9][A-Za-z0-9.+~-]*\z/ ? 1 : 0;
}

# Policy 5.6.1: lowercase letters, digits, + - . and at least two characters,
# starting with a letter or digit.
our $MAX_NAME = 128;

sub valid_name {
    my ($n) = @_;

    return 0 if !defined($n) || length($n) > $MAX_NAME;

    return $n =~ m/\A[a-z0-9][a-z0-9+.-]+\z/ ? 1 : 0;
}

sub valid_arch {
    my ($a) = @_;

    return defined($a) && $a =~ m/\A[a-z0-9-]{1,32}\z/ ? 1 : 0;
}

# ── deb822 stanzas ──────────────────────────────────────────────────────────
#
# Both inputs are the same format: blocks separated by an empty line, one
# "Field: value" per line, continuation lines starting with a space. Only the
# fields asked for are kept, which is also what keeps a hostile file from
# turning into a large hash.
#
# Not a general deb822 parser on purpose. Multi-line values (Description,
# Conffiles) are continuation lines and are skipped; nothing this needs is ever
# one.
sub parse_stanzas {
    my ($text, $wanted) = @_;

    my %want = map { $_ => 1 } @$wanted;
    my @res;
    my $cur = {};

    # Split on \n only. A \r is not a line ending in either file, and treating
    # it as one would let "Status: x\rinstall ok installed" mean two things.
    for my $line (split(/\n/, $text // '', -1)) {
        if ($line eq '') {
            push @res, $cur if %$cur;
            $cur = {};
            next;
        }
        # A continuation line starts with a space or a tab, and the field name
        # has to start with a letter or digit - so this is also what skips
        # them. A separate check for them reddened no test (#39 mutant M4).
        # Greedy to the end, trailing blanks stripped apart. The one-regex
        # form "(.*?)[ \t]*\z" retried every run of blanks from each of its
        # positions: 160 000 blanks in a guest's status file cost 16 s,
        # growing with the square (#69).
        my ($field, $value) = $line =~ m/\A([A-Za-z0-9][A-Za-z0-9-]{0,63}):[ \t]*(.*)\z/
            or next;
        $value =~ s/[ \t]+\z//;
        next if !$want{$field};
        # The first occurrence wins. A stanza that names its version twice is
        # malformed, and taking the later one would let a line appended by hand
        # override the one dpkg wrote.
        $cur->{$field} //= $value;
    }
    push @res, $cur if %$cur;

    return \@res;
}

# ── the installed side ──────────────────────────────────────────────────────

# Installed packages of a dpkg status file: name, architecture, version and
# source package. Returns ($packages, $skipped), where $skipped counts stanzas
# that claimed to be installed but did not pass the field checks - reported,
# because a target whose status file is half garbage has a result that is half
# missing, and that must not read as "nothing pending".
sub installed_packages {
    my ($text) = @_;

    my $skipped = 0;
    my @res;

    for my $s (@{ parse_stanzas($text, [qw(Package Status Architecture Version Source)]) }) {
        # "want ok status": only a package dpkg calls installed has files on
        # disk that a security fix would replace. config-files, half-installed,
        # unpacked and the rest are not counted - and not skipped either, they
        # are simply not installed.
        my @status = split(/ /, $s->{Status} // '');
        next if scalar(@status) != 3 || $status[2] ne 'installed';

        my ($name, $arch, $version) = @{$s}{qw(Package Architecture Version)};
        if (!valid_name($name) || !valid_arch($arch) || !valid_version($version)) {
            $skipped++;
            next;
        }

        # "Source: openssl (3.5.1-1)" names the source package and, when it
        # differs, its version. Only the name is used, for the severity lookup
        # (#44), which the security tracker files by source package.
        my $source = $name;
        if (defined($s->{Source}) && $s->{Source} =~ m/\A([a-z0-9][a-z0-9+.-]+)(?: \([^)]*\))?\z/) {
            $source = $1;
        }

        push @res, { name => $name, arch => $arch, version => $version, source => $source };
    }

    return (\@res, $skipped);
}

# ── the security side ───────────────────────────────────────────────────────

# How large a security Packages index may be. Not the limit for a guest's
# status file: an index has passed apt's hash check against an InRelease the
# distribution signed, and its size is the distribution's. Measured from the
# InRelease files of 2026-10-23 (#62): jammy-security main 20 698 557 bytes,
# restricted 37 850 959; focal-security main 20 100 998. The status-file limit
# of 16 MiB used here before dropped jammy's and focal's main without a word.
# Reading both jammy files took 9.5 s and 153 MB peak with Dpkg::Version.
our $MAX_INDEX = 128 * 1024 * 1024;

# Adds the packages of one security Packages index to $index:
# "name:arch" => highest version listed. Several indices (main, contrib,
# non-free, two releases) go into one hash by calling this once per file.
sub add_index {
    my ($index, $text) = @_;

    my $added = 0;
    for my $s (@{ parse_stanzas($text, [qw(Package Architecture Version)]) }) {
        my ($name, $arch, $version) = @{$s}{qw(Package Architecture Version)};
        next if !valid_name($name) || !valid_arch($arch) || !valid_version($version);

        my $key = "$name:$arch";
        my $have = $index->{$key};
        if (!defined($have) || version_compare($version, $have) > 0) {
            $index->{$key} = $version;
            $added++;
        }
    }

    return $added;
}

# ── leaving packages out ────────────────────────────────────────────────────
#
# security_exclude: shell-style patterns, * and ? only, separated by commas or
# spaces - "linux-image-*, firmware-*". Anything else in a pattern is refused
# rather than passed to a regex, because a setting is not a place for one.
sub parse_exclude {
    my ($spec) = @_;

    my @res;
    for my $pat (grep { length } split(/[\s,]+/, $spec // '')) {
        die "invalid package pattern '$pat' - letters, digits, + . - * ? only\n"
            if $pat !~ m/\A[a-z0-9+.*?-]{1,128}\z/;
        my $re = join('', map { $_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta($_) } split(//, $pat));
        push @res, qr/\A$re\z/;
    }

    return \@res;
}

# ── the comparison ──────────────────────────────────────────────────────────

# Every installed package for which the index has a higher version, as
# { name, arch, source, installed, fixed }, sorted by name. An Architecture:
# all package is looked up under "all" as well as under the target's own
# architecture, because an index lists it once as "all" and dpkg records it
# that way too - but a package dpkg calls amd64 is never compared with an i386
# build of the same name.
sub pending {
    my ($installed, $index, $exclude) = @_;

    my @res;
    for my $p (@$installed) {
        next if grep { $p->{name} =~ $_ } @{ $exclude // [] };

        my $fixed = $index->{"$p->{name}:$p->{arch}"};
        $fixed //= $index->{"$p->{name}:all"} if $p->{arch} ne 'all';
        next if !defined($fixed);
        next if version_compare($fixed, $p->{version}) <= 0;

        push @res, { %$p, installed => $p->{version}, fixed => $fixed };
        delete $res[-1]->{version};
    }

    return [sort { $a->{name} cmp $b->{name} || $a->{arch} cmp $b->{arch} } @res];
}

1;
