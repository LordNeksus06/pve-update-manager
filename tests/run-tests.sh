#!/usr/bin/env bash
# The pve-update-manager test suite.
#
#   bash tests/run-tests.sh
#
# Three parts:
#
#   perl unit tests   the modules against the stubs in tests/stubs - path
#                     building, interpreter selection, the shape of the task log
#   web interface     the REAL js/pve-update-manager.js, loaded into a V8 context
#                     with a stub ExtJS - what it decides, without a browser
#   hook tests        the REAL tools/pve-update-manager-hooks, run against copies
#                     of a real index.html.tpl, a real taint-mode pvedaemon and a
#                     real pvesh in a tmpdir, checking that applying twice changes
#                     nothing and that reverting restores them byte for byte
#
# No Proxmox is needed for any of it, which is the point: this runs in CI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HOOKS="$REPO_ROOT/tools/pve-update-manager-hooks"

failures=0
checks=0

ok() {
    checks=$((checks + 1))
    echo "  ok   $*"
}

bad() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    echo "  FAIL $*"
}

check() {
    # check <description> <command...>
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"
    else
        bad "$desc"
    fi
}

# Line number of the first line of $2 matching $1, or empty.
#
# `grep -m1` rather than `grep | head -1`: head closes the pipe as soon as it has
# its line, and a grep that has not exited yet takes SIGPIPE for it - exit 141,
# which `set -o pipefail` turns into a failed pipeline and `set -e` turns into a
# dead test run. It is a race, so it passes locally and falls over on a busy CI
# runner, which is exactly how it was found.
#
# `|| true` for the no-match case: a missing line must fail its own check with a
# message, not abort the suite before the rest of the checks run.
line_of() {
    local pattern="$1" file="$2"
    grep -nEm1 -- "$pattern" "$file" 2>/dev/null | cut -d: -f1 || true
}

echo "== perl unit tests"
for t in tests/perl/*.t; do
    if out="$(perl -I tests/stubs -I perl "$t" 2>&1)"; then
        ok "$t"
    else
        bad "$t"
        # shellcheck disable=SC2001  # indenting every line of a captured block
        echo "$out" | sed 's/^/       /'
    fi
done

# What the interface DECIDES can be tested without a browser: the file is loaded
# into a V8 context carrying a stub ExtJS. What it LOOKS like cannot, and no
# amount of this replaces opening the page once.
echo
# The publishing tool checks itself, where it exists: it is not part of what it
# publishes, so a checkout can legitimately be without it and these two checks
# then have nothing to run against.
if [ -f "$REPO_ROOT/tools/github-mirror.sh" ]; then
    # Every top-level entry has to be classified as published or withheld before
    # it can be added, not on the day somebody publishes. This is the check that
    # would have caught `.gitea/` and CLAUDE.md going out.
    check "the publishing tool knows what may be published" \
        bash "$REPO_ROOT/tools/github-mirror.sh" check

    # And the scans it refuses on: a scanner nobody has watched fail is a scanner
    # nobody knows the shape of. Its own fixtures, its own verdict.
    if out="$(bash "$REPO_ROOT/tools/github-mirror.sh" selftest 2>&1)"; then
        ok "the scans catch addresses and credentials before publishing"
    else
        bad "the scans catch addresses and credentials before publishing"
        # shellcheck disable=SC2001  # indenting every line of a captured block
        echo "$out" | sed 's/^/       /'
    fi

    # The same scans over THIS tree, so a line that makes the repository
    # unpublishable fails here rather than on the day somebody asks for it to go
    # out. It reads the last commit, which is what sync would stage.
    if out="$(bash "$REPO_ROOT/tools/github-mirror.sh" scan 2>&1)"; then
        ok "nothing in the tree would stop it from being published"
        echo "$out" | grep '^github-mirror: SKIP' | sed 's/^github-mirror: /       /' || true
    else
        bad "nothing in the tree would stop it from being published"
        # shellcheck disable=SC2001  # indenting every line of a captured block
        echo "$out" | sed 's/^/       /'
    fi

    # And over the WORKING TREE, which is not the same question. The scan above
    # reads the last commit because that is what sync would stage - so a line
    # added but not yet committed passes it, and then fails the pipeline after the
    # push. That has happened twice: a packaging check and an address pattern,
    # both green locally and red in CI for something sitting in the editor.
    if out="$(bash "$REPO_ROOT/tools/github-mirror.sh" scan --worktree 2>&1)"; then
        ok "and neither would what is about to be committed"
    else
        bad "and neither would what is about to be committed"
        # shellcheck disable=SC2001  # indenting every line of a captured block
        echo "$out" | sed 's/^/       /'
    fi
fi

# A setting the server knows and the dialog does not is invisible: the window
# saves what it has, and the key it never loaded is written back as whatever
# default the merge produced. Both sides are listed here rather than trusted to
# stay in step - this is the one drift that costs a value somebody set.
echo "== settings reach the dialog"
# LC_ALL=C on both sides: perl sorts bytes and `sort` follows the locale, and
# comm refuses two lists that were ordered by different rules.
schema_keys="$(perl -I tests/stubs -I perl -e '
    use PVE::UpdateManager::Config;
    my $s = PVE::UpdateManager::Config::settings_schema();
    print join("\n", sort keys %$s), "\n";
' | LC_ALL=C sort)"
# What the window sends: commonParams(), plus the two the two modes add
# themselves - the ticked containers and the host tick.
dialog_keys="$(
    {
        awk '/commonParams: function/,/^    },/' js/pve-update-manager.js \
            | sed -n 's/^ *\([a-z_]*\): me\.down.*/\1/p'
        printf 'schedule_host\nschedule_vmids\n'
    } | LC_ALL=C sort -u
)"
missing="$(comm -23 <(echo "$schema_keys") <(echo "$dialog_keys"))"
unknown="$(comm -13 <(echo "$schema_keys") <(echo "$dialog_keys"))"
if [ -z "$missing" ] && [ -z "$unknown" ]; then
    ok "the settings window and the API describe the same settings"
else
    bad "the settings window and the API describe the same settings"
    # shellcheck disable=SC2001  # prefixing every line of a captured block
    [ -z "$missing" ] || echo "$missing" | sed 's/^/       missing from the dialog: /'
    # The other direction is a save that comes back as a 400 for every node:
    # additionalProperties is 0, so a key the schema does not know is refused.
    # shellcheck disable=SC2001
    [ -z "$unknown" ] || echo "$unknown" | sed 's/^/       sent but not in the schema: /'
fi

# A notification template is rendered by Proxmox, not by us, and a key that does
# not exist is not an error there - it renders as nothing. So a template that
# names `{{total_time}}` where the code writes `total-time` produces a mail with a
# blank where the number should be, at 03:00, and says nothing anywhere else. Both
# sides are compared here rather than trusted to stay in step.
#
# The reference set is Proxmox' own common data (hostname, fqdn, cluster-name)
# plus whatever failure_report() actually returns - derived, not a second list to
# keep up to date.
echo
echo "== the notification template and the code agree"
if out="$(perl -I tests/stubs -I perl -e '
    use strict;
    use warnings;
    use PVE::UpdateManager::Notify;

    # What PVE::Notify::common_template_data adds to every notification.
    my %known = map { $_ => 1 } qw(hostname fqdn cluster-name);

    my $report = PVE::UpdateManager::Notify::failure_report(
        [{ desc => "CT 101", state => "FAILED", note => "n", exit => 1, finished => 1 }],
        "UPID:x", 1,
    );
    $known{$_} = 1 for keys %$report;

    # The fields one failed target carries, for the {{this.x}} references inside
    # the {{#each}} blocks.
    my %row = map { $_ => 1 } keys %{ $report->{"failed-targets"}->[0] };

    my $bad = 0;
    for my $file (glob("packaging/notification-templates/*.hbs")) {
        open(my $fh, "<", $file) or die "cannot read $file - $!";
        local $/ = undef;
        my $raw = <$fh>;
        close($fh);

        while ($raw =~ m/\{\{~?([^}]*?)~?\}\}/g) {
            my $expr = $1;
            $expr =~ s/\A\s+|\s+\z//g;
            # Comments, block ends, and the block helpers themselves.
            next if $expr =~ m|\A[!/]|;
            # `else` is handlebars structure, not data. Listed because a false
            # red costs a round and gets blamed on the check rather than on the
            # template - the first `{{#if}}...{{else}}` anybody adds would
            # otherwise be reported as a value nothing sends.
            next if $expr eq q{else};
            $expr =~ s/\A#\w+\s+//;
            next if !length($expr);
            # The last word is the data; anything before it is a helper.
            my @words = split(/\s+/, $expr);
            my $ref = $words[-1];
            # Parenthesised sub-expressions are helpers of their own - not data.
            next if $ref =~ m/[()]/;

            if ($ref =~ s/\Athis\.//) {
                print "$file: row field {{this.$ref}} is in no table column\n"
                    and $bad++
                    if !$row{$ref};
                next;
            }

            my ($base) = split(/\./, $ref);
            print "$file: {{$ref}} is data nothing puts in the notification\n" and $bad++
                if !$known{$base};
        }
    }

    exit($bad ? 1 : 0);
' 2>&1)"; then
    ok "every value the templates print is data the code really sends"
else
    bad "every value the templates print is data the code really sends"
    # shellcheck disable=SC2001  # indenting every line of a captured block
    echo "$out" | sed 's/^/       /'
fi

# And the other way round for the files themselves: Proxmox renders a subject and
# a body from a template NAME, and a name with no files behind it is a
# notification that fails to render at the moment it is needed. All three,
# because upstream ships all three for every one of its own templates.
for part in subject.txt body.txt body.html; do
    if [ -f "$REPO_ROOT/packaging/notification-templates/pve-update-manager-$part.hbs" ]; then
        ok "the $part template is there"
    else
        bad "the $part template is there"
    fi
done

echo
echo "== web interface"
for t in tests/js/*.test.js; do
    if out="$(node "$t" 2>&1)"; then
        ok "$t"
    else
        bad "$t"
        # shellcheck disable=SC2001  # indenting every line of a captured block
        echo "$out" | sed 's/^/       /'
    fi
done

# The schedule is a systemd calendar event now, parsed by PVE::CalendarEvent on
# the server and entered through the same pveCalendarEvent field a backup job
# uses - so there is no second implementation to drift apart from.
echo
echo "== hook script"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# pvedaemon and pveproxy are taint-mode scripts loading PVE::Service::*, pvesh is
# not taint mode and loads PVE::CLI::* - all three have to be hooked, so all
# three are in the fixture set.
sed "s|@STUBS@|$REPO_ROOT/tests/stubs|" tests/fixtures/pvedaemon.in > "$WORK/pvedaemon"
cp "$WORK/pvedaemon" "$WORK/pveproxy"
sed "s|@STUBS@|$REPO_ROOT/tests/stubs|" tests/fixtures/pvesh.in > "$WORK/pvesh"
cp tests/fixtures/index.html.tpl "$WORK/index.html.tpl"
chmod 0755 "$WORK/pvedaemon" "$WORK/pveproxy" "$WORK/pvesh"

PERL_FILES=(pvedaemon pveproxy pvesh)

# Proxmox' own bundle, standing in the directory the hooks work in. Nothing in
# the script should ever write to it - the whole design is an ExtJS override
# precisely so this file stays as pve-manager shipped it. The workflow asserts
# that by reading the script; this asserts it by running it.
cat > "$WORK/pvemanagerlib.js" <<'BUNDLE'
// stand-in for Proxmox' own bundle - must come out of apply/revert untouched
Ext.define('PVE.panel.Config', { extend: 'Ext.tab.Panel' });
BUNDLE

mkdir -p "$WORK/pristine"
cp -a "$WORK/pvedaemon" "$WORK/pveproxy" "$WORK/pvesh" "$WORK/index.html.tpl" \
      "$WORK/pvemanagerlib.js" "$WORK/pristine/"

cp js/pve-update-manager.js "$WORK/ui.js"

export PVEUM_TPL="$WORK/index.html.tpl"
export PVEUM_TPL_JS="$WORK/ui.js"
export PVEUM_PERL_TARGETS="$WORK/pvedaemon $WORK/pveproxy $WORK/pvesh"
export PVEUM_BACKUP_DIR="$WORK/backup"

# ── apply ───────────────────────────────────────────────────────────────────
check "apply succeeds" bash "$HOOKS" apply --quiet

# Counts OUR line, not the name. The fixtures deliberately carry an unrelated
# mention of "pve-update-manager" so that a detection which matches the bare name
# instead of the whole inserted line fails here - which is exactly what happened
# once the repository was renamed and the checkout path started containing it.
count_lines() {
    grep -c -- "$1" "$2" || true
}

if [ "$(count_lines 'pve-update-manager\.js' "$WORK/index.html.tpl")" = "1" ]; then
    ok "the web interface hook is added exactly once"
else
    bad "the web interface hook is added exactly once"
fi

# Position matters: our script needs PVE.panel.Config to exist, which means it
# must load AFTER pvemanagerlib.js and not merely somewhere in <head>.
lib_line="$(line_of 'pvemanagerlib\.js' "$WORK/index.html.tpl")"
our_line="$(line_of 'pve-update-manager\.js' "$WORK/index.html.tpl")"
# ${x:-0} so a pattern that did not match reports a FAIL with the line numbers
# rather than dying in the arithmetic and taking the rest of the suite with it.
if [ -n "$our_line" ] && [ "$our_line" = "$(( ${lib_line:-0} + 1 ))" ]; then
    ok "the script tag sits directly after pvemanagerlib.js"
else
    bad "the script tag sits directly after pvemanagerlib.js (tag on '${our_line:-<none>}', pvemanagerlib on '${lib_line:-<none>}')"
fi

for d in "${PERL_FILES[@]}"; do
    if [ "$(count_lines 'UpdateManager::Inject' "$WORK/$d")" = "1" ]; then
        ok "$d carries the require line exactly once"
    else
        bad "$d carries the require line exactly once"
    fi

    anchor_line="$(line_of '^use PVE::(Service|CLI)::' "$WORK/$d")"
    req_line="$(line_of 'UpdateManager::Inject' "$WORK/$d")"
    # BEFORE, not after: pvesh resolves the requested path while its entry-point
    # module is still being imported, so a require placed below it is too late.
    if [ -n "$anchor_line" ] && [ "$anchor_line" = "$(( ${req_line:-0} + 1 ))" ]; then
        ok "$d loads it right before its entry-point module"
    else
        bad "$d loads it right before its entry-point module (require on '${req_line:-<none>}', anchor on '${anchor_line:-<none>}')"
    fi

    check "$d still compiles" perl -Tc "$WORK/$d"
done

# Proxmox versions its own script tags; without one the browser keeps running
# the interface it cached, against an API that has moved on - which is exactly
# how a removed button was seen calling a removed endpoint.
if [ "$(count_lines 'pve-update-manager\.js?ver=' "$WORK/index.html.tpl")" = "1" ]; then
    ok "the script tag carries a version"
else
    bad "the script tag carries a version"
fi

ver_before="$(sed -n 's/.*pve-update-manager\.js?ver=\([0-9a-f]*\).*/\1/p' "$WORK/index.html.tpl")"
echo '// changed' >> "$WORK/ui.js"
bash "$HOOKS" apply --quiet >/dev/null 2>&1 || true
ver_after="$(sed -n 's/.*pve-update-manager\.js?ver=\([0-9a-f]*\).*/\1/p' "$WORK/index.html.tpl")"

if [ -n "$ver_before" ] && [ -n "$ver_after" ] && [ "$ver_before" != "$ver_after" ]; then
    ok "and it changes when the interface file does"
else
    bad "and it changes when the interface file does ($ver_before -> $ver_after)"
fi
if [ "$(count_lines 'pve-update-manager\.js' "$WORK/index.html.tpl")" = "1" ]; then
    ok "without leaving the previous tag behind"
else
    bad "without leaving the previous tag behind"
fi

for f in index.html.tpl "${PERL_FILES[@]}"; do
    if [ "$(count_lines 'stray mention of pve-update-manager' "$WORK/$f")" = "1" ]; then
        ok "the unrelated mention in $f was left alone"
    else
        bad "the unrelated mention in $f was left alone"
    fi
done

for f in index.html.tpl "${PERL_FILES[@]}"; do
    check "a backup of $f was kept" test -f "$WORK/backup/${WORK//\//_}_$f"
done

# ── idempotency ─────────────────────────────────────────────────────────────
before="$(md5sum "$WORK/index.html.tpl" "$WORK/pvedaemon" "$WORK/pveproxy" "$WORK/pvesh")"
check "a second apply succeeds" bash "$HOOKS" apply --quiet
after="$(md5sum "$WORK/index.html.tpl" "$WORK/pvedaemon" "$WORK/pveproxy" "$WORK/pvesh")"
if [ "$before" = "$after" ]; then
    ok "applying twice changes nothing"
else
    bad "applying twice changes nothing"
fi

check "status reports success while hooked" bash "$HOOKS" status

if cmp -s "$WORK/pristine/pvemanagerlib.js" "$WORK/pvemanagerlib.js"; then
    ok "apply left pvemanagerlib.js byte for byte alone"
else
    bad "apply left pvemanagerlib.js byte for byte alone"
fi

# ── revert ──────────────────────────────────────────────────────────────────
check "revert succeeds" bash "$HOOKS" revert --quiet

for f in index.html.tpl pvemanagerlib.js "${PERL_FILES[@]}"; do
    if cmp -s "$WORK/pristine/$f" "$WORK/$f"; then
        ok "revert restored $f byte for byte"
    else
        bad "revert restored $f byte for byte"
    fi
done

if bash "$HOOKS" status >/dev/null 2>&1; then
    bad "status reports failure once unhooked"
else
    ok "status reports failure once unhooked"
fi

# ── a Perl file that no longer compiles is put back, not left broken ────────
#
# The revert removes our line and then checks the file still compiles, because a
# pvedaemon that does not is a Proxmox API that will not start. What makes the
# check worth having is that it acts: it puts the copy taken at apply time back.
bash "$HOOKS" apply --quiet >/dev/null 2>&1

# Something else breaks the file after we hooked it - a half-finished edit, a
# truncated write. Removing our line does not fix that, and leaving it is the
# one outcome the script must not produce.
echo 'this is not perl(' >> "$WORK/pvedaemon"
if perl -Tc "$WORK/pvedaemon" >/dev/null 2>&1; then
    bad "the fixture is actually broken before the revert"
else
    ok "the fixture is actually broken before the revert"
fi

bash "$HOOKS" revert --quiet >/dev/null 2>&1 || true

check "the reverted pvedaemon compiles again" perl -Tc "$WORK/pvedaemon"
if cmp -s "$WORK/pristine/pvedaemon" "$WORK/pvedaemon"; then
    ok "because the copy taken at apply time was put back"
else
    bad "because the copy taken at apply time was put back"
fi

# ── a file the hook does not recognise is left alone ────────────────────────
cat > "$WORK/stranger" <<'PERL'
#!/usr/bin/perl -T
use strict;
use warnings;
print "nothing to anchor to\n";
PERL
cp "$WORK/stranger" "$WORK/stranger.orig"

if PVEUM_PERL_TARGETS="$WORK/stranger" bash "$HOOKS" apply --quiet >/dev/null 2>&1; then
    bad "apply fails when the anchor is missing"
else
    ok "apply fails when the anchor is missing"
fi

if cmp -s "$WORK/stranger.orig" "$WORK/stranger"; then
    ok "and leaves the file untouched"
else
    bad "and leaves the file untouched"
fi

# ── packaging: the maintainer scripts must keep the timer's books straight ──
#
# `systemctl disable` in prerm removes the symlink behind deb-systemd-helper's
# back, and the next install reads that as "the admin turned this off" - so the
# timer never comes back and scheduled updates silently stop for ever. Measured
# on the test node before this guard existed. A full dpkg cycle needs a Proxmox
# box, so what is checked here is the shape of the scripts.
if grep -Eq '^[^#]*systemctl[[:space:]]+disable' "$REPO_ROOT/packaging/debian/prerm"; then
    bad "prerm stops the timer instead of disabling it"
else
    ok "prerm stops the timer instead of disabling it"
fi

if grep -q 'deb-systemd-helper purge' "$REPO_ROOT/packaging/debian/postrm"; then
    ok "purge drops the helper state, so a later install starts clean"
else
    bad "purge drops the helper state, so a later install starts clean"
fi

if grep -q 'deb-systemd-helper mask' "$REPO_ROOT/packaging/debian/postrm"; then
    ok "remove masks the timer rather than forgetting it was enabled"
else
    bad "remove masks the timer rather than forgetting it was enabled"
fi

echo
if [ "$failures" = "0" ]; then
    echo ":: $checks checks, all green"
else
    echo "!! $checks checks, $failures failed"
    exit 1
fi
