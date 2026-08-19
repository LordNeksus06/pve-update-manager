#!/usr/bin/perl
# PVE::UpdateManager::LXCAPI - what pressing Update on one container answers.
#
# The endpoint has three ways out: start a task, refuse, or skip. Which one it
# picks decides what forty selected containers do to the screen, so it is tested
# here rather than inferred from the worker's behaviour.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 31;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Tools;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::LXCAPI;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

my $run = PVE::RESTHandler::registered('PVE::UpdateManager::LXCAPI', 'run');
ok(ref($run) eq 'CODE', 'the run endpoint is registered');

my $delete = PVE::RESTHandler::registered('PVE::UpdateManager::LXCAPI', 'delete_script');

# Fresh books before each call: what matters is not only what came back, but
# whether a Proxmox worker was started at all.
sub call_run {
    my (%param) = @_;

    local @PVE::RPCEnvironment::FORKED = ();

    my $res = eval { $run->({ node => 'pve', %param }) };
    my $err = $@;

    return {
        result => $res,
        error => $err,
        forked => [@PVE::RPCEnvironment::FORKED],
    };
}

sub state_of {
    my ($vmid) = @_;
    return PVE::UpdateManager::Config::load_state('lxc', $vmid) || {};
}

# ── a container with nothing stored ─────────────────────────────────────────
#
# The case that started this: selecting forty containers and pressing Update
# answered with an error per container without a script, and the confirmation
# dialog had just called those "skipped". A skip is what it has to be, and the
# row is where it has to say so - a dialog is gone the moment it is clicked
# away, the row is still there afterwards.
{
    $PVE::LXC::RUNNING{201} = 4711;

    my $call = call_run(vmid => 201);

    is($call->{error}, '', 'a container with no script stored is not an error');
    is($call->{result}, '', 'and answers with no task to watch');
    is(scalar(@{ $call->{forked} }), 0, 'and starts no worker for it');

    my $state = state_of(201);
    is($state->{state}, 'skipped', 'the row says skipped');
    is($state->{note}, 'no update script stored', 'and says why, on the row');
    ok($state->{finished}, 'with an end time, so the row does not spin for ever');
    ok(!defined($state->{upid}) || $state->{upid} eq '', 'and no log link to a task that never ran');
}

# One wording, one place. The worker walking a list and the endpoint answering a
# single container must leave the same sentence behind, or the same container
# reads differently depending on which button was pressed.
{
    $PVE::LXC::RUNNING{202} = 4711;

    PVE::UpdateManager::Job::run_one({ type => 'lxc', id => 202 }, 60, undef, {});

    is(
        state_of(202)->{note},
        state_of(201)->{note},
        'the worker and the endpoint skip a script-less container in the same words',
    );
    is(
        state_of(201)->{note},
        $PVE::UpdateManager::Job::NO_SCRIPT_NOTE,
        'which is the note the module names once',
    );
}

# A script of nothing but whitespace is nothing to run. save_script refuses to
# write one, but the scripts are plain files in /etc/pve that the README invites
# people to edit with $EDITOR - so the check is on content, not on existence.
{
    $PVE::LXC::RUNNING{203} = 4711;
    PVE::Tools::file_set_contents(
        PVE::UpdateManager::Config::script_file('lxc', 203), "   \n\t\n",
    );

    my $call = call_run(vmid => 203);

    is($call->{result}, '', 'a script of pure whitespace is nothing to run');
    is(scalar(@{ $call->{forked} }), 0, 'and starts no worker either');
    is(state_of(203)->{state}, 'skipped', 'the row says skipped for that too');
}

# ── a container that does have one ──────────────────────────────────────────
{
    $PVE::LXC::RUNNING{204} = 4711;
    PVE::UpdateManager::Config::save_script('lxc', 204, "#!/bin/bash\napt-get update\n");

    my $call = call_run(vmid => 204);

    like($call->{result}, qr/\AUPID:/, 'a container with a script gets a task');
    is(scalar(@{ $call->{forked} }), 1, 'and exactly one worker is started for it');
    is($call->{forked}->[0]->{type}, 'ctupdate', 'typed as a container update');
    is($call->{forked}->[0]->{id}, 204, 'and carrying its vmid, so the task list names it');
}

# The text box sends its content along, which is what makes pressing Update run
# what is on screen rather than what was saved last. That has to store first and
# then run - a container with nothing stored yet must not be skipped when the
# request itself brings the script.
{
    $PVE::LXC::RUNNING{205} = 4711;

    my $call = call_run(vmid => 205, script => "#!/bin/sh\napk upgrade\n");

    like($call->{result}, qr/\AUPID:/, 'a script sent with the request is stored and run');
    my ($stored) = PVE::UpdateManager::Config::load_script('lxc', 205);
    like($stored, qr/apk upgrade/, 'and it is what got stored');
}

# A row that is mid-run belongs to that run. Removing a container's script while
# its update is working and pressing Update again must not write "skipped" over
# the "running" its own task is about to finish - the spinner would stop, the
# Update button would come back, and the task would still be inside the
# container.
{
    $PVE::LXC::RUNNING{207} = 4711;
    PVE::UpdateManager::Config::save_state(
        'lxc', 207,
        { state => 'running', started => time(), upid => 'UPID:pve:1:ctupdate:207:' },
    );

    my $call = call_run(vmid => 207);

    like($call->{error}, qr/already being updated/, 'a container mid-run says so');
    is(state_of(207)->{state}, 'running', 'and its row is left exactly as its task left it');
    is(scalar(@{ $call->{forked} }), 0, 'with no second worker started');
}

# A stopped container is still a refusal, not a skip: the node has a setting for
# it, and the message is what points at that setting. Only the no-script case
# moved to the row.
{
    $PVE::LXC::RUNNING{206} = undef;
    PVE::UpdateManager::Config::save_script('lxc', 206, "apt-get update\n");

    my $call = call_run(vmid => 206);

    like($call->{error}, qr/not running/, 'a stopped container still says so to the caller');
    is(scalar(@{ $call->{forked} }), 0, 'and starts no worker');
}

# ── deleting what is stored for a container ─────────────────────────────────
#
# Two different operations behind one endpoint, and the difference matters. A
# user clearing a container's commands is saying "no commands"; the destroy
# dialog is saying "this container is gone". Only the second may take the
# last-run record with it - and it MUST, because Proxmox hands vmids out again
# and the next CT 301 would otherwise inherit this one's update history.
{
    PVE::UpdateManager::Config::save_script('lxc', 301, "apt-get update\n");
    PVE::UpdateManager::Config::save_state(
        'lxc', 301, { state => 'ok', started => 100, finished => 200, exit => 0 },
    );

    $delete->({ node => 'pve', vmid => 301 });

    my ($script, $stored) = PVE::UpdateManager::Config::load_script('lxc', 301);
    is($stored, 0, 'a plain delete removes the commands');
    ok(
        defined(PVE::UpdateManager::Config::load_state('lxc', 301)),
        'and deliberately keeps the record of when it was last updated',
    );
}

{
    PVE::UpdateManager::Config::save_script('lxc', 302, "apt-get update\n");
    PVE::UpdateManager::Config::save_state(
        'lxc', 302, { state => 'ok', started => 100, finished => 200, exit => 0 },
    );

    $delete->({ node => 'pve', vmid => 302, purge => 1 });

    my ($script, $stored) = PVE::UpdateManager::Config::load_script('lxc', 302);
    is($stored, 0, 'purging removes the commands too');
    is(
        PVE::UpdateManager::Config::load_state('lxc', 302),
        undef,
        'and this time the last-run record goes with them',
    );
}

# Nothing stored at all is not an error: the destroy dialog sends this for every
# container, and most of them never had an update script.
{
    ok(
        eval { $delete->({ node => 'pve', vmid => 303, purge => 1 }); 1 },
        'purging a container that never had anything stored is quietly fine',
    );
}

# The flag has to be off by default, or every Remove button in the editor would
# silently be throwing the history away too.
{
    my $def = PVE::RESTHandler::registered_def('PVE::UpdateManager::LXCAPI', 'delete_script');

    is($def->{parameters}->{properties}->{purge}->{default}, 0, 'purge is off unless asked for');
    is($def->{parameters}->{properties}->{purge}->{optional}, 1, 'and it is optional');
}
