package PVE::UpdateManager::Notify;

# Says out loud that an update run had a target fail.
#
# Through Proxmox' own notification system, not through an address of our own:
# the node already knows where its backup and package notifications go, and a
# second address field in a second settings page is a second thing to keep in
# step with reality. What comes out of here is one notification with
# `type=pve-update-manager` on it, and the targets and matchers under Datacenter
# -> Notifications decide whether that becomes a mail, a Gotify push, a webhook
# or nothing at all.
#
# ONE notification per run, and only once the whole run is over. A run of twelve
# containers that breaks four is one thing that happened, not four - and four
# mails for it is how somebody learns to filter them all away. That is also why
# the notification is sent from the job rather than from run_one: the job is the
# only thing that knows the run is finished.
#
# Nothing is sent for a run in which everything worked. A target that was SKIPPED
# is not a failure either - "no update script stored" and "container is not
# running" are answers, not breakage, and they are on the target's own row.

use strict;
use warnings;

use PVE::INotify;

# The name of the template files this needs on the node, minus their
# `-subject.txt.hbs`, `-body.txt.hbs` and `-body.html.hbs` endings. Proxmox
# renders them from /usr/share/pve-manager/templates/default, and the packaging
# installs them there - read off libpve_rs.so on PVE 9.2 rather than assumed.
#
# The templates and the data below are built to Proxmox' own shape, not to one of
# our own: the subject is `... status ({{fqdn}}): {{status-text}}` like vzdump's,
# the text body is a `Details` section with an `=====` rule over a {{table}}, the
# html body is the same table with vzdump's inline styles, and multi-word keys are
# kebab-case (`status-text`, `failed-targets`, `total-time`) because every key in
# every PVE template is. A notification that arrives in a different shape from the
# backup one next to it in the same mailbox is a notification somebody has to stop
# and read twice.
our $TEMPLATE = 'pve-update-manager';

# The metadata field a matcher can select on, so somebody who wants update
# failures somewhere other than the rest can say `match-field type=...`.
our $TYPE = 'pve-update-manager';

# The table of what failed, and the counts around it - everything that goes into
# the template except the hostname, which PVE fills in itself.
#
# Split out from the sending so it can be tested without a notification system
# underneath: what this returns IS the notification, and the part that can be
# wrong in a way nobody sees is the shape of the table.
#
# Returns undef when there is nothing to report, which is the caller's signal to
# send nothing at all rather than a mail that says everything is fine.
sub failure_report {
    my ($results, $upid, $elapsed) = @_;

    $results //= [];

    my @failed = grep { ($_->{state} // '') eq 'FAILED' } @$results;
    return undef if !scalar(@failed);

    my $total = scalar(@$results);
    my $skipped = scalar(grep { ($_->{state} // '') eq 'SKIPPED' } @$results);
    my $now = time();

    return {
        failed => scalar(@failed),
        skipped => $skipped,
        ok => $total - scalar(@failed) - $skipped,
        total => $total,
        # The one line the subject is built from, the way vzdump builds its own.
        # Here rather than in the template so a template somebody rewrites cannot
        # end up saying something the summary in the task log does not.
        'status-text' => sprintf(
            '%d of %d update targets failed', scalar(@failed), $total,
        ),
        # Seconds, for the `duration` helper - the same field and the same helper
        # vzdump reports its own running time through.
        'total-time' => defined($elapsed) ? $elapsed : 0,
        # Empty rather than absent when the run was not started by a worker with
        # a UPID - a template that prints an undefined value is a template that
        # renders "Task: " and not one that fails.
        upid => $upid // '',
        # A LIST, walked by the template with {{#each}}, one stacked block per
        # target - not a {{table}}. A table puts everything about a target on one
        # wide line, and the fields that matter most when an update fails are the
        # ones a table squeezes: which snapshot there is to go back to, and
        # whether the run already went back to it. Upstream does both - vzdump
        # tabulates its guests, fencing stacks its nodes with {{#each}} - and this
        # is the fencing shape because this is the fencing question: something
        # broke, what is the state of the machine now.
        'failed-targets' => [
            map { _target_block($_, $now) } @failed
        ],
    };
}

# One failed target, as the lines the notification prints under its name.
#
# Every value is a STRING that is ready to print, or a number a helper renders -
# never an undef and never a "-" that has to be guessed at. The template's job is
# layout; deciding what "no snapshot" reads as is this function's.
sub _target_block {
    my ($result, $now) = @_;

    my $facts = $result->{facts} // {};

    # What the note says beyond the fields around it. The note is one sentence
    # built for the row and the log, and it opens by repeating the exit code and
    # the duration - both of which now have lines of their own. Printing it whole
    # underneath them is the long line the fields were split out of, so what is
    # kept is the part that is nowhere else: dropped output, a container that
    # could not be stopped again, a snapshot that could not be removed.
    my @also;
    push @also,
        sprintf('%d further output line%s not logged',
            $facts->{dropped}, ($facts->{dropped} == 1 ? '' : 's'))
        if ($facts->{dropped} // 0) > 0;
    push @also, 'the container could NOT be stopped again' if $facts->{shutdown_failed};
    push @also,
        sprintf('%d snapshot%s could NOT be removed',
            $facts->{stuck}, ($facts->{stuck} == 1 ? '' : 's'))
        if ($facts->{stuck} // 0) > 0;

    # Three separate things somebody has to know, and the difference between them
    # decides what to do next: whether the update was taken back, whether the
    # container is up, and whether there is still a snapshot to go back to.
    my $snapshot = $facts->{snapshot};
    my $rollback =
        !$facts->{rolled_back} && $facts->{rollback_failed}
            ? 'tried and FAILED - the container is NOT back on the snapshot'
        : $facts->{rolled_back} && $facts->{rollback_failed}
            ? 'yes - but the container did NOT come back up afterwards'
        : $facts->{rolled_back} ? 'yes - the update was taken back'
        : defined($snapshot) ? 'no - the snapshot above is still there to go back to'
        : 'no - there is no snapshot of this container to go back to';

    return {
        target => $result->{desc},
        # Epochs, for Proxmox' own `timestamp` and `duration` helpers. Never
        # undef: a null reaches the reader as the literal word ERROR in the cell.
        finished => ($facts->{finished} // $result->{finished} // '') =~ m/\A\d+\z/
            ? int($facts->{finished} // $result->{finished})
            : $now,
        ran => ($facts->{elapsed} // '') =~ m/\A\d+\z/ ? int($facts->{elapsed}) : 0,
        exit => defined($result->{exit}) ? $result->{exit} : '',
        # "timed out" and "exit 124" are the same number and not the same event -
        # the limit killed the process tree rather than the script deciding to
        # stop - so the line says which one it was.
        outcome => $facts->{timed_out} ? 'the time limit killed it' : 'the script exited',
        snapshot => defined($snapshot) ? $snapshot : 'none was taken',
        rollback => $rollback,
        also => scalar(@also) ? join('; ', @also) : 'nothing else to report',
        # Not printed by the templates that ship here - everything in it is on a
        # line of its own above, which is the point. It is handed over anyway
        # because a template under /etc/pve/notification-templates overrides
        # these, and somebody who wants the sentence the row and the task log
        # carry should not have to reassemble it from the fields.
        note => $result->{note} // '',
    };
}

# Sends it, and never lets that failure become the run's failure.
#
# PVE::Notify is required at call time rather than used at the top of the file on
# purpose: this module is loaded by every worker on every run, and a node whose
# notification stack is not there - or is a version that does not have it - must
# still be able to update its containers. The one thing it may not do is take the
# job down on the way out; the run has already happened either way, and the task
# log is the record of it.
#
# Returns 1 when a notification was handed over, 0 when there was nothing to
# report, and undef when the attempt failed.
sub notify_failures {
    my ($results, $upid, $elapsed) = @_;

    my $report = failure_report($results, $upid, $elapsed);
    return 0 if !$report;

    my $sent = eval {
        require PVE::Notify;

        my $data = PVE::Notify::common_template_data();
        $data->{$_} = $report->{$_} for keys %$report;

        PVE::Notify::error(
            $TEMPLATE,
            $data,
            {
                type => $TYPE,
                # Without the domain part, the same way every other notification
                # in PVE fills this field - a matcher written for one of them has
                # to work for this one.
                hostname => PVE::INotify::nodename(),
            },
        );

        1;
    };

    if (!$sent) {
        my $err = $@ // 'unknown error';
        chomp($err);
        warn "unable to send the update failure notification - $err\n";
        return undef;
    }

    return 1;
}

1;
