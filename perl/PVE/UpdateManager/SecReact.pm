package PVE::UpdateManager::SecReact;

# What happens around a security check round: the worker task it runs in, the
# notification about what it found (#42) and the immediate update it may start
# (#43).
#
# Everything here runs in a background worker task - started by the timer or
# by "Check now" - and never in an API call (#35: nothing may block, a hang
# may not take the web UI down).

use strict;
use warnings;

use JSON::PP ();
use POSIX ();

use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::Tools;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::SecCompare;
use PVE::UpdateManager::SecScan;
use PVE::UpdateManager::SecSettings;
use PVE::UpdateManager::Settings;

our $TEMPLATE = 'pve-update-manager-security';
our $UNFIXED_TEMPLATE = 'pve-update-manager-security-unfixed';
our $TYPE = 'pve-update-manager';

# Hooks for the tests: sending a notification, starting the update task, the
# clock of the NOT FIXED cooldown.
our $SEND = \&_send;
our $SEND_UNFIXED = sub { _send($_[0], $_[1], $UNFIXED_TEMPLATE) };
our $START = \&_start;
our $NOW = sub { time() };

sub _log { print "$_[0]\n" }

# ── the worker task ─────────────────────────────────────────────────────────

sub worker {
    my ($node) = @_;

    # Below everything else on the node: a check is never urgent, an update a
    # guest is running, or the web UI, is (#35).
    eval { POSIX::nice(10) };
    eval { PVE::Tools::run_command(['ionice', '-c3', '-p', $$], timeout => 5) };

    my $settings = PVE::UpdateManager::Settings::load_settings($node);
    my $r = PVE::UpdateManager::SecScan::run_round($node, $settings, \&_log);
    if ($r->{busy}) {
        _log('another check is still running - nothing to do');
        return;
    }

    my @found = found($r->{results});
    _log(sprintf('%d target(s) checked in %d s, %d with pending security updates, %d timed out',
        scalar(@{ $r->{results} }), $r->{elapsed} // 0, scalar(@found), $r->{timed_out} // 0));
    for my $t (@found) {
        _log("  $t->{type} $t->{id} ($t->{name}): " . join(', ', map { $_->{name} } @{ $t->{pending} }));
    }

    notify($node, $settings, \@found) if $settings->{security_notify};
    install($node, $settings, \@found) if $settings->{security_install};

    return;
}

# The targets of a round that have something pending. A busy target carries
# its last result, which may be stale - it is being updated right now, so it
# is neither reported again nor updated a second time.
sub found {
    my ($results) = @_;

    return grep {
        ($_->{status} // '') eq 'ok' && !$_->{busy} && scalar(@{ $_->{pending} // [] })
    } @$results;
}

# ── the notification (#42) ──────────────────────────────────────────────────
#
# One per round and node, not one per target: a node with hundreds of guests
# would otherwise send hundreds. With security_notify_once a package of a
# target is reported once per fixed version - a new fix for it is news again,
# the same one every 30 minutes is not.

sub _notified_file { "$PVE::UpdateManager::SecScan::STATE_DIR/notified.json" }

sub notify {
    my ($node, $settings, $found) = @_;

    my $seen = {};
    if ($settings->{security_notify_once}) {
        my $raw = eval { PVE::Tools::file_get_contents(_notified_file(), 4 * 1024 * 1024) };
        $seen = eval { JSON::PP->new->utf8->decode($raw // '') } // {};
        $seen = {} if ref($seen) ne 'HASH';
    }

    my ($data, $now) = report($found, $seen);

    # What is pending now replaces what was: a package that was updated and
    # later needs the same fix again is reported again.
    _write_seen($now) if $settings->{security_notify_once};

    if (!$data) {
        _log('nothing new to notify about');
        return 0;
    }

    return $SEND->($node, $data) ? 1 : 0;
}

# The notification's data for what is new against $seen, and what is pending
# now (for the next round's $seen). No data when nothing is new. Its own
# function so the test suite can hold the templates against what it really
# returns (tests/run-tests.sh, "the notification template and the code agree").
sub report {
    my ($found, $seen) = @_;

    $seen //= {};
    my (@blocks, %now, $packages, $warned);
    for my $t (@$found) {
        my $key = "$t->{type}-$t->{id}";
        my @new;
        for my $p (@{ $t->{pending} }) {
            my $id = "$p->{name}:$p->{arch}=$p->{fixed}";
            $now{$key}->{$id} = 1;
            push @new, $p if !$seen->{$key}->{$id};
        }
        # A source whose package files are gone (#53) is news once, like a
        # package - and again only when the warning itself changes.
        my $warning;
        if (defined($t->{warning})) {
            my $id = "warning=$t->{warning}";
            $now{$key}->{$id} = 1;
            $warning = $t->{warning} if !$seen->{$key}->{$id};
        }
        next if !@new && !defined($warning);
        $packages += scalar(@new);
        $warned++ if defined($warning);
        push @blocks, {
            target => sprintf('%s %s (%s)', PVE::UpdateManager::Guest::label($t->{type}),
                $t->{id}, $t->{name} // $t->{id}),
            count => scalar(@new),
            packages => [map {
                { name => $_->{name}, installed => $_->{installed}, fixed => $_->{fixed},
                  urgency => $_->{urgency} // 'unknown' }
            } @new],
            (defined($warning) ? (warning => "WARNING: $warning") : ()),
        };
    }

    return (undef, \%now) if !@blocks;

    $packages //= 0;
    my $text = sprintf('%d pending security update%s on %d target%s',
        $packages, $packages == 1 ? '' : 's', scalar(@blocks), scalar(@blocks) == 1 ? '' : 's');
    $text .= sprintf('; on %d of them the updates cannot be installed from the configured source', $warned)
        if $warned;

    return ({
        'status-text' => $text,
        targets => \@blocks,
        count => $packages,
    }, \%now);
}

sub _write_seen {
    my ($seen) = @_;

    eval {
        # Which guest has which update pending: root's alone, like the
        # results it is made from (#67).
        PVE::Tools::file_set_contents(_notified_file(), JSON::PP->new->utf8->canonical->encode($seen),
            0600);
    };
    warn "pve-update-manager: cannot remember what was notified: $@" if $@;
}

sub _send {
    my ($node, $data, $template) = @_;

    $template //= $TEMPLATE;

    my $sent = eval {
        require PVE::Notify;
        my $all = PVE::Notify::common_template_data();
        $all->{$_} = $data->{$_} for keys %$data;
        PVE::Notify::warning($template, $all, { type => $TYPE, hostname => $node });
        1;
    };
    if (!$sent) {
        my $err = $@ // 'unknown error';
        chomp($err);
        _log("WARNING: the security notification could not be sent - $err");
        return 0;
    }

    _log("notification sent: $data->{'status-text'}");

    return 1;
}

# ── NOT FIXED (#73) ─────────────────────────────────────────────────────────
#
# A run whose script exited 0 but left security updates that were pending
# before it uninstalled. Sent by the run itself, through the security
# notification, at most once per cooldown per node (owner, 2026-10-23:
# "nachricht max alle 5h", per node) - the immediate update tries again every
# round, and a mail every 30 minutes for the same unfixable package is how a
# notification gets filtered away.

sub _unfixed_file { "$PVE::UpdateManager::SecScan::STATE_DIR/unfixed-notified" }

# The notification's data for the NOT FIXED records of a run.
sub unfixed_report {
    my ($records) = @_;

    my @blocks = map {
        { target => $_->{desc}, packages => ($_->{facts} // {})->{not_fixed} // '' }
    } @$records;
    my $n = scalar(@blocks);

    return {
        'status-text' => sprintf('%d target%s NOT FIXED - security updates pending before the run'
            . ' are still not installed', $n, $n == 1 ? '' : 's'),
        targets => \@blocks,
        count => $n,
    };
}

# 1 when handed to Proxmox, 0 when within the cooldown or not sent.
sub notify_unfixed {
    my ($records, $cooldown_minutes) = @_;

    return 0 if !@{ $records // [] };

    my $now = $NOW->();
    my $raw = eval { PVE::Tools::file_get_contents(_unfixed_file(), 64) } // '';
    my ($last) = $raw =~ m/\A(\d{1,12})\s*\z/;
    my $cooldown = 60 * int($cooldown_minutes // 300);
    return 0 if defined($last) && $cooldown > 0 && $now - $last < $cooldown;

    my $sent = $SEND_UNFIXED->(PVE::INotify::nodename(), unfixed_report($records)) ? 1 : 0;
    if ($sent) {
        eval { PVE::Tools::file_set_contents(_unfixed_file(), "$now\n", 0600) };
        warn "pve-update-manager: cannot remember the NOT FIXED notification: $@" if $@;
    }

    return $sent;
}

# ── the immediate update (#43) ──────────────────────────────────────────────

sub install {
    my ($node, $settings, $found, $now) = @_;

    $now //= time();

    if (!PVE::UpdateManager::SecSettings::in_window($settings->{security_install_window}, $now)) {
        _log("immediate updates: outside the window $settings->{security_install_window} - not now");
        return [];
    }

    # The scheduled run picks it up when it is close (#40, case 3).
    if ($settings->{schedule_enabled}) {
        my $next = PVE::UpdateManager::Settings::next_schedule_run($settings, $settings->{last_run} || $now);
        if (defined($next) && $next - $now < 60 * ($settings->{security_install_gap} // 60)) {
            _log(sprintf('immediate updates: the scheduled run is due in %d min - leaving it to that',
                int(($next - $now) / 60)));
            return [];
        }
    }

    my %only = map { $_ => 1 } grep { length } split(/,/, $settings->{security_install_vmids} // '');
    my $mode = $settings->{security_install_mode} // 'script';

    my @targets;
    for my $t (@$found) {
        my $label = "$t->{type} $t->{id}";

        if (%only) {
            next if $t->{type} eq 'node' || !$only{ $t->{id} };
        }
        # Mode 'security' brings its own commands, so no target needs a stored
        # script for it - a guest (#74) and the host alike (#75, the owner's
        # decision). The host is not let in through a back door by this: it is
        # only covered with an empty security_install_vmids, and saving that
        # takes root@pam already (Authz::check_settings_save, #65).
        if ($mode ne 'security'
            && !PVE::UpdateManager::Config::has_script($t->{type}, $t->{id})) {
            _log("immediate updates: $label has no update script - not updated");
            next;
        }
        # Checked again here, not only at the start of the round: the round
        # can take minutes and an update may have started meanwhile (#40,
        # case 1). The run itself refuses a busy target as well.
        if (PVE::UpdateManager::Config::target_is_running($t->{type}, $t->{id})) {
            _log("immediate updates: $label is updating right now - left alone");
            next;
        }

        my ($type, $id) = _clean_target($t);
        if (!defined($id)) {
            _log("immediate updates: $label is not a valid target - not updated");
            next;
        }
        my $target = { type => $type, id => $id, name => $t->{name} };
        if ($mode eq 'security') {
            # Names only, after SecCompare's check: what reaches this shell line
            # matches [a-z0-9][a-z0-9+.-]+ and nothing else.
            my @names = grep { PVE::UpdateManager::SecCompare::valid_name($_) }
                map { $_->{name} } @{ $t->{pending} };
            next if !@names;
            $target->{script} = "export DEBIAN_FRONTEND=noninteractive\n"
                . "apt-get update\n"
                . "apt-get install -y --only-upgrade -o Dpkg::Options::=--force-confold "
                . join(' ', @names) . "\n";
        }
        push @targets, $target;
    }

    if (!@targets) {
        _log('immediate updates: no target to update');
        return [];
    }

    my $max = $settings->{security_install_parallel_max} // 1;
    my $opts = PVE::UpdateManager::Settings::run_opts($settings, $max > 1 ? 1 : 0, $max);
    $opts->{reboot_vms} = 1 if $settings->{security_reboot};

    _log(sprintf('immediate updates (%s): %s', $mode, join(', ', map { "$_->{type} $_->{id}" } @targets)));
    $START->($node, \@targets, $settings->{timeout}, $opts, $settings->{security_reboot});

    return \@targets;
}

# A result's type and id as captures of the patterns Config::script_file
# accepts. The results come back out of results/<type>-<id>.json, so under -T -
# a check started with "Check now" runs in a worker forked from pvedaemon - they
# are tainted, and these two name the target's state file, its lock and the
# container `pct exec` runs in: every one of those died with "Insecure
# dependency" (#66). script_file's own check says yes or no but hands back the
# tainted original, which is why this is not left to it.
sub _clean_target {
    my ($t) = @_;

    my ($type) = ($t->{type} // '') =~ m/\A(lxc|qemu|node)\z/ or return;
    my ($id) = $type eq 'node'
        ? ($t->{id} // '') =~ m/\A([A-Za-z0-9](?:[A-Za-z0-9\-\.]{0,62}))\z/
        : ($t->{id} // '') =~ m/\A([1-9][0-9]{2,8})\z/;

    return defined($id) ? ($type, $id) : ();
}

# The update is its own task, like any run, so it is in the task list with
# its own log - and this check task ends without waiting for it.
sub _start {
    my ($node, $targets, $timeout, $opts, $reboot) = @_;

    my $rpcenv = PVE::RPCEnvironment::get();
    my $upid = $rpcenv->fork_worker('updatemgr', $node, 'root@pam', sub {
        PVE::UpdateManager::Job::run_all($targets, $timeout, $opts);
        restart_containers($targets) if $reboot;
    }, 1);
    _log("started $upid");

    return $upid;
}

# security_reboot for containers. A container has no kernel of its own, but a
# new libc or systemd only takes effect in processes started afterwards, and
# Debian/Ubuntu say so with /var/run/reboot-required as for a host. VMs are
# rebooted by the run itself (reboot_vms).
sub restart_containers {
    my ($targets) = @_;

    for my $t (grep { $_->{type} eq 'lxc' } @$targets) {
        my $last = PVE::UpdateManager::Config::last_run('lxc', $t->{id});
        # NOT FIXED too (#73): the script ran through, and a new libc it did
        # install takes effect only after the restart all the same.
        next if ($last->{last_state} // '') !~ m/\A(?:ok|not_fixed)\z/;
        next if !PVE::UpdateManager::Guest::is_running('lxc', $t->{id});

        my $wanted = eval {
            PVE::Tools::run_command(['pct', 'exec', $t->{id}, '--', 'test', '-e', '/var/run/reboot-required'],
                timeout => 30, noerr => 1, quiet => 1) == 0;
        };
        next if !$wanted;

        _log("CT $t->{id}: /var/run/reboot-required exists - restarting it");
        eval { PVE::Tools::run_command(['pct', 'reboot', $t->{id}, '--timeout', '120'], timeout => 180) };
        _log("WARNING: CT $t->{id} could not be restarted - $@") if $@;
    }
}

1;
