package PVE::UpdateManager::SecSettings;

# The settings of the security scan (#35, #41): defaults, API schema, reading
# a stored value and validating a save.
#
# Its own module rather than seventeen more entries in Settings.pm, which was
# already 511 lines. Settings.pm merges what is here into the one settings
# file and the one schema, so the API, the file format and the datacenter-wide
# save see no difference between these keys and the older ones.
#
# Every default below was confirmed by the owner on 2026-10-22, except where a
# comment says "assumed".

use strict;
use warnings;

use PVE::UpdateManager::SecCompare;

our $MIN_INTERVAL = 5;        # minutes - the timer ticks every 5 (pve-update-manager.timer)
our $MAX_INTERVAL = 10080;    # a week
our $MAX_PARALLEL = 64;
our $MAX_GAP = 1440;
our $MAX_COOLDOWN = 10080;    # a week

our @SEVERITIES = ('', 'low', 'medium', 'high');

sub defaults {
    return {
        security_scan => 0,
        security_interval => 30,
        # Assumed (#41): the example in the question that made it a setting.
        security_parallel => 4,
        security_targets => 'all',
        security_source => 'configured',
        security_exclude => '',
        security_min_severity => '',
        security_notify => 1,
        security_notify_once => 1,
        # #73, owner 2026-10-23: "nachricht max alle 5h", per node.
        security_unfixed_cooldown => 300,
        security_install => 0,
        security_install_mode => 'script',
        security_install_vmids => '',
        security_install_window => '',
        security_install_gap => 60,
        # Assumed (#43): one at a time, like the two older parallel switches,
        # which both start off.
        security_install_parallel_max => 1,
        security_reboot => 0,
    };
}

# The vmid list names containers of ONE node, like schedule_vmids - a
# datacenter-wide save must not broadcast it.
our @PER_NODE = qw(security_install_vmids);

sub schema {
    return {
        security_scan => {
            type => 'boolean',
            description => "Check the targets for pending security updates in the background."
                . " Off by default. Nothing is installed by the check itself; it reads each"
                . " target's package list from the node and compares it with the security"
                . " suite of the sources the target has configured.",
        },
        security_interval => {
            type => 'integer',
            minimum => $MIN_INTERVAL,
            maximum => $MAX_INTERVAL,
            description => "Minutes between two checks. The timer ticks every 5 minutes, so"
                . " this takes effect in steps of 5.",
        },
        security_parallel => {
            type => 'integer',
            minimum => 1,
            maximum => $MAX_PARALLEL,
            description => "How many targets one check reads at the same time. This is not"
                . " the number of updates - see security_install_parallel_max.",
        },
        security_targets => {
            type => 'string',
            enum => ['all', 'script'],
            description => "Check every guest ('all') or only those with an update script.",
        },
        security_source => {
            type => 'string',
            enum => ['configured', 'debian'],
            description => "Fetch the security lists from the sources each target has"
                . " configured, with its proxy ('configured'), or from Debian directly.",
        },
        security_exclude => {
            type => 'string',
            maxLength => 1024,
            # The empty string has to pass: it is "exclude nothing".
            pattern => '[a-z0-9+.*?,\s-]*',
            description => "Package patterns that are never counted, separated by commas,"
                . " e.g. 'linux-image-*'. * and ? only.",
        },
        security_min_severity => {
            type => 'string',
            enum => [@SEVERITIES],
            description => "React only to updates of at least this severity. Empty = all."
                . " An update Debian has not rated yet counts as reaching any threshold:"
                . " most fixes are never rated, and dropping them would drop nearly all.",
        },
        security_notify => {
            type => 'boolean',
            description => "Send a notification when a check finds pending security updates.",
        },
        security_notify_once => {
            type => 'boolean',
            description => "Notify about a package on a target once, not on every check.",
        },
        security_unfixed_cooldown => {
            type => 'integer',
            minimum => 0,
            maximum => $MAX_COOLDOWN,
            description => "Minutes between two notifications, per node, that a run left security"
                . " updates it should have installed not installed (NOT FIXED). 0 notifies every time.",
        },
        security_install => {
            type => 'boolean',
            description => "Start an update of a target as soon as a check finds a pending"
                . " security update. Off by default. It is a normal run - snapshot,"
                . " rollback and log as usual.",
        },
        security_install_mode => {
            type => 'string',
            enum => ['script', 'security'],
            description => "What such a run executes: the target's update script, or only"
                . " an upgrade of the affected packages from the target's own sources.",
        },
        security_install_vmids => {
            type => 'string',
            pattern => '(\d+(,\d+)*)?',
            maxLength => 4096,
            description => "Only these guests are updated immediately. Empty = every"
                . " target with pending updates - in mode 'script' only those with an update"
                . " script, in mode 'security' every guest and the host.",
        },
        security_install_window => {
            type => 'string',
            pattern => '(([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d)?',
            description => "Start immediate updates only within this daily window, e.g."
                . " 06:00-22:00 (may cross midnight). Empty = any time.",
        },
        security_install_gap => {
            type => 'integer',
            minimum => 0,
            maximum => $MAX_GAP,
            description => "No immediate update when the scheduled run is due within this"
                . " many minutes - the scheduled run picks it up.",
        },
        security_install_parallel_max => {
            type => 'integer',
            minimum => 1,
            maximum => $MAX_PARALLEL,
            description => "How many immediate updates may run at the same time.",
        },
        security_reboot => {
            type => 'boolean',
            description => "After an immediate update, restart a guest that left"
                . " /var/run/reboot-required behind.",
        },
    };
}

sub handles {
    my ($key) = @_;

    return exists(defaults()->{$key}) ? 1 : 0;
}

# ── one stored value, read back ─────────────────────────────────────────────
#
# Never dies and never refuses: a value that does not fit falls back to the
# default or is clamped, as the older keys do in Settings::load_settings - a
# settings file edited by hand into nonsense must not switch the check off,
# or on.
sub load_value {
    my ($key, $value) = @_;

    my $def = defaults()->{$key};
    my $s = schema()->{$key};
    $value //= '';

    if ($s->{type} eq 'boolean') {
        return $value =~ m/\A[01]\z/ ? int($value) : $def;
    }

    if ($s->{type} eq 'integer') {
        return $def if $value !~ m/\A\d{1,9}\z/;
        my $n = int($value);
        $n = $s->{minimum} if $n < $s->{minimum};
        $n = $s->{maximum} if $n > $s->{maximum};
        return $n;
    }

    if ($s->{enum}) {
        return (grep { $_ eq $value } @{ $s->{enum} }) ? $value : $def;
    }

    return valid_string($key, $value) ? $value : $def;
}

sub valid_string {
    my ($key, $value) = @_;

    return 0 if !defined($value);

    if ($key eq 'security_exclude') {
        return 0 if length($value) > 1024;
        return defined(eval { PVE::UpdateManager::SecCompare::parse_exclude($value) }) ? 1 : 0;
    }
    if ($key eq 'security_install_vmids') {
        return $value eq '' || $value =~ m/\A\d+(?:,\d+)*\z/ ? 1 : 0;
    }
    if ($key eq 'security_install_window') {
        return defined(parse_window($value)) ? 1 : 0;
    }

    return 0;
}

# ── a save ──────────────────────────────────────────────────────────────────
#
# Dies with a sentence naming the key, like the checks in save_settings.
sub validate {
    my ($merged) = @_;

    my $schema = schema();
    for my $key (sort keys %$schema) {
        my $s = $schema->{$key};
        my $v = $merged->{$key};

        die "missing $key\n" if !defined($v);

        if ($s->{type} eq 'boolean') {
            die "invalid $key '$v' - must be 0 or 1\n" if $v !~ m/\A[01]\z/;
        } elsif ($s->{type} eq 'integer') {
            die "invalid $key '$v' - must be between $s->{minimum} and $s->{maximum}\n"
                if $v !~ m/\A\d{1,9}\z/ || $v < $s->{minimum} || $v > $s->{maximum};
        } elsif ($s->{enum}) {
            die "invalid $key '$v' - must be one of " . join(', ', map { "'$_'" } @{ $s->{enum} }) . "\n"
                if !grep { $_ eq $v } @{ $s->{enum} };
        } elsif (!valid_string($key, $v)) {
            die "invalid $key '$v'\n";
        }
    }

    return 1;
}

# ── the install window ──────────────────────────────────────────────────────

# '' → [] (any time); 'HH:MM-HH:MM' → [from, to] in minutes of the day;
# anything else → undef.
sub parse_window {
    my ($spec) = @_;

    return undef if !defined($spec);
    return [] if $spec eq '';

    my ($fh, $fm, $th, $tm) =
        $spec =~ m/\A([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)\z/
        or return undef;

    my ($from, $to) = ($fh * 60 + $fm, $th * 60 + $tm);

    # A window of no length is either "never" or "always", and neither is what
    # somebody typing it means. Refused rather than guessed.
    return undef if $from == $to;

    return [$from, $to];
}

# Is $epoch inside the window? Local time, like the schedule. A window that
# crosses midnight (22:00-06:00) is the two pieces around it.
sub in_window {
    my ($spec, $epoch) = @_;

    my $w = parse_window($spec) // return 0;
    return 1 if !scalar(@$w);

    my @t = localtime($epoch // time());
    my $now = $t[2] * 60 + $t[1];
    my ($from, $to) = @$w;

    return $from < $to
        ? ($now >= $from && $now < $to ? 1 : 0)
        : ($now >= $from || $now < $to ? 1 : 0);
}

1;
