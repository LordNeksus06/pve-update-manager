package PVE::UpdateManager::Templates;

# The starting points offered by the Templates menu.
#
# They used to be a constant in the web interface file, which made them
# unchangeable without editing an installed .js. They are configuration now: the
# built-in set below is what a fresh install offers, and the moment anything is
# added, edited or removed the WHOLE set is written to
# /etc/pve/pve-update-manager/templates.conf and that file is the truth from
# then on. Deleting the file goes back to the built-ins, which is what "Reset to
# defaults" does.
#
# Writing the whole set rather than a diff is deliberate. A stored list of
# "changes to the built-ins" would silently rewrite a user's menu on the next
# package upgrade that touches the defaults - the one thing an editable list
# must not do.
#
# The file lives in /etc/pve, so the menu is the same on every node of the
# cluster, and `cat` shows what is in it.

use strict;
use warnings;

use PVE::Tools;

use PVE::UpdateManager::Config;

# A menu, not a package repository: these numbers exist to name a mistake rather
# than to attempt a write that pmxcfs would refuse anyway.
our $MAX_TEMPLATES = 64;
our $MAX_NAME_LENGTH = 128;
our $MAX_FILE_SIZE = 256 * 1024;

# ── the built-in set ────────────────────────────────────────────────────────
#
# Suggestions pasted into the text box, never something that runs on its own.
# They are here and not in the JavaScript because the API has to be able to
# answer with them when nothing is stored - two copies of the same text is how
# they drift apart.

my $APT = <<'EOS';
#!/bin/bash
set -e
# noninteractive answers every debconf question with its default.
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
apt-get -y --purge autoremove
apt-get clean
EOS

# A major release upgrade is a different operation from an update, and this
# template says so before it does anything. It is deliberately one template for
# both distributions: they need opposite methods, and picking the wrong one by
# hand is the mistake that leaves a container with half its sources rewritten.
my $APT_MAJOR = <<'EOS';
#!/bin/bash
# MAJOR RELEASE UPGRADE - this moves the container to the NEXT release of its
# distribution, not to the newest packages of the one it is on. Services come
# back as new major versions and configuration files change. Take a snapshot
# first - the node's Update Manager settings can do that for every run.
set -e
export DEBIAN_FRONTEND=noninteractive

# Debian only, and it has to be spelled out: nothing inside the container knows
# which release follows its own. Ubuntu ignores this and asks
# do-release-upgrade, which does know.
TARGET_RELEASE=trixie

. /etc/os-release

# A release upgrade that starts from a half-patched system finishes as a
# half-upgraded one. Bring the CURRENT release fully up to date first.
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
apt-get -y --purge autoremove

case "$ID" in
ubuntu)
    # Ubuntu's own tool is the supported path: it rewrites the sources, knows
    # the per-release quirks and drops obsolete packages afterwards. The
    # non-interactive frontend does NOT reboot by itself - that is the
    # NonInteractive/RealReboot option and it defaults to false - so the
    # container is left running and wants a restart when you are ready.
    apt-get -y install ubuntu-release-upgrader-core

    # Ask before upgrading. do-release-upgrade exits 1 both for "there is
    # nothing to upgrade to" and for a real failure, and on an LTS the first
    # of those is the NORMAL answer: the path to the next LTS only opens with
    # its .1 point release, so until then every run of this template would be
    # reported as a failed update. The check mode writes nothing, so gating on
    # it cannot leave a half-upgraded container. What it can do is call a
    # failed meta-release fetch "nothing to upgrade to" - upstream conflates
    # the two into the same exit code - which is why the tool's own message is
    # left in the log above instead of being swallowed.
    if do-release-upgrade -c; then
        do-release-upgrade -f DistUpgradeViewNonInteractive
    else
        echo "no new release to upgrade to - staying on $VERSION_ID"
    fi
    ;;
debian)
    # Debian has no do-release-upgrade: the codename in the sources IS the
    # upgrade. Both layouts are rewritten - the one-line entries in
    # sources.list and the deb822 .sources files trixie ships - and the word
    # boundary is what turns bookworm-security into trixie-security too.
    if [ -z "$VERSION_CODENAME" ]; then
        echo "no VERSION_CODENAME in /etc/os-release - refusing to guess" >&2
        exit 1
    fi
    if [ "$VERSION_CODENAME" = "$TARGET_RELEASE" ]; then
        echo "already on $TARGET_RELEASE - nothing to upgrade to"
        exit 0
    fi

    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        sed -i "s/\b$VERSION_CODENAME\b/$TARGET_RELEASE/g" "$f"
    done

    apt-get update
    # The two steps the Debian release notes prescribe: the minimal upgrade
    # first, so the packages that have to move before anything else do, then
    # the rest.
    apt-get -y -o Dpkg::Options::=--force-confold --without-new-pkgs upgrade
    apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
    ;;
*)
    echo "not a Debian or Ubuntu container (ID=$ID) - nothing done" >&2
    exit 1
    ;;
esac

apt-get -y --purge autoremove
apt-get clean
EOS

my $APK = <<'EOS';
#!/bin/sh
set -e

apk update
apk upgrade
EOS

my $PACMAN = <<'EOS';
#!/bin/bash
set -e

pacman -Syu --noconfirm
EOS

my $DNF = <<'EOS';
#!/bin/bash
set -e

dnf -y upgrade --refresh
EOS

# Returned as a fresh copy every time: a caller that edits one entry must not be
# editing the built-in list every other caller is about to be handed.
sub defaults {
    return [
        { name => 'Debian / Ubuntu (apt)', script => $APT },
        { name => 'Debian / Ubuntu - major release upgrade', script => $APT_MAJOR },
        { name => 'Alpine (apk)', script => $APK },
        { name => 'Arch (pacman)', script => $PACMAN },
        { name => 'Fedora / RHEL (dnf)', script => $DNF },
    ];
}

sub templates_file {
    return "$PVE::UpdateManager::Config::BASE_DIR/templates.conf";
}

# ── the file format ─────────────────────────────────────────────────────────
#
# One block per template: a `name:` line, then the script indented by exactly
# one space. An empty script line is written as a single space, so a blank line
# inside a script is still an indented line and can never be mistaken for the
# end of a block.
#
# That is the whole reason for the indentation. A format where the script sat at
# column 0 would have no way to tell a script line reading `name: foo` from the
# start of the next template - and an update script is arbitrary text.
#
# Anything else at column 0 - a blank line, a `#` comment - is ignored, so the
# file can be commented and spaced by hand and still read back the same.

sub parse {
    my ($raw) = @_;

    my $res = [];
    my $current;

    for my $line (split(/\n/, $raw // '', -1)) {
        if ($line =~ m/\A[ ](.*)\z/s) {
            # Script content: it belongs to the block above it, and a blank line
            # or a comment in between does NOT end that block. The forgiving
            # reading on purpose - the likely hand-edit is a genuinely empty line
            # left in the middle of a script, and treating that as the end of the
            # template would make the rest of somebody's commands disappear
            # without a word. Before any `name:` at all there is no block to
            # belong to, and the line is dropped.
            push @{ $current->{lines} }, $1 if $current;
            next;
        }

        if ($line =~ m/\Aname:\s*(.*?)\s*\z/) {
            my $name = $1;

            # A `name:` with nothing behind it starts nothing - but it must also
            # END whatever came before, or the indented lines under it would be
            # appended to the previous template and silently merge two entries.
            # Dropping them matches what happens to an indented line before any
            # `name:` at all.
            if (!length($name)) {
                $current = undef;
                next;
            }

            $current = { name => $name, lines => [] };
            push @$res, $current;
            next;
        }

        # A blank line or a comment ends nothing and starts nothing; the next
        # `name:` is what starts the next block.
    }

    # A block with nothing but blank lines under it is dropped rather than
    # offered: a menu entry that pastes an empty box is a menu entry that looks
    # broken, and save() would refuse to store one anyway.
    return [
        map { { name => $_->{name}, script => join("\n", @{ $_->{lines} }) . "\n" } }
        grep { scalar(grep { m/\S/ } @{ $_->{lines} }) }
        @$res
    ];
}

sub encode {
    my ($templates) = @_;

    my $raw = <<'EOH';
# pve-update-manager - the starting points offered by the Templates menu.
#
# One block per template: a `name:` line, then that template's script indented
# by exactly one space. An empty script line is a single space. Lines at column
# zero that are not `name:` - blank lines, these comments - are ignored.
#
# Delete this file to go back to the built-in templates.
EOH

    for my $tpl (@$templates) {
        $raw .= "\nname: $tpl->{name}\n";

        my @lines = split(/\n/, $tpl->{script} // '', -1);
        # The trailing newline every script is stored with produces one empty
        # field at the end. Writing it out would add a blank line to the script
        # on every save - the classic file that grows by one line each time it
        # is opened.
        pop @lines if scalar(@lines) && $lines[-1] eq '';

        $raw .= " $_\n" for @lines;
    }

    return $raw;
}

# Returns ($templates, $custom). $custom is false when the built-ins are being
# reported because nothing is stored - which is what tells the UI whether
# "Reset to defaults" has anything to undo.
#
# Never dies. This feeds a menu; a hand-edited file that cannot be read may cost
# the customised entries and a line in the syslog, it may not cost the tab.
sub load {
    my $file = templates_file();
    return (defaults(), 0) if !-f $file;

    my $raw = eval { PVE::Tools::file_get_contents($file, $MAX_FILE_SIZE) };
    if (my $err = $@) {
        chomp($err);
        warn "pve-update-manager: cannot read the update templates: $err\n";
        return (defaults(), 0);
    }

    # $@ rather than defined($raw) as the test for failure: a zero-byte file is
    # a successful read of nothing, and treating it as a failure would put the
    # built-ins back in a menu somebody emptied on purpose.
    my $templates = parse($raw);

    # An empty file is a stored "no templates at all", which is a legitimate
    # thing to want - a menu with nothing in it rather than the built-ins back.
    return ($templates, 1);
}

# Every write goes through here, so there is one place that decides what a
# storable set looks like.
sub save {
    my ($templates) = @_;

    die "too many templates (max $MAX_TEMPLATES)\n"
        if scalar(@$templates) > $MAX_TEMPLATES;

    my %seen;
    for my $tpl (@$templates) {
        my $name = $tpl->{name};

        die "a template needs a name\n" if !defined($name) || $name !~ m/\S/;
        # A newline in the name would forge a block boundary, and a leading
        # space would be read back as script content. Neither can survive here.
        die "a template name must be a single line\n" if $name =~ m/[\r\n]/;
        die "a template name must not start or end with a space\n"
            if $name =~ m/\A\s|\s\z/;
        die "template name is too long (max $MAX_NAME_LENGTH characters)\n"
            if length($name) > $MAX_NAME_LENGTH;
        die "duplicate template name '$name'\n" if $seen{$name}++;

        my $script = $tpl->{script};
        die "template '$name' has no commands\n"
            if !defined($script) || $script !~ m/\S/;
        die "template '$name' is too large (max"
            . " $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE bytes)\n"
            if length($script) > $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE;
    }

    my $raw = encode($templates);
    die "the template list is too large (max $MAX_FILE_SIZE bytes)\n"
        if length($raw) > $MAX_FILE_SIZE;

    PVE::UpdateManager::Config::ensure_base_dir();
    PVE::Tools::file_set_contents(templates_file(), $raw);

    return $templates;
}

# Adds or replaces one entry, and can rename one on the way.
#
# Read, change, write - with no lock around it, deliberately. Two people editing
# the menu in the same second would have one of the two edits lost, and that is
# the whole exposure: file_set_contents writes through a temporary file and a
# rename, so the file itself is never half-written. A lock for a menu that is
# edited a handful of times in a machine's life would cost more than the race.
#
# Replacing in place rather than removing and appending: an entry that jumped to
# the bottom of the menu every time its text was corrected would be a menu that
# reorders itself behind the user's back.
sub store_one {
    my ($name, $script, $oldname) = @_;

    my ($templates) = load();

    my $target = defined($oldname) && length($oldname) ? $oldname : $name;

    # Renaming onto a name that is already taken would silently merge two
    # entries into one. Say so instead.
    die "a template named '$name' already exists\n"
        if $target ne $name && grep { $_->{name} eq $name } @$templates;

    my $replaced = 0;
    for my $tpl (@$templates) {
        next if $tpl->{name} ne $target;
        $tpl->{name} = $name;
        $tpl->{script} = $script;
        $replaced = 1;
        last;
    }

    die "no template named '$oldname'\n" if !$replaced && defined($oldname) && length($oldname);

    push @$templates, { name => $name, script => $script } if !$replaced;

    return save($templates);
}

# Returns 1 when something was removed, 0 when there was nothing by that name.
sub remove_one {
    my ($name) = @_;

    # An empty name matches nothing, and says so, rather than comparing undef
    # against every entry. The schema already requires one; this is the second
    # lock on the door, because the value that gets here decides whether one
    # entry or none is removed.
    return 0 if !defined($name) || !length($name);

    my ($templates) = load();

    my $before = scalar(@$templates);
    my $left = [grep { $_->{name} ne $name } @$templates];

    return 0 if scalar(@$left) == $before;

    save($left);

    return 1;
}

# Back to the built-ins by deleting the file, not by writing the built-ins into
# it. A stored copy of today's defaults would freeze them: the next release
# could improve a template and this install would never see it.
sub reset_to_defaults {
    my $file = templates_file();
    return 0 if !-f $file;

    unlink($file) or die "unable to delete '$file' - $!\n";

    return 1;
}

1;
