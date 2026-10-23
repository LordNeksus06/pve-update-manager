package PVE::UpdateManager::QemuPower;

# Switching a VM on, off and through a reboot around its update - the VM half of
# start_lxc, wait_online and shutdown_lxc in PVE::UpdateManager::Runner.
#
# A module of its own rather than more of QemuRunner.pm: that one carries a
# script through the guest agent and is long enough as it is; this one is about
# the machine around the script. What they share - the agent call and its error
# handling - is called from there, not copied.
#
# What PVE does, read off pve-manager 9.2.4:
#
# - `qm shutdown` asks the guest agent to shut the guest down when the agent is
#   enabled in the VM's options, ACPI otherwise, and gives up after --timeout
#   leaving the VM running. So a hard `qm stop` stays behind it, exactly as for
#   containers: a VM left running that was found stopped is the worse outcome.
# - `qm reboot` is vm_reboot: it writes a reboot request, shuts the VM down and
#   returns once it is down; qmeventd then starts it again on its own. So the
#   command returning says nothing about the VM being back - the agent answering
#   again is what does.
# - Both refuse while the VM carries a lock (check_lock), the update's own
#   'backup' lock included - so the caller gives that back first.

use strict;
use warnings;

use Time::HiRes ();

use PVE::UpdateManager::QemuRunner;
use PVE::UpdateManager::Runner;

our $QM = '/usr/sbin/qm';

our $START_TIMEOUT = 180;      # how long `qm start` itself may take
our $SHUTDOWN_TIMEOUT = 120;   # how long a graceful shutdown may take

# How long a booting VM gets until its guest agent answers. Longer than a
# container's wait for a default route: a VM boots a kernel, runs its initrd and
# fsck, and the agent is one of the last units systemd starts. Measured on the
# lab host (Ubuntu 24.04 cloud image, 2 vCPUs, cloud-init on every boot), from
# `qm start` to the first answered guest-ping: 54 s, 174 s, about 180 s in a full
# run, and over 300 s in the run that started the VM again after a cold snapshot
# (328 s for the whole target, the update itself a single echo). 300 s, the first
# value here, would have failed that run - and a VM that misses the wait is shut
# down again and reported failed, so the cost of a short wait is a false red.
our $AGENT_WAIT = 600;

# How often the agent is asked while waiting.
our $AGENT_POLL = 3;

# What switching one VM off and on again can cost on top of the limit that
# bounds its script - the VM counterpart of Runner::PER_TARGET_GRACE, plus one
# reboot: two shutdowns at worst (the graceful one and the hard stop behind it),
# a start, the wait for the agent, and a reboot with its own shutdown and wait.
our $PER_TARGET_GRACE =
    2 * ($SHUTDOWN_TIMEOUT + 30) + $START_TIMEOUT + $AGENT_WAIT
    + ($SHUTDOWN_TIMEOUT + 30) + $AGENT_WAIT;

# The file Debian and Ubuntu write when an installed package wants a reboot -
# a new kernel, a new libc. The owner's decision names exactly this one.
our $REBOOT_FLAG = '/var/run/reboot-required';

# $skiplock is for the one caller that holds the update's own lock while it
# starts the VM: a stopped VM started for its update. `qm start` refuses while
# ANY lock is set - measured on the lab host: "VM is locked (backup)", and the
# run failed with "could not be started for the update" (vm_start calls
# check_lock unless skiplock is given). A container's start does not do that
# with its 'mounted' lock, which is why the container path never needed this.
#
# Skipping the check skips it for every lock, so it is only passed where the
# lock on the VM is known to be ours: set_lock refused before if somebody else
# held one. Starting first and locking afterwards was the alternative, and it
# leaves a window in which a backup can take the VM between the boot and the
# update. --skiplock is root-only, and the worker runs as root.
sub start_vm {
    my ($vmid, $logfunc, $skiplock) = @_;

    my $safe = PVE::UpdateManager::Runner::_safe_vmid($vmid);

    my @cmd = ($QM, 'start', $safe);
    push @cmd, '--skiplock', '1' if $skiplock;

    return PVE::UpdateManager::Runner::_run(\@cmd, $START_TIMEOUT, $logfunc);
}

# Graceful first, for the reason shutdown_lxc gives: the update just rewrote
# half the packages, and a hard stop is a power cut.
sub shutdown_vm {
    my ($vmid, $logfunc) = @_;

    my $safe = PVE::UpdateManager::Runner::_safe_vmid($vmid);

    my $rc = PVE::UpdateManager::Runner::_run(
        [$QM, 'shutdown', $safe, '--timeout', $SHUTDOWN_TIMEOUT],
        $SHUTDOWN_TIMEOUT + 30,
        $logfunc,
    );
    return $rc if defined($rc) && $rc == 0;

    $logfunc->('graceful shutdown did not finish, stopping the VM');

    return PVE::UpdateManager::Runner::_run([$QM, 'stop', $safe], 60, $logfunc);
}

# True once the guest agent answers, false if it never does within $seconds.
#
# The agent and not "the VM process exists": a VM is running long before
# anything inside it can be reached, and the update goes through the agent.
sub wait_agent {
    my ($vmid, $seconds) = @_;

    my $deadline = time() + ($seconds // $AGENT_WAIT);

    while (1) {
        return 1 if PVE::UpdateManager::QemuRunner::agent_running($vmid);
        return 0 if time() >= $deadline;
        Time::HiRes::sleep($AGENT_POLL);
    }
}

# Does the guest say it wants a reboot? 1 yes, 0 no, undef when it could not be
# asked - which the caller treats as "no", because rebooting a VM on a guess is
# the one thing this setting must not do.
#
# `test -e` through guest-exec rather than guest-file-open: an open of a file
# that is not there comes back as an agent error that cannot be told apart from
# an agent that failed, and the exit code of `test` can.
sub reboot_required {
    my ($vmid) = @_;

    my $res = eval {
        my $pid = int(PVE::UpdateManager::QemuRunner::_agent(
            $vmid, 'guest-exec', path => '/bin/sh', arg => ['-c', "test -e $REBOOT_FLAG"],
        )->{pid});

        my $status = {};
        for (1 .. $PVE::UpdateManager::QemuRunner::RM_TRIES) {
            $status = PVE::UpdateManager::QemuRunner::_agent($vmid, 'guest-exec-status', pid => $pid);
            last if $status->{exited};
            Time::HiRes::sleep($PVE::UpdateManager::QemuRunner::RM_WAIT);
        }

        die "no answer\n" if !$status->{exited} || defined($status->{signal});

        ($status->{exitcode} // 1) == 0 ? 1 : 0;
    };

    return $@ ? undef : $res;
}

# Reboots the VM and waits for its agent. Returns 0 when the VM is back and
# answering, non-zero otherwise - the reason is in the log.
sub reboot_vm {
    my ($vmid, $logfunc) = @_;

    my $safe = PVE::UpdateManager::Runner::_safe_vmid($vmid);

    my $rc = PVE::UpdateManager::Runner::_run(
        [$QM, 'reboot', $safe, '--timeout', $SHUTDOWN_TIMEOUT],
        $SHUTDOWN_TIMEOUT + 30,
        $logfunc,
    );
    if (!defined($rc) || $rc != 0) {
        $logfunc->('WARNING: the reboot did not go through');
        return defined($rc) && $rc != 0 ? $rc : -1;
    }

    return 0 if wait_agent($safe);

    $logfunc->("WARNING: the guest agent did not answer within ${AGENT_WAIT}s of the reboot");

    return -1;
}

1;
