package PVE::UpdateManager::SecSummary;

# The security scan's summary per node in /etc/pve (#40): what the datacenter
# tab of every node shows for every node's targets.
#
# Out of SecScan.pm, which went past 500 lines with it in.

use strict;
use warnings;

use JSON::PP ();

use PVE::Tools;

use PVE::UpdateManager::Config;

# The per-node summary in /etc/pve, which the datacenter tab of every node can
# read. Beside the node's settings file, named like it.
sub file {
    my ($node) = @_;

    my $file = PVE::UpdateManager::Config::script_file('node', $node);
    $file =~ s{/node-([^/]+)\.conf\z}{/security-$1.json};

    return $file;
}

sub load {
    my ($node) = @_;

    # Read here rather than through SecScan: the API loads this module on its
    # own, and must never pull in the scan's machinery to show a number.
    my $raw = eval { PVE::Tools::file_get_contents(file($node), 1024 * 1024) } // return {};
    my $data = eval { JSON::PP->new->utf8->decode($raw) };

    return ref($data) eq 'HASH' ? $data : {};
}

# ── the summary every node can read ─────────────────────────────────────────
#
# One file per node in /etc/pve: status, count and the first few package
# names per target. Written only when it changed - ten thousand targets every
# 30 minutes would otherwise be a cluster-wide write for nothing - and kept
# well under pmxcfs' 1 MiB per file by dropping the names first when it grows.
our $SUMMARY_NAMES = 5;
our $SUMMARY_MAX = 900 * 1024;

sub entry {
    my ($r) = @_;

    my @names = map { $_->{name} } @{ $r->{pending} // [] };

    return {
        status => $r->{status} // 'unknown',
        count => scalar(@names),
        packages => [@names[0 .. ($#names < $SUMMARY_NAMES - 1 ? $#names : $SUMMARY_NAMES - 1)]],
        (defined($r->{reason}) ? (reason => substr($r->{reason}, 0, 200)) : ()),
        # Kept when the summary has to shrink: it is the one line that says
        # the count cannot be acted on (#53).
        (defined($r->{warning}) ? (warning => substr($r->{warning}, 0, 300)) : ()),
        ($r->{busy} ? (busy => 1) : ()),
        checked => $r->{checked} // 0,
    };
}

sub write {
    my ($node, $results) = @_;

    my %targets = map {; "$_->{type}-$_->{id}" => entry($_) } @$results;

    return _store($node, \%targets);
}

# One target's entry, rewritten outside a round: by a run that installed what
# the entry listed (#76). The UI's counts come from this file, not from the
# results - correcting only the result left the row at 113 while the result
# said 109. A target the summary does not have stays out: the next round adds
# it with everything else.
sub update_one {
    my ($node, $t, $result) = @_;

    my $key = "$t->{type}-$t->{id}";
    my %targets = %{ load($node)->{targets} // {} };
    return 0 if !$targets{$key};
    $targets{$key} = entry($result);

    return _store($node, \%targets);
}

sub _store {
    my ($node, $targets) = @_;

    my %targets = %$targets;
    my $json = JSON::PP->new->utf8->canonical;

    my $data = { targets => \%targets };
    if (length($json->encode($data)) > $SUMMARY_MAX) {
        $_->{packages} = [] for values %targets;
        delete $_->{reason} for values %targets;
    }

    # Compared without the per-target times, which move every round.
    my $strip = sub {
        my ($d) = @_;
        return $json->encode({ map { $_ => { %{ $d->{targets}->{$_} }, checked => 0 } }
            keys %{ $d->{targets} // {} } });
    };
    my $old = load($node);
    return 0 if $strip->($old) eq $strip->($data);

    PVE::UpdateManager::Config::_ensure_base_dir();
    PVE::Tools::file_set_contents(file($node), $json->encode($data));

    return 1;
}

# ── what a row of the target list carries ───────────────────────────────────
#
# One schema and one function for the node tab and the datacenter tab, so the
# two grids cannot disagree about what a column means.
sub row_schema {
    return {
        security_status => {
            type => 'string', optional => 1,
            description => "Result of the last security check: ok, timeout, stopped, no-agent,"
                . " unsupported, no-security-source, source-unreachable or error.",
        },
        security_count => {
            type => 'integer', optional => 1,
            description => "Installed packages with a pending security update.",
        },
        security_packages => {
            type => 'string', optional => 1,
            description => "The first of them, comma separated.",
        },
        security_reason => { type => 'string', optional => 1, description => "Why there is no count." },
        security_warning => {
            type => 'string', optional => 1,
            description => "Why the pending updates cannot be installed as configured, e.g. a source"
                . " whose package files answer 404.",
        },
        security_busy => { type => 'boolean', optional => 1, description => "Was updating during the check." },
        # Not the time of the last check: the summary is only rewritten when
        # it changed (see write), so this is when this answer was first seen.
        security_checked => {
            type => 'integer', optional => 1,
            description => "Since when this result stands (epoch) - the first check that gave it.",
        },
    };
}

sub row_fields {
    my ($summary, $type, $id) = @_;

    my $e = (($summary // {})->{targets} // {})->{"$type-$id"} // return {};

    return {
        security_status => $e->{status} // 'unknown',
        security_count => int($e->{count} // 0),
        security_packages => join(',', @{ $e->{packages} // [] }),
        (defined($e->{reason}) ? (security_reason => $e->{reason}) : ()),
        (defined($e->{warning}) ? (security_warning => $e->{warning}) : ()),
        ($e->{busy} ? (security_busy => 1) : ()),
        security_checked => int($e->{checked} // 0),
    };
}

1;
