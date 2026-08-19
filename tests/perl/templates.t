#!/usr/bin/perl
# PVE::UpdateManager::Templates - the editable Templates menu.
#
# Two things are worth pinning here. The file format, because an update script
# is arbitrary text and a format that can be confused by its own content would
# lose somebody's commands on the next save. And the built-in set, because those
# are the lines that actually run against a container.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 63;

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Templates;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

sub names {
    my ($templates) = @_;
    return [map { $_->{name} } @$templates];
}

sub script_of {
    my ($templates, $name) = @_;
    for my $tpl (@$templates) {
        return $tpl->{script} if $tpl->{name} eq $name;
    }
    return undef;
}

# ── nothing stored means the built-ins ──────────────────────────────────────
{
    my ($templates, $custom) = PVE::UpdateManager::Templates::load();

    is($custom, 0, 'a fresh install has no stored list, so there is nothing to reset');
    is(
        scalar(@$templates),
        scalar(@{ PVE::UpdateManager::Templates::defaults() }),
        'and it is handed the built-in set',
    );
    ok(!-f PVE::UpdateManager::Templates::templates_file(), 'reading alone writes no file');
}

# The built-ins are handed out as a copy: a caller that edits one entry must not
# be editing the list the next caller is about to get.
{
    my $first = PVE::UpdateManager::Templates::defaults();
    $first->[0]->{name} = 'clobbered';

    my $second = PVE::UpdateManager::Templates::defaults();
    isnt($second->[0]->{name}, 'clobbered', 'the built-in list cannot be edited by a caller');
}

# ── what the shipped templates actually say ─────────────────────────────────
{
    my $defaults = PVE::UpdateManager::Templates::defaults();
    my $apt = script_of($defaults, 'Debian / Ubuntu (apt)');

    ok(defined($apt), 'there is still an apt template');
    like($apt, qr/^export DEBIAN_FRONTEND=noninteractive$/m, 'it answers debconf questions');
    like($apt, qr/\A\#\!/, 'it starts with a shebang, which is what picks the interpreter');
    like($apt, qr/--force-confold/, 'and keeps the config files that are already on the box');

    my $major = script_of($defaults, 'Debian / Ubuntu - major release upgrade');
    ok(defined($major), 'there is a template for a major release upgrade');
    like(
        $major,
        qr/do-release-upgrade -f DistUpgradeViewNonInteractive/,
        'Ubuntu goes through its own upgrader, non-interactively',
    );
    like(
        $major,
        qr/ubuntu-release-upgrader-core/,
        'and the tool is installed first, because a minimal container has no do-release-upgrade',
    );
    like(
        $major,
        qr/sources\.list\.d\/\*\.sources/,
        'Debian rewrites the deb822 sources trixie ships, not only sources.list',
    );
    like(
        $major,
        qr/--without-new-pkgs upgrade/,
        'and does the minimal upgrade before the full one, as the release notes prescribe',
    );
    like($major, qr/TARGET_RELEASE=/, 'the release to go to is named, not guessed');
    like($major, qr/MAJOR RELEASE UPGRADE/, 'and the box says what it is before it says how');

    for my $tpl (@$defaults) {
        # A template that cannot be stored is a template the moment somebody
        # edits any other one - the first change writes the whole set out.
        ok(
            eval { PVE::UpdateManager::Templates::save([$tpl]); 1 },
            "the built-in '$tpl->{name}' is a storable template",
        );
    }

    PVE::UpdateManager::Templates::reset_to_defaults();
}

# ── an LTS with nowhere to go is not a failed update ────────────────────────
#
# Regression: the template ran do-release-upgrade unconditionally, and on an
# Ubuntu LTS the tool answers "There is no development version of an LTS
# available" and exits 1. That is the NORMAL answer until the next LTS's .1
# point release opens the path - so every run of this template was reported as
# a failed update, snapshot taken and kept for it. The script has to ask first
# and treat "nothing to upgrade to" as a clean run.
#
# Run for real rather than grepped: the claim is about what the shell does with
# an exit code, and a regex cannot see an `if`.
SKIP: {
    skip('no /bin/bash to run the template with', 4) if !-x '/bin/bash';

    my $major = script_of(PVE::UpdateManager::Templates::defaults(),
        'Debian / Ubuntu - major release upgrade');

    my $play = tempdir(CLEANUP => 1);
    mkdir "$play/bin";

    # Only the path to os-release is redirected; everything the claim is about
    # runs exactly as it ships.
    my $script = $major;
    my $edits = ($script =~ s{^\. /etc/os-release$}{. $play/os-release}m);
    is($edits, 1, 'the fixture really is the os-release the shipped script reads');

    PVE::Tools::file_set_contents(
        "$play/os-release", "ID=ubuntu\nVERSION_ID=\"24.04\"\nVERSION_CODENAME=noble\n");
    PVE::Tools::file_set_contents("$play/script.sh", $script);

    for my $stub (qw(apt-get do-release-upgrade)) {
        # "No new release" is reported with the same exit code as a failure,
        # and in BOTH modes: the check and the upgrade run into the same
        # `new_dist is None` branch upstream. That conflation is what the
        # template has to cope with, so the stub reproduces it exactly.
        PVE::Tools::file_set_contents("$play/bin/$stub", <<"EOS");
#!/bin/sh
echo "$stub \$*" >> "\$PLAYLOG"
if [ "$stub" = do-release-upgrade ]; then exit "\$DRU_RC"; fi
exit 0
EOS
        chmod(0755, "$play/bin/$stub");
    }

    my $run = sub {
        my ($dru_rc) = @_;
        unlink("$play/log");
        my $rc = system("PATH='$play/bin:\$PATH' PLAYLOG='$play/log'"
            . " DRU_RC=$dru_rc /bin/bash '$play/script.sh' >/dev/null 2>&1");
        my $log = -f "$play/log" ? PVE::Tools::file_get_contents("$play/log") : '';
        return ($rc, $log);
    };

    my ($nothing_rc, $nothing_log) = $run->(1);
    is($nothing_rc, 0, 'an Ubuntu LTS with nowhere to upgrade to is a successful run');
    unlike(
        $nothing_log,
        qr/DistUpgradeViewNonInteractive/,
        'and the upgrade is not attempted when the check says there is no new release',
    );

    my (undef, $available_log) = $run->(0);
    like(
        $available_log,
        qr/DistUpgradeViewNonInteractive/,
        'but a release that IS available gets upgraded to, which is the point of the template',
    );
}

# ── the file format, against content that looks like the format ─────────────
#
# The case the indentation exists for: a script whose own text contains a line
# reading `name: something`. At column zero that would start a new template and
# eat the rest of the script.
{
    my $nasty = "#!/bin/sh\nname: not a template\n\necho 'still here'\n";

    PVE::UpdateManager::Templates::save(
        [
            { name => 'first', script => $nasty },
            { name => 'second', script => "#!/bin/sh\necho two\n" },
        ],
    );

    my ($templates, $custom) = PVE::UpdateManager::Templates::load();

    is($custom, 1, 'once something is stored the list is custom');
    is_deeply(names($templates), ['first', 'second'], 'both templates came back, in order');
    is(
        script_of($templates, 'first'),
        $nasty,
        'a script containing a `name:` line survives the round trip byte for byte',
    );
    is(
        script_of($templates, 'second'),
        "#!/bin/sh\necho two\n",
        'and it did not swallow the template after it',
    );
}

# Saving the same set twice must produce the same bytes. A format that grows a
# blank line per save is the classic version of getting this wrong.
{
    my ($templates) = PVE::UpdateManager::Templates::load();
    my $once = PVE::Tools::file_get_contents(PVE::UpdateManager::Templates::templates_file());

    PVE::UpdateManager::Templates::save($templates);
    my $twice = PVE::Tools::file_get_contents(PVE::UpdateManager::Templates::templates_file());

    is($twice, $once, 'saving what was just loaded changes nothing on disk');
}

# The stored file is meant to be readable and editable by hand.
{
    my $raw = PVE::Tools::file_get_contents(PVE::UpdateManager::Templates::templates_file());

    like($raw, qr/^name: first$/m, 'the name is on a line of its own');
    like($raw, qr/^ \#\!\/bin\/sh$/m, 'and the script is indented by exactly one space');
    like($raw, qr/^ $/m, 'an empty script line is written as a single space, not as nothing');
}

# A hand-written file with comments and odd spacing reads back as expected.
{
    my $parsed = PVE::UpdateManager::Templates::parse(<<'EOF');
 an indented line before any name has no template to belong to
# a comment at column zero is not a template

name:   spaced out
 echo hi

name: dropped
# nothing indented under this one
EOF

    is_deeply(names($parsed), ['spaced out'], 'a block with no script lines is not offered');
    is(script_of($parsed, 'spaced out'), "echo hi\n", 'and the name is trimmed');
}

# A `name:` with nothing behind it starts nothing - and must end what came
# before. Otherwise the lines under it are appended to the template above and
# two entries silently become one.
{
    my $parsed = PVE::UpdateManager::Templates::parse(<<'EOF');
name: real
 echo mine

name:
 echo belongs to nobody
EOF

    is_deeply(names($parsed), ['real'], 'the nameless block is not a template');
    is(
        script_of($parsed, 'real'),
        "echo mine\n",
        'and its orphaned lines are dropped rather than merged into the entry above',
    );
}

# A blank line or a comment between two script lines does not end the template.
# The rule is deliberately forgiving in this direction: the likely hand-edit is a
# genuinely empty line left inside a script, and ending the block there would
# make the rest of somebody's commands vanish without a word.
{
    my $parsed = PVE::UpdateManager::Templates::parse(<<'EOF');
name: interrupted
 echo before

# somebody's note, at column zero
 echo after
EOF

    is(
        script_of($parsed, 'interrupted'),
        "echo before\necho after\n",
        'a blank line and a comment inside a block do not truncate its script',
    );
}

# ── what save refuses ───────────────────────────────────────────────────────
{
    my @refused = (
        [[{ name => '', script => "echo\n" }], 'a template with no name'],
        [[{ name => "two\nlines", script => "echo\n" }], 'a name carrying a newline'],
        [[{ name => ' leading', script => "echo\n" }], 'a name starting with a space'],
        [[{ name => 'a', script => "  \n" }], 'a template with no commands'],
        [
            [{ name => 'a', script => "echo\n" }, { name => 'a', script => "echo\n" }],
            'two templates with the same name',
        ],
        [
            [{ name => 'x' x 200, script => "echo\n" }],
            'a name longer than the limit',
        ],
    );

    for my $case (@refused) {
        my ($set, $desc) = @$case;
        ok(
            !defined(eval { PVE::UpdateManager::Templates::save($set); 1 }),
            "$desc is refused",
        );
    }

    my $too_many = [map { { name => "t$_", script => "echo\n" } } (1 .. 100)];
    ok(
        !defined(eval { PVE::UpdateManager::Templates::save($too_many); 1 }),
        'and so is a menu with a hundred entries in it',
    );
}

# ── add, replace, rename, remove ────────────────────────────────────────────
{
    PVE::UpdateManager::Templates::reset_to_defaults();

    PVE::UpdateManager::Templates::store_one('Mine', "#!/bin/sh\necho mine\n");
    my ($templates) = PVE::UpdateManager::Templates::load();

    is(
        scalar(@$templates),
        scalar(@{ PVE::UpdateManager::Templates::defaults() }) + 1,
        'adding one writes the built-ins out alongside it',
    );
    is($templates->[-1]->{name}, 'Mine', 'and the new one goes to the end of the menu');

    # Editing a built-in is the point of the whole exercise.
    PVE::UpdateManager::Templates::store_one('Alpine (apk)', "#!/bin/sh\napk upgrade --available\n");
    ($templates) = PVE::UpdateManager::Templates::load();
    is(
        script_of($templates, 'Alpine (apk)'),
        "#!/bin/sh\napk upgrade --available\n",
        'a built-in can be edited',
    );
    is(
        $templates->[2]->{name},
        'Alpine (apk)',
        'and an edited entry keeps its place instead of jumping to the bottom',
    );

    PVE::UpdateManager::Templates::store_one('Alpine', "#!/bin/sh\napk upgrade\n", 'Alpine (apk)');
    ($templates) = PVE::UpdateManager::Templates::load();
    is($templates->[2]->{name}, 'Alpine', 'renaming keeps the position too');
    is(script_of($templates, 'Alpine (apk)'), undef, 'and the old name is gone');

    ok(
        !defined(eval {
            PVE::UpdateManager::Templates::store_one('Mine', "echo\n", 'Alpine');
            1;
        }),
        'renaming onto a name that is taken is refused rather than merging the two',
    );

    ok(
        !defined(eval {
            PVE::UpdateManager::Templates::store_one('x', "echo\n", 'nothing by this name');
            1;
        }),
        'and renaming something that does not exist is an error, not a silent add',
    );

    is(PVE::UpdateManager::Templates::remove_one('Mine'), 1, 'removing reports that it did');
    is(PVE::UpdateManager::Templates::remove_one('Mine'), 0, 'and says so when there is nothing to remove');
    ($templates) = PVE::UpdateManager::Templates::load();
    is(script_of($templates, 'Mine'), undef, 'the entry is really gone');
}

# ── reset ───────────────────────────────────────────────────────────────────
{
    is(PVE::UpdateManager::Templates::reset_to_defaults(), 1, 'reset removes the stored list');

    my ($templates, $custom) = PVE::UpdateManager::Templates::load();
    is($custom, 0, 'and the list is the built-in one again');
    is_deeply(
        names($templates),
        names(PVE::UpdateManager::Templates::defaults()),
        'with every built-in back, including the one that had been edited',
    );

    is(PVE::UpdateManager::Templates::reset_to_defaults(), 0, 'resetting twice is not an error');
}

# An empty stored list is a legitimate answer - "I want no menu" - and must not
# read back as "nothing stored, here are the built-ins".
{
    PVE::UpdateManager::Templates::save([]);

    my ($templates, $custom) = PVE::UpdateManager::Templates::load();
    is($custom, 1, 'an empty list is still a stored list');
    is_deeply($templates, [], 'and it stays empty rather than falling back to the built-ins');

    PVE::UpdateManager::Templates::reset_to_defaults();
}

# A zero-byte file is a successful read of nothing, not a failed read. Getting
# that backwards would put the built-ins back into a menu somebody emptied by
# hand - and the file that made it happen is the easiest one to create.
{
    PVE::UpdateManager::Config::ensure_base_dir();
    PVE::Tools::file_set_contents(PVE::UpdateManager::Templates::templates_file(), '');

    my ($templates, $custom) = PVE::UpdateManager::Templates::load();

    is($custom, 1, 'an empty file is still a stored list');
    is(scalar(@$templates), 0, 'and it holds no templates rather than the built-ins');

    PVE::UpdateManager::Templates::reset_to_defaults();
}
