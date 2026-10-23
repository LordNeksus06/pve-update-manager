package PVE::UpdateManager::QemuScripts;

# The two shell parts a VM run starts inside the guest (QemuRunner::run_vm).
# Out of QemuRunner.pm, which went past 500 lines with the private run
# directory of #72; QemuRunner keeps $VM_OUTER and $VM_INNER under its own
# names for its callers and tests.

use strict;
use warnings;

# The guest half, in two parts. The OUTER part is what guest-exec starts: it
# opens the log - with umask 077, because an update log can carry what a script
# echoes and /var/tmp is world-readable - and hands over to the inner part in a
# scope of its own. The INNER part travels as an argument rather than as a file:
# nothing has to be written into the VM before the run can start.
#
# Both files live in a 0700 directory under a random name (#72). Directly in
# /var/tmp, any VM user could plant the exit code the host trusts after an
# agent restart (measured: exit 1 reported as "OK (exit 0)"). A taken name: 125.
our $VM_OUTER = <<'EOS';
dir=$1
log=$2
inner=$3
shift 3
umask 077
mkdir -m 700 -- "$dir" || exit 125
exec >"$log" 2>&1
if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    exec systemd-run --scope --quiet --collect -- /bin/sh -c "$inner" pve-update-manager "$@"
fi
echo "WARNING: no systemd in this VM - if the update restarts qemu-guest-agent, as an upgrade of that package does, the update is killed with it"
exec /bin/sh -c "$inner" pve-update-manager "$@"
EOS

# The time limit is enforced in here, by coreutils `timeout` in its own process
# group, for the same reason as in a container: the host cannot kill a process
# inside a VM, it can only stop waiting for it.
#
# The exit code goes into its own file, renamed into place so the host never
# reads half of it. That file is how the end of a run is noticed after the agent
# was restarted and has forgotten the pid.
#
# Unlike the container prologue there is no raw-script fallback for a guest
# without base64: the raw script is exactly what must not cross the agent.
our $VM_INNER = <<'EOS';
rcf=$1
secs=$2
grace=$3
b64=$4
shift 4
if script=$(printf %s "$b64" | base64 -d 2>/dev/null) && [ -n "$script" ]; then
    HOME=/root
    USER=root
    LOGNAME=root
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME USER LOGNAME PATH
    if timeout -k 1 1 true 2>/dev/null; then
        timeout -k "$grace" "$secs" "$@" -c "$script"
    else
        echo "WARNING: no usable 'timeout' in this VM - a run that exceeds ${secs}s will be abandoned, not killed"
        "$@" -c "$script"
    fi
    rc=$?
else
    echo "ERROR: no usable 'base64' in this VM - the update script cannot be passed in"
    rc=127
fi
echo "$rc" >"$rcf.tmp" && mv -f "$rcf.tmp" "$rcf"
exit "$rc"
EOS

1;
