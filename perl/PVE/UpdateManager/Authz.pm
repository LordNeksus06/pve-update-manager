package PVE::UpdateManager::Authz;

# Who may make the addon run what (#63, #64, #65).
#
# Decided by the owner on 2026-10-23, and modelled on what PVE itself asks for
# the same actions, read on PVE 9.2.4:
#
# - A root shell on the host: PVE gives it to root@pam alone (API2/Nodes.pm,
#   termproxy and vncshell: "user != root@pam"; an API token of root@pam fails
#   verify_username there). The host's update script is that shell, so the
#   same rule - before, Sys.Modify plus Sys.Console was enough, which the
#   built-in Administrator role holds without being root (#63).
# - Snapshot create and delete: VM.Snapshot. Rollback: VM.Snapshot or
#   VM.Snapshot.Rollback. Start, stop, shutdown, reboot: VM.PowerMgmt
#   (API2/LXC/Snapshot.pm, LXC/Status.pm, Qemu.pm). A run does those things
#   when the node's settings say so; before, VM.Console was all it asked (#64).
# - A schedule and the immediate updates run unattended, as root@pam. Whoever
#   sets them up must hold what a run of each covered target needs; before,
#   Sys.Console on the node let anyone schedule any guest (#65).
#
# Checked in the code, not only declared on the endpoints: a declared check
# names one path, and these depend on the settings and on lists of guests.

use strict;
use warnings;

use PVE::Exception qw(raise_perm_exc);

our $ROOT = 'root@pam';

sub check_root {
    my ($user, $what) = @_;

    return if defined($user) && $user eq $ROOT;
    raise_perm_exc("$what runs commands as root on the node - only $ROOT may do that");
}

# What a run of a guest needs on /vms/<vmid> with these settings, as
# [privileges, any-of] pairs. $immediate: an immediate update after a security
# check, which can also restart the guest (security_reboot).
sub guest_run_privs {
    my ($s, $immediate) = @_;

    my @need = ([['VM.Console'], 0]);
    push @need, [['VM.Snapshot'], 0]
        if $s->{snapshot_before} || ($s->{rollback_on_failure} && $s->{rollback_remove_newer});
    push @need, [['VM.Snapshot', 'VM.Snapshot.Rollback'], 1] if $s->{rollback_on_failure};
    push @need, [['VM.PowerMgmt'], 0]
        if $s->{start_stopped} || $s->{reboot_vms}
        || ($s->{snapshot_before} && $s->{snapshot_shutdown})
        || ($immediate && $s->{security_reboot});

    return \@need;
}

sub check_guest_run {
    my ($rpcenv, $user, $path, $settings, $immediate) = @_;

    for my $n (@{ guest_run_privs($settings, $immediate) }) {
        my ($privs, $any) = @$n;
        if ($any) {
            $rpcenv->check_any($user, $path, $privs);
        } else {
            $rpcenv->check($user, $path, $privs);
        }
    }
    return;
}

sub _ids { return grep { length } split(/,/, $_[0] // '') }

# A save of a node's settings: if it changes anything, its author must hold
# what the node will then run unattended - checked on the settings as they
# will be after the save, so adding a guest to a list, or switching on a
# snapshot for listed guests, is checked like setting the list up.
#
# A save that changes nothing is not checked. One that changes something
# unrelated is: the settings decide together what an unattended run does, and
# a rule that guessed which keys matter would be one more list to keep right.
sub check_settings_save {
    my ($rpcenv, $user, $current, $param) = @_;

    my $changed = grep {
        defined($param->{$_}) && ($param->{$_} // '') ne ($current->{$_} // '')
    } keys %$param;
    return if !$changed;

    my $s = { %$current, map { $_ => $param->{$_} } grep { defined($param->{$_}) } keys %$param };

    if ($s->{schedule_enabled}) {
        check_root($user, 'a scheduled run of the host script') if $s->{schedule_host};
        check_guest_run($rpcenv, $user, "/vms/$_", $s, 0) for _ids($s->{schedule_vmids});
    }

    if ($s->{security_install}) {
        my @ids = _ids($s->{security_install_vmids});
        if (@ids) {
            check_guest_run($rpcenv, $user, "/vms/$_", $s, 1) for @ids;
        } else {
            # An empty list is every target with pending updates - the host
            # among them, in mode 'security' even without a host script (#75),
            # and guests that do not exist yet: the path for all of them.
            check_root($user, 'an immediate update of every target');
            check_guest_run($rpcenv, $user, '/vms', $s, 1);
        }
    }

    return;
}

1;
