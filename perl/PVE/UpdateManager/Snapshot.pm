package PVE::UpdateManager::Snapshot;

# The rollback point before an update, for containers and VMs alike: taking it,
# rolling back to it, clearing what blocks that rollback, and pruning the old
# ones - including undoing what a snapshot removal that failed halfway leaves
# behind.
#
# Split out of Runner.pm (#21), which had grown past the 1000-line ceiling with
# this section as its largest part. Runner keeps running scripts and switching
# containers on and off; nothing here runs a script.

use strict;
use warnings;

use PVE::LXC::Config;
use PVE::QemuConfig;
use PVE::Storage;

use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Runner;

# ── A rollback point before the update ──────────────────────────────────────
#
# A dist-upgrade is the operation people most want to be able to undo, and on a
# storage that can snapshot, undoing it costs a second. So this is on by
# default - but only where the storage really can, which is not a question about
# ZFS: LVM-thin, RBD and btrfs snapshot too, and a container on a directory
# storage cannot however the node is set up. PVE already knows the answer per
# container, and asking it is better than keeping our own list of storage types
# that would be wrong the first time a plugin gains the feature.

our $SNAPSHOT_PREFIX = 'updmgr';

# The config class that owns a guest's snapshots: PVE::LXC::Config or
# PVE::QemuConfig. Both inherit snapshot_create, snapshot_rollback,
# snapshot_delete, has_feature, foreach_volume, set_lock and remove_lock from
# PVE::AbstractConfig with the same signatures (read off pve-manager 9.2.4), which
# is what lets every function in this section serve both kinds. What does differ
# is spelled out where it matters: the key a disk keeps its volume under (see
# _snapshot_volid) and the memory a VM snapshot could carry, which this addon
# never asks for - a VM is snapshotted disk-only, the owner's decision.
#
# Derived from the vmid rather than passed in by every caller: a vmid is unique
# across both kinds, and a vmid that is neither here stays a container, which is
# what every function below assumed before VMs were targets.
sub _snap_class {
    my ($vmid) = @_;

    return (PVE::UpdateManager::Guest::type_of($vmid) // 'lxc') eq 'qemu'
        ? 'PVE::QemuConfig'
        : 'PVE::LXC::Config';
}

# "CT 101" / "VM 200", for the lines below that name the guest.
sub _who {
    my ($vmid) = @_;

    return PVE::UpdateManager::Guest::label(PVE::UpdateManager::Guest::type_of($vmid) // 'lxc')
        . " $vmid";
}

# The storage volume behind one disk of a guest config, or undef where there is
# no storage to ask. A container's mountpoint says so by type - bind mounts and
# passed-through devices are not 'volume', the same test PVE's own
# __snapshot_activate_storages makes. A VM's drive keeps its volume under 'file'
# (QemuConfig->volid_key), and a CD-ROM is skipped exactly as QemuConfig's own
# has_feature skips it: an ISO is never snapshotted with the VM.
sub _snapshot_volid {
    my ($class, $volume) = @_;

    if ($class eq 'PVE::QemuConfig') {
        return undef if ($volume->{media} // '') eq 'cdrom';
        my $volid = $volume->{file};
        # 'none', or a path to a device on the host: no storage plugin to ask.
        return undef if !defined($volid) || $volid !~ m/\A[^\/:\s]+:/;
        return $volid;
    }

    return undef if ($volume->{type} // '') ne 'volume';

    return $volume->{volume};
}

# The name has to satisfy PVE's pve-configid format - a letter first, then
# letters, digits, underscores and dashes, at most 40 characters - which
# `updmgr-20260819-031500` does at 22.
#
# Local time, because this name is what an operator reads in the snapshot list
# and a UTC timestamp there is a puzzle. It is deliberately NOT what the pruning
# below sorts on: an hour repeats itself once a year and a name that sorts
# wrongly would delete the wrong snapshot.
sub snapshot_name {
    my ($when) = @_;

    my @t = localtime($when // time());

    return sprintf(
        '%s-%04d%02d%02d-%02d%02d%02d',
        $SNAPSHOT_PREFIX, $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0],
    );
}

# Ours and nobody else's. Whatever is pruned has to be something this addon made:
# deleting a snapshot somebody took by hand before a migration would be a data
# loss with our name on it.
sub is_our_snapshot {
    my ($name) = @_;

    return defined($name) && $name =~ m/\A\Q$SNAPSHOT_PREFIX\E-\d{8}-\d{6}\z/ ? 1 : 0;
}

# Can this container be snapshotted at all? PVE's own answer, per container -
# every one of its volumes has to support it, which is why a container with one
# mountpoint on a directory storage says no even on a node full of ZFS.
#
# Never dies: this is asked while building a settings dialog and while deciding
# whether to snapshot, and neither is a place to fail over a storage.cfg that
# cannot be read. Unknown means "no", which costs a snapshot and never a run.
# $storecfg is optional and only an optimisation: the settings endpoint asks
# this for every container on the node in turn, and reading storage.cfg once for
# all of them also means one warning in the syslog rather than one per container
# when it is the storage config that is broken.
sub can_snapshot {
    my ($vmid, $storecfg) = @_;

    my $safe = eval { PVE::UpdateManager::Runner::_safe_vmid($vmid) };
    return 0 if !defined($safe);

    my $class = _snap_class($safe);

    my $res = eval {
        my $conf = $class->load_config($safe);
        $storecfg //= PVE::Storage::config();

        # $snapname is undef: the question is whether a snapshot can be taken of
        # the guest as it is now. For a container the storage plugins do not
        # consult the running state at all; for a VM QemuConfig hands it on to
        # volume_has_feature, so it is given the true answer rather than a guess.
        my $running = $class eq 'PVE::QemuConfig'
            ? PVE::UpdateManager::Guest::is_running('qemu', $safe)
            : undef;

        $class->has_feature('snapshot', $conf, $storecfg, undef, $running);
    };
    if (my $err = $@) {
        chomp($err);
        warn "pve-update-manager: cannot tell whether " . _who($safe)
            . " can be snapshotted: $err\n";
        return 0;
    }

    return $res ? 1 : 0;
}

# How many seconds forward the name may be moved to find a free one. Five is
# generous for what it is there for - see below.
our $SNAPSHOT_NAME_TRIES = 5;

# Returns the name of the snapshot it made, or dies. Dying is the point: the
# caller asked for a rollback point on a storage that says it can provide one,
# and a run that quietly went ahead without it would have removed the safety net
# in exactly the situation - a full thin pool - where it is needed most.
sub snapshot_guest {
    my ($vmid, $logfunc, $when) = @_;

    my $safe = PVE::UpdateManager::Runner::_safe_vmid($vmid);

    # The name carries a whole second, so two runs of the same container inside
    # one second ask for the same one - and PVE refuses a name it already has:
    # "snapshot name '...' already used", read off AbstractConfig. Measured, not
    # imagined: pressing Update twice on a container whose script finishes
    # instantly failed the second run before it started, with a message that
    # sounds like the storage and is not about the storage.
    #
    # So the stamp is moved forward until the name is free. What the name has to
    # be is unique and readable in a snapshot list; being accurate to the second
    # is not what it is for. A check-then-act is enough here - two workers on the
    # same container are already kept apart by the busy lock, and what is left is
    # runs that follow each other.
    my $class = _snap_class($safe);
    my $stamp = $when // time();
    my $taken = eval { $class->load_config($safe)->{snapshots} } || {};

    my $name = snapshot_name($stamp);
    my $tries = 0;
    while ($taken->{$name} && ++$tries <= $SNAPSHOT_NAME_TRIES) {
        $name = snapshot_name(++$stamp);
    }

    $logfunc->("taking snapshot $name before the update") if $logfunc;

    # The 0 is $save_vmstate. A container has no memory to save; a VM could, and
    # is deliberately snapshotted without it - the owner's decision, and the
    # reason a rollback brings a VM back cold. On a running VM with its agent on,
    # QemuConfig freezes the guest's filesystems around the snapshot by itself
    # (__snapshot_check_freeze_needed), so the disks are caught consistent.
    $class->snapshot_create($safe, $name, 0, 'pve-update-manager: before the update');

    return $name;
}

# Puts the container back to the snapshot this run took.
#
# Only ever one of ours: rolling back to a snapshot somebody made by hand would
# be this addon throwing away work it knows nothing about.
#
# With $remove_newer, a rollback the storage refuses because something
# snapshotted the container after us is tried a second time with those
# snapshots removed - see rollback_blockers below for why that is the only way
# through and why it destroys nothing the rollback would have spared.
#
# What PVE does with it, read off AbstractConfig and then watched on a real 9.2:
# it refuses while ANY lock is set - ours included, so the update lock has to be
# back before this is called - it STOPS the container itself as part of the
# rollback, and it leaves it stopped. Starting it again afterwards is the
# caller's job, and only the caller knows whether it was running to begin with.
sub rollback_guest {
    my ($vmid, $name, $logfunc, $remove_newer) = @_;

    my $safe = PVE::UpdateManager::Runner::_safe_vmid($vmid);

    die "refusing to roll back to '$name', which is not a snapshot this addon took\n"
        if !is_our_snapshot($name);

    my $class = _snap_class($safe);

    $logfunc->("rolling " . _who($safe) . " back to $name") if $logfunc;

    return 1 if eval { $class->snapshot_rollback($safe, $name); 1 };

    my $err = $@ || "rolling back to $name failed\n";
    die $err if !$remove_newer;

    # A second attempt, and only ever this one. The refusal that brings us here
    # is decided BEFORE anything is stopped or written - AbstractConfig checks
    # every volume first - so the failed attempt has changed nothing, and a
    # blocker that appeared in the meantime would only produce the same refusal
    # again. One retry ends; a loop would race the very tool that took the
    # snapshot.
    chomp(my $refused = $err);
    $logfunc->("the rollback was refused - $refused") if $logfunc;

    die $err if !clear_rollback_blockers($safe, $name, $logfunc);

    $class->snapshot_rollback($safe, $name);

    return 1;
}

# What a storage names when it refuses a rollback, and what it is called here.
#
# A rollback undoes the volume, not a list of snapshots, so every snapshot taken
# AFTER the one being rolled back to disappears with it - that is what `zfs
# rollback -r` does, and it is the only thing it can do. ZFS, classic LVM and
# qcow2 snapshot chains therefore refuse outright while such a snapshot exists
# ("can't rollback, 'X' is not most recent snapshot on 'Y'", ZFSPoolPlugin.pm on
# pve-manager 9.2.4); btrfs and LVM-thin roll back regardless and never produce
# one of these.
#
# There is no force to pass on: neither snapshot_rollback, nor the API endpoint,
# nor `pct rollback` has such a parameter. Clearing the way means removing those
# snapshots first, and the reason that is not the data loss it looks like is the
# first paragraph: they do not survive the rollback either way.
#
# Returns them per volume, because removing one is two different operations
# depending on where it lives - see clear_rollback_blockers below.
sub rollback_blockers {
    my ($vmid, $name) = @_;

    my $class = _snap_class($vmid);
    my $conf = eval { $class->load_config($vmid) } // {};
    my $snap = $conf->{snapshots}->{$name};
    return {} if !$snap;

    my $storecfg = eval { PVE::Storage::config() };
    return {} if !defined($storecfg);

    my $per_volume = {};

    $class->foreach_volume(
        $snap,
        sub {
            my ($key, $volume) = @_;

            my $volid = _snapshot_volid($class, $volume);
            return if !defined($volid);

            my $blockers = [];

            # This dies when the rollback is impossible, and the die is the
            # answer: the plugin fills $blockers on its way out. Anything else
            # it dies of - an unparsable volume, a storage that is not there -
            # leaves the list empty, which reads as "nothing here to clear" and
            # keeps the caller reporting the original refusal.
            eval {
                PVE::Storage::volume_rollback_is_possible(
                    $storecfg, $volid, $name, $blockers,
                );
            };

            $per_volume->{$volid} = $blockers if scalar(@$blockers);
        },
    );

    return $per_volume;
}

# Snapshots PVE's replication owns. snapshot_rollback removes the ones in its
# way itself, before the check that produces the list above, so one reaching
# this code would be a surprise - and removing it by hand is how a replication
# job is made to start from the beginning. Left alone, and said out loud.
our $REPLICATION_PREFIX = '__replicate_';

# Removes what rollback_blockers found. Returns how many went away.
#
# This is the one place in the addon that removes a snapshot it did not take.
# It is deliberate and it is narrow: only snapshots the storage itself named as
# standing between the container and the rollback, only after a rollback has
# already been refused, only with the setting on, and only while nothing else
# is known to refuse the retry - see the checks below. Everything else this
# addon touches is still ours and ours alone - the pruning above checks
# is_our_snapshot for exactly that reason.
sub clear_rollback_blockers {
    my ($vmid, $name, $logfunc) = @_;

    my $per_volume = rollback_blockers($vmid, $name);
    return 0 if !scalar(keys %$per_volume);

    my $storecfg = eval { PVE::Storage::config() };
    return 0 if !defined($storecfg);

    my $class = _snap_class($vmid);
    my $conf = eval { $class->load_config($vmid) };
    return 0 if !$conf;
    my $snapshots = $conf->{snapshots} || {};

    # "A rollback destroys them either way" is only true of a rollback that then
    # HAPPENS. Removing a blocker and having the retry refused for another reason
    # destroys somebody's snapshot for nothing (#59). So everything that is known
    # to make the retry fail is asked first, and while any of it holds, nothing
    # is removed:
    #
    # - a lock. snapshot_rollback asks the storage BEFORE check_lock, so the
    #   refusal that brought us here names the blockers even while a backup or a
    #   migration holds the guest - or our own lock, when giving it back failed.
    #   A storage-only blocker is removed through the storage, which asks no
    #   lock, so without this check it went and the retry still said "locked".
    # - a template, and a rollback point with a snapstate: both refused by
    #   snapshot_rollback whatever is on the storage.
    # - a replication snapshot among the blockers: it is left alone below, so
    #   the rollback stays blocked by it.
    my $refuse;
    if (defined($conf->{lock}) && length($conf->{lock})) {
        $refuse = _who($vmid) . " carries a '$conf->{lock}' lock, so the rollback would be refused anyway";
    } elsif ($class->is_template($conf)) {
        $refuse = _who($vmid) . " is a template";
    } elsif (($snapshots->{$name} // {})->{snapstate}) {
        $refuse = "$name is in state '$snapshots->{$name}->{snapstate}'";
    } else {
        my ($repl) = grep { m/\A\Q$REPLICATION_PREFIX\E/ } map { @$_ } values %$per_volume;
        $refuse = "the replication snapshot $repl blocks it too, and it belongs to PVE's"
            . " replication, not to this addon" if defined($repl);
    }
    if (defined($refuse)) {
        $logfunc->("not removing any snapshot to clear the rollback - $refuse") if $logfunc;
        return 0;
    }

    my $removed = 0;
    my %done;

    for my $volid (sort keys %$per_volume) {
        for my $blocker (@{ $per_volume->{$volid} }) {
            # Cannot happen - a plugin only lists what came after - and cheap
            # enough to make sure of, because getting it wrong here deletes the
            # rollback point itself.
            next if $blocker eq $name;

            # Two homes, two removals. A snapshot taken through PVE - by hand,
            # by the API, by a tool that uses it - is in the container's config
            # and has to go through snapshot_delete, which removes it from every
            # volume and from the config. One taken on the storage directly, by
            # a tool that calls `zfs snapshot` itself, is not in the config at
            # all: snapshot_delete would die with "does not exist" and leave the
            # rollback just as blocked, so that one is removed per volume.
            my $in_config = $snapshots->{$blocker} ? 1 : 0;
            next if $in_config && $done{$blocker}++;

            $logfunc->(
                "removing the snapshot $blocker, which is newer than $name and blocks the"
                . " rollback - a rollback to $name destroys it either way")
                if $logfunc;

            my $ok = $in_config
                ? eval { $class->snapshot_delete($vmid, $blocker, 0); 1 }
                : eval { PVE::Storage::volume_snapshot_delete($storecfg, $volid, $blocker); 1 };

            if ($ok) {
                $removed++;
                next;
            }

            my $err = $@ // '';
            chomp($err);
            $logfunc->("WARNING: could not remove $blocker - $err") if $logfunc;

            # Only the config path can wedge the container: snapshot_delete
            # writes the lock and `snapstate: delete` before it asks the storage.
            # The repair is allowed past its own guard here because this blocker
            # is one we were told to remove - see the parameter's comment.
            _repair_stuck_delete($vmid, $blocker, $logfunc, 1) if $in_config;

            # The rollback stays blocked by this one, so every further removal
            # would destroy a snapshot for a rollback that cannot happen (#59).
            # What went before it is gone already - knowing in advance which
            # removal a storage will refuse (a ZFS hold, a dependent clone)
            # would take a dry run no storage plugin offers.
            $logfunc->("stopping here - the rollback stays blocked by $blocker") if $logfunc;
            return $removed;
        }
    }

    return $removed;
}

# Keeps the newest $keep of OUR snapshots and removes the rest.
#
# Ordered by the snaptime PVE records in the config rather than by the name: the
# names carry local time, and one hour a year is lived through twice.
#
# Never dies. Pruning is housekeeping that runs after the update; a snapshot
# that cannot be removed is a warning in the log and a disk that fills up
# slower than it would have, not a failed update.
# The lock PVE sets on a container while it removes one of its snapshots. It is
# set BEFORE the volume is touched and removed again at the very end, so a
# failure in between leaves it behind - see _repair_stuck_delete.
our $SNAPSHOT_DELETE_LOCK = 'snapshot-delete';

# Take back a 'snapshot-delete' lock a failed removal left on the container.
#
# Deliberately narrow: only that exact value is removed. A 'backup', 'mounted'
# or 'migrate' lock means somebody else is holding the container and clearing it
# would be the addon breaking the very rule it obeys everywhere else.
sub _clear_delete_lock {
    my ($vmid, $logfunc) = @_;

    my $class = _snap_class($vmid);
    my $who = _who($vmid);
    my $conf = eval { $class->load_config($vmid) } // {};
    my $lock = $conf->{lock};
    return 1 if !defined($lock) || !length($lock);

    if ($lock ne $SNAPSHOT_DELETE_LOCK) {
        $logfunc->("$who carries a '$lock' lock, which is not ours to remove")
            if $logfunc;
        return 0;
    }

    if (!eval { $class->remove_lock($vmid, $SNAPSHOT_DELETE_LOCK); 1 }) {
        my $err = $@ // '';
        chomp($err);
        $logfunc->("WARNING: $who stays locked ($SNAPSHOT_DELETE_LOCK) - $err")
            if $logfunc;
        return 0;
    }

    $logfunc->("removed the '$SNAPSHOT_DELETE_LOCK' lock the failed removal left on $who")
        if $logfunc;

    return 1;
}

# Undo what a failed snapshot removal leaves behind.
#
# PVE's snapshot_delete locks the container with 'snapshot-delete' and writes
# `snapstate: delete` into the snapshot BEFORE it asks the storage to remove the
# volume. If that removal fails it dies with both still in the config, and
# nothing ever clears them: every later operation on the container - the next
# update, a backup, a start - then refuses because the guest is locked, and the
# web interface shows the snapshot with the status "delete" forever. The
# documented repair is `pct unlock` followed by `pct delsnapshot --force`, and
# that is exactly what happens here.
#
# The force pass can leave the volume itself on the storage - that is what force
# means - so it says so with the name to look for rather than reporting a clean
# removal.
#
# $foreign_ok is the one way past the is_our_snapshot guard below, and it has
# exactly one caller: clear_rollback_blockers, which removes a snapshot that is
# not ours on purpose. Without it, a storage failure there would leave the
# container locked and the snapshot half deleted for good - the guard would
# protect the snapshot from being tidied up after it had already been destroyed.
sub _repair_stuck_delete {
    my ($vmid, $name, $logfunc, $foreign_ok) = @_;

    return 0 if !$foreign_ok && !is_our_snapshot($name);

    my $class = _snap_class($vmid);
    my $conf = eval { $class->load_config($vmid) } // {};
    my $snap = $conf->{snapshots}->{$name};
    my $pending = $snap && ($snap->{snapstate} // '') eq 'delete';
    my $locked = defined($conf->{lock}) && $conf->{lock} eq $SNAPSHOT_DELETE_LOCK;

    # The removal failed before it changed anything - the container is usable
    # and there is nothing half-done to clean up.
    return 1 if !$pending && !$locked;

    # The lock has to go first: snapshot_delete takes it again itself, and
    # set_lock refuses outright while any lock is set, force or not.
    return 0 if !_clear_delete_lock($vmid, $logfunc);

    return 1 if !$pending;

    $logfunc->("snapshot $name is half removed - forcing it out of the config")
        if $logfunc;

    if (!eval { $class->snapshot_delete($vmid, $name, 1); 1 }) {
        my $err = $@ // '';
        chomp($err);
        $logfunc->("WARNING: forcing the removal of $name failed too - $err") if $logfunc;
        # The forced attempt will have taken the lock again on its way in.
        _clear_delete_lock($vmid, $logfunc);
        return 0;
    }

    $logfunc->(
        "snapshot $name is out of the config, but its volume may still be on the"
        . " storage - look for a volume named after the snapshot")
        if $logfunc;

    return 1;
}

# How long a 'snapshot-delete' lock has to have sat untouched before it counts
# as abandoned rather than in progress. A removal that is really running writes
# the container's config several times as it goes - once to mark the snapshot,
# once per volume, once to clean up - so a config nobody has written for this
# long is not one somebody is working on.
our $STALE_WEDGE_SECONDS = 600;

# The name of a snapshot of ours that an earlier run left half deleted, if the
# container is still locked over it and nothing has touched it since.
#
# This is the case the repair in prune_snapshots cannot reach: it only runs when
# a removal fails during a run, and a container that is already locked never
# gets that far - the pre-check skips it, every time, for good.
sub stale_delete_wedge {
    my ($vmid, $now) = @_;

    my $safe = eval { PVE::UpdateManager::Runner::_safe_vmid($vmid) };
    return undef if !defined($safe);

    my $class = _snap_class($safe);
    my $conf = eval { $class->load_config($safe) } // {};
    return undef
        if !defined($conf->{lock}) || $conf->{lock} ne $SNAPSHOT_DELETE_LOCK;

    my ($name) =
        grep { ($conf->{snapshots}->{$_}->{snapstate} // '') eq 'delete' }
        grep { is_our_snapshot($_) }
        sort keys %{ $conf->{snapshots} // {} };
    return undef if !defined($name);

    # The clock is the container's own config file. pmxcfs keeps a real mtime
    # and every write above moves it, which is what makes this a measurement
    # rather than a guess about how long a delete "should" take.
    my $file = eval { $class->config_file($safe) };
    return undef if !defined($file);

    my $mtime = (stat($file))[9];
    return undef if !defined($mtime);

    $now //= time();
    return undef if ($now - $mtime) < $STALE_WEDGE_SECONDS;

    return $name;
}

# Returns how many snapshots were removed. In list context also an arrayref of
# the ones that are still half-deleted, so the caller can say so in the row
# rather than only in the log.
#
# $protect names the snapshot the current run took. It is never removed and
# counts as one of the $keep (#60): ordering by snaptime puts it last only while
# the clock never ran ahead of now - an earlier snapshot taken while it did, or
# on a node whose clock was ahead before a migration, sorts after it, and with a
# keep of one the run's own rollback point was the one removed, minutes before
# the row names it as the snapshot to roll back to.
sub prune_snapshots {
    my ($vmid, $keep, $logfunc, $protect) = @_;

    my $safe = eval { PVE::UpdateManager::Runner::_safe_vmid($vmid) };
    return wantarray ? (0, []) : 0 if !defined($safe);

    # The floor is one, not zero: keeping none would delete the snapshot the run
    # has just taken. The pattern is checked before the comparison because this
    # is callable with whatever a settings file happened to contain, and `<` on
    # a non-number is a warning in the task log rather than an answer.
    $keep = 1 if !defined($keep) || "$keep" !~ m/\A\d+\z/ || $keep < 1;

    my $class = _snap_class($safe);
    my $snapshots = eval { $class->load_config($safe)->{snapshots} } || {};

    my $protected = defined($protect) && is_our_snapshot($protect) && $snapshots->{$protect} ? 1 : 0;

    my @ours =
        sort { ($snapshots->{$a}->{snaptime} // 0) <=> ($snapshots->{$b}->{snaptime} // 0)
                or $a cmp $b }
        grep { is_our_snapshot($_) && !($protected && $_ eq $protect) }
        keys %$snapshots;

    my $excess = scalar(@ours) + $protected - $keep;
    return wantarray ? (0, []) : 0 if $excess <= 0;

    my $removed = 0;
    my $stuck = [];
    for my $name (@ours[0 .. $excess - 1]) {
        $logfunc->("removing old update snapshot $name") if $logfunc;

        if (eval { $class->snapshot_delete($safe, $name, 0); 1 }) {
            $removed++;
            next;
        }

        my $err = $@ // '';
        chomp($err);
        $logfunc->("WARNING: could not remove the old snapshot $name - $err") if $logfunc;

        # Whatever the storage's reason was, the container must not be left
        # locked over it.
        push @$stuck, $name if !_repair_stuck_delete($safe, $name, $logfunc);
    }

    return wantarray ? ($removed, $stuck) : $removed;
}

1;
