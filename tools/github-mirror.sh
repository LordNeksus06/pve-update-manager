#!/usr/bin/env bash
# Fills the public GitHub mirror from this repository.
#
#   tools/github-mirror.sh check          only verify the file lists (used by the test suite)
#   tools/github-mirror.sh sync [DIR]     sync + commit into the mirror at DIR
#
# Why a mirror and not a push:
#
# This repository holds two things that must not be published - `.gitea/`, which
# is the internal pipeline with its registry paths and token names, and
# CLAUDE.md, which describes how the project is worked on. They live in every
# commit, so pushing a branch publishes them; that happened once and cost a leak
# that a force-push cannot undo. A mirror inverts the default: nothing is
# published unless it is named below.
#
# Symlinks were the obvious idea and do not work. Git stores a symlink AS a
# symlink - the blob is the target path, not the file - so a mirror built from
# links would publish broken pointers into somebody's home directory.
#
# The lists are exhaustive on purpose. Anything at the top level that is in
# neither of them makes this script REFUSE, which is what turns "somebody added
# a file" from a silent decision into a deliberate one. `check` runs on every
# `make test`, so the refusal arrives while the file is being added rather than
# on the day it is published.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Everything the public side needs to build, test and package the addon.
PUBLISHED=(
    .github
    .gitignore
    LICENSE
    Makefile
    VERSION
    docs
    js
    packaging
    perl
    tests
    tools
    version.sh
)

# Everything that stays here, and why:
#
#   .gitea      the internal pipeline
#   CLAUDE.md   how the project is worked on, not what it does
#   README.md   describes that pipeline and the apt registry in prose; the
#               mirror carries .github/README.md under this name instead, which
#               also keeps `make install` working - the packaging installs a
#               README.md and would fail without one
#   deb-out     build output
WITHHELD=(
    .gitea
    CLAUDE.md
    README.md
    deb-out
)

die() { echo "github-mirror: $*" >&2; exit 1; }

# Every top-level entry git tracks has to be classified. A file that is in
# neither list is not "probably fine", it is an unanswered question.
check_lists() {
    local unknown=() entry
    local tracked
    tracked="$(git ls-files | cut -d/ -f1 | sort -u)"

    for entry in $tracked; do
        if printf '%s\n' "${PUBLISHED[@]}" | grep -qxF -- "$entry"; then continue; fi
        if printf '%s\n' "${WITHHELD[@]}" | grep -qxF -- "$entry"; then continue; fi
        unknown+=("$entry")
    done

    if [ ${#unknown[@]} -gt 0 ]; then
        echo "github-mirror: these are tracked but classified neither way:" >&2
        printf '  %s\n' "${unknown[@]}" >&2
        echo "Add each to PUBLISHED or WITHHELD in tools/github-mirror.sh." >&2
        return 1
    fi

    # A path that is published AND withheld would resolve by whichever loop runs
    # first, which is not a thing to leave to reading order.
    for entry in "${WITHHELD[@]}"; do
        if printf '%s\n' "${PUBLISHED[@]}" | grep -qxF -- "$entry"; then
            die "'$entry' is in both lists"
        fi
    done

    return 0
}

# What must never appear in a published file. The maintainer address is the one
# deliberate exception - it is what a Debian package is required to carry - and
# the commit authorship carries the owner's address by a decision taken when the
# project was published.
leak_scan() {
    local dir="$1" hits
    hits="$(grep -rIEn '192\.168\.|(^|[^0-9.])10\.[0-9]+\.[0-9]+\.[0-9]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$dir" \
        --exclude-dir=.git 2>/dev/null \
        | grep -vE 'noreply@anthropic\.com|jilkelukas@gmail\.com|example\.(com|org)|@[A-Za-z0-9.-]*\{|\$\{' || true)"

    [ -z "$hits" ] && return 0

    echo "github-mirror: refusing to publish - possible personal data:" >&2
    echo "$hits" | head -20 >&2
    return 1
}

sync_mirror() {
    local mirror="${1:-$REPO_ROOT/../pve-update-manager-github}"
    local ver source_commit

    [ -d "$mirror/.git" ] || die "'$mirror' is not a git checkout - clone the GitHub repo there first"

    check_lists || exit 1

    # From the COMMIT, not the working tree: publishing an uncommitted edit puts
    # something on GitHub that exists nowhere else.
    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "the working tree has uncommitted changes - commit them first"
    fi

    ver="$(bash "$REPO_ROOT/version.sh")"
    source_commit="$(git rev-parse HEAD)"

    local staging
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' RETURN

    git archive HEAD | tar -x -C "$staging"
    local entry
    for entry in "${WITHHELD[@]}"; do
        rm -rf "${staging:?}/$entry"
    done

    # The public README takes the place of the internal one.
    [ -f "$staging/.github/README.md" ] || die ".github/README.md is missing"
    cp "$staging/.github/README.md" "$staging/README.md"

    # Same version on both forges, which is the whole point of pinning it: over
    # here the patch number counts commits since VERSION last changed, and the
    # mirror has a different history, so the same source would otherwise be
    # published under two different numbers.
    cat > "$staging/version.sh" <<EOF
#!/usr/bin/env bash
# Prints the project version.
#
# Pinned when this mirror was filled, so the package built here carries the same
# version as the one built from the source repository. Do not edit by hand -
# tools/github-mirror.sh rewrites it on every sync.
set -euo pipefail
echo "$ver"
EOF
    chmod 0755 "$staging/version.sh"

    leak_scan "$staging" || exit 1

    # Replace, do not merge: a file deleted here has to disappear there too.
    find "$mirror" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -a "$staging/." "$mirror/"

    git -C "$mirror" add -A
    if git -C "$mirror" diff --cached --quiet; then
        echo "github-mirror: the mirror already matches $ver ($source_commit) - nothing to commit"
        return 0
    fi

    git -C "$mirror" commit -q -m "pve-update-manager $ver"

    echo "github-mirror: committed $ver into $mirror"
    echo "  source: $source_commit"
    echo
    echo "Push it - release FIRST, and wait for its pipeline before pushing main."
    echo "Whichever ref reaches 'gh release create' first decides whether the one"
    echo "tag is stable or a prerelease, and the other run then finds it taken."
    echo "  git -C $mirror push origin HEAD:release"
    echo "  git -C $mirror push origin HEAD:main"
}

case "${1:-}" in
    check) check_lists ;;
    sync) shift; sync_mirror "${1:-}" ;;
    *) die "usage: $0 check | sync [MIRROR_DIR]" ;;
esac
