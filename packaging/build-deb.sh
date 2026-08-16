#!/usr/bin/env bash
# Builds the pve-update-manager .deb into deb-out/.
#
#   packaging/build-deb.sh [VERSION]
#
# Architecture: all - the package is Perl, JavaScript and one shell script, so
# one .deb serves every arch. Run it from anywhere; it locates the repo itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(bash version.sh)}"
[ -n "$VERSION" ] || { echo "FATAL: empty version"; exit 1; }

PKG="pve-update-manager"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

make install DESTDIR="$STAGE" PREFIX=/usr >/dev/null

mkdir -p "$STAGE/DEBIAN"
sed "s|@VERSION@|$VERSION|g" packaging/debian/control.in > "$STAGE/DEBIAN/control"

install -m 0755 packaging/debian/postinst "$STAGE/DEBIAN/postinst"
install -m 0755 packaging/debian/prerm "$STAGE/DEBIAN/prerm"
install -m 0755 packaging/debian/postrm "$STAGE/DEBIAN/postrm"
install -m 0644 packaging/debian/triggers "$STAGE/DEBIAN/triggers"

# dpkg refuses to build when directories carry odd modes.
find "$STAGE" -type d -exec chmod 0755 {} +

# Wipe deb-out first: a leftover .deb from an earlier version would still match
# the deb-out/*.deb glob that CI uploads, and a stale package could get shipped
# alongside (or instead of) this one.
rm -rf deb-out
mkdir -p deb-out
DEB="deb-out/${PKG}_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"

echo ":: built $DEB"
dpkg-deb --contents "$DEB"
