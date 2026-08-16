#!/usr/bin/perl
# PVE::UpdateManager::Config - path building, storage, defaults.
#
# The path tests carry the weight here: script_file() is the only place a vmid
# or node name from an API request turns into a filesystem path, so it is also
# the only place that can be talked into writing outside /etc/pve.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 33;

use PVE::Tools;
use PVE::UpdateManager::Config;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# ── path building ───────────────────────────────────────────────────────────
is(
    PVE::UpdateManager::Config::script_file('lxc', 101),
    "$dir/store/lxc-101.conf",
    'container path',
);
is(
    PVE::UpdateManager::Config::script_file('node', 'pve-test'),
    "$dir/store/node-pve-test.conf",
    'node path',
);

my @rejected_vmids = ('../../etc/passwd', '1;rm -rf /', '', '99', 'abc', '10 1', "101\nx");
for my $bad (@rejected_vmids) {
    my $got = eval { PVE::UpdateManager::Config::script_file('lxc', $bad) };
    ok(!defined($got), "vmid '" . ($bad =~ s/\n/\\n/gr) . "' is refused");
}

my @rejected_nodes = ('../other', 'a/b', '', '-leading-dash');
for my $bad (@rejected_nodes) {
    my $got = eval { PVE::UpdateManager::Config::script_file('node', $bad) };
    ok(!defined($got), "node name '$bad' is refused");
}

ok(!defined(eval { PVE::UpdateManager::Config::script_file('vm', 101) }), 'unknown type is refused');

# ── storage ─────────────────────────────────────────────────────────────────
my ($script, $stored) = PVE::UpdateManager::Config::load_script('lxc', 101);
ok(!defined($script) && !$stored, 'nothing stored yet');
is(PVE::UpdateManager::Config::has_script('lxc', 101), 0, 'has_script says so too');

# The directory does not exist yet - saving has to create it, because on a fresh
# install nobody ever ran mkdir in /etc/pve.
PVE::UpdateManager::Config::save_script('lxc', 101, "apt-get update\n");
ok(-d "$dir/store", 'save created the base directory');

($script, $stored) = PVE::UpdateManager::Config::load_script('lxc', 101);
is($script, "apt-get update\n", 'stored script comes back byte for byte');
ok($stored, 'and is reported as stored');
is(PVE::UpdateManager::Config::has_script('lxc', 101), 1, 'has_script agrees');

PVE::UpdateManager::Config::save_script('lxc', 101, "apt-get dist-upgrade\n");
($script) = PVE::UpdateManager::Config::load_script('lxc', 101);
is($script, "apt-get dist-upgrade\n", 'overwriting replaces the whole file');

ok(
    !defined(
        eval {
            PVE::UpdateManager::Config::save_script(
                'lxc', 101, 'x' x ($PVE::UpdateManager::Config::MAX_SCRIPT_SIZE + 1),
            );
        }
    ),
    'an oversized script is refused',
);

# An empty script is refused, not stored: it would show a tick in the grid and
# then skip at run time, which is the worst of both.
ok(
    !defined(eval { PVE::UpdateManager::Config::save_script('lxc', 105, "   \n\t\n") }),
    'a whitespace-only script is refused',
);
ok(!-f PVE::UpdateManager::Config::script_file('lxc', 105), 'and nothing is written');

# A file that went empty some other way must not claim to hold commands.
PVE::Tools::file_set_contents(PVE::UpdateManager::Config::script_file('lxc', 106), '');
is(
    PVE::UpdateManager::Config::has_script('lxc', 106),
    0,
    'an empty file on disk does not count as a stored script',
);
is(
    PVE::UpdateManager::Config::has_script('lxc', 101),
    1,
    'a real one still does',
);

is(PVE::UpdateManager::Config::delete_script('lxc', 101), 1, 'delete removes it');
is(PVE::UpdateManager::Config::delete_script('lxc', 101), 0, 'deleting again is a no-op');

# ── the base directory is created on demand, and reports the real reason ────
{
    my $blocked = tempdir(CLEANUP => 1);
    # A file where the directory should go: mkdir fails and -d fails, so the
    # message has to carry mkdir's errno and not the one the -d stat left behind.
    PVE::Tools::file_set_contents("$blocked/store", "not a directory\n");
    local $PVE::UpdateManager::Config::BASE_DIR = "$blocked/store";

    ok(
        !defined(eval { PVE::UpdateManager::Config::save_script('lxc', 101, "x\n") }),
        'saving into a base directory that cannot exist fails',
    );
    like($@, qr/File exists|Not a directory/, 'with the reason mkdir gave, not the one -d left behind');
}

# ── text pasted out of a Windows editor ─────────────────────────────────────
#
# A literal CR before every LF is what a paste from Notepad carries, and the
# shell takes it as part of the command: measured on the test node, the run
# died with "$'uptime\r': command not found", which names neither cause nor
# cure. Stored scripts are normalised so the box shows what will really run.
{
    PVE::UpdateManager::Config::save_script('lxc', 140, "#!/bin/bash\r\napt-get update\r\nuptime\r\n");
    my ($script) = PVE::UpdateManager::Config::load_script('lxc', 140);

    is($script, "#!/bin/bash\napt-get update\nuptime\n", 'CRLF is normalised on the way in');
    unlike($script, qr/\r/, 'nothing carries a stray carriage return');
}

{
    PVE::UpdateManager::Config::save_script('lxc', 141, "echo a\nprintf 'b\\r'\n");
    my ($script) = PVE::UpdateManager::Config::load_script('lxc', 141);
    is(
        $script,
        "echo a\nprintf 'b\\r'\n",
        'an escape sequence a script writes itself is left alone - only CRLF pairs go',
    );
}
