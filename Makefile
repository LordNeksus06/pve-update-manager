# pve-update-manager
#
#   make check     shellcheck, perl compile check, javascript syntax check
#   make test      the test suite (hook script behaviour against fixtures)
#   make install   staged install, used by packaging/build-deb.sh
#   make deb       build the .deb into deb-out/

PREFIX ?= /usr
DESTDIR ?=

PKG := pve-update-manager

PERLDIR := $(DESTDIR)$(PREFIX)/share/perl5/PVE/UpdateManager
JSDIR := $(DESTDIR)$(PREFIX)/share/pve-manager/js
SBINDIR := $(DESTDIR)$(PREFIX)/sbin
UNITDIR := $(DESTDIR)$(PREFIX)/lib/systemd/system
DOCDIR := $(DESTDIR)$(PREFIX)/share/doc/$(PKG)

PERL_MODULES := $(wildcard perl/PVE/UpdateManager/*.pm)
# github-mirror.sh through $(wildcard ...) on purpose: it is the publishing tool
# and does not go out with the published tree, so on a checkout that does not
# have it shellcheck must not be handed a path that is not there.
SHELL_SCRIPTS := tools/pve-update-manager-hooks $(wildcard tools/github-mirror.sh) \
                 packaging/build-deb.sh tests/run-tests.sh \
                 packaging/debian/postinst packaging/debian/prerm packaging/debian/postrm
PERL_SCRIPTS := tools/pve-update-manager-schedule
# Every .js under tests/, not only the *.test.js the suite runs: harness.js is
# shared by all of them and a syntax error in it would fail every test at once
# with a message about the wrong file.
JS_TESTS := $(wildcard tests/js/*.js)

.PHONY: all check test install deb clean version

all: check

version:
	@bash version.sh

# ── Static checks ───────────────────────────────────────────────────────────
#
# The Perl modules are compiled against stubs in tests/stubs, not against a real
# Proxmox: `perl -c` runs BEGIN/use but not the module body, so a stub package
# per PVE module is enough to catch a syntax error or a missing import - and it
# means the check runs in CI, where no Proxmox exists.
check:
	@echo ":: shellcheck"
	@shellcheck $(SHELL_SCRIPTS)
	@echo ":: perl -c (against tests/stubs)"
	@for m in $(PERL_MODULES) $(PERL_SCRIPTS); do \
		perl -I tests/stubs -I perl -c "$$m" || exit 1; \
	done
	@echo ":: javascript syntax"
	@for j in js/pve-update-manager.js $(JS_TESTS); do \
		node --check "$$j" || exit 1; \
	done
	@echo ":: OK"

test: check
	@bash tests/run-tests.sh

# ── Install ─────────────────────────────────────────────────────────────────
install:
	install -d $(PERLDIR)
	install -m 0644 $(PERL_MODULES) $(PERLDIR)
	install -d $(JSDIR)
	install -m 0644 js/pve-update-manager.js $(JSDIR)
	install -d $(SBINDIR)
	install -m 0755 tools/pve-update-manager-hooks $(SBINDIR)/pve-update-manager-hooks
	install -m 0755 tools/pve-update-manager-schedule $(SBINDIR)/pve-update-manager-schedule
	install -d $(UNITDIR)
	install -m 0644 packaging/systemd/pve-update-manager.service $(UNITDIR)
	install -m 0644 packaging/systemd/pve-update-manager.timer $(UNITDIR)
	install -d $(DOCDIR)
	install -m 0644 README.md $(DOCDIR)
	install -m 0644 LICENSE $(DOCDIR)

deb:
	bash packaging/build-deb.sh

clean:
	rm -rf deb-out
