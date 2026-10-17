SCRIPTS := ddpar.sh ddpar-restore.sh ddpar-check.sh ddpar-common.sh testing-docker/*.sh completions/ddpar

.PHONY: lint lint-gate test test-verbose test-log test-integration check install-deps install-build-deps deb help

help:
	@echo "Verfügbare Targets:"
	@echo "  make lint              ShellCheck auf alle .sh-Dateien ausführen (voller Report)"
	@echo "  make lint-gate         ShellCheck nur auf echte Fehler prüfen (CI-Gate, severity=error)"
	@echo "  make test              bats-Testsuite ausführen (Integrationstests werden ohne"
	@echo "                         root/SSH automatisch übersprungen)"
	@echo "  make test-verbose      wie test, gibt Kommandos + Output live aus (DDPAR_VERBOSE=1)"
	@echo "  make test-log          wie test, schreibt Kommandos + Output nach /tmp/ddpar-test.log"
	@echo "  make test-integration  Nur Blockgerät- (losetup) und Remote-Tests (SSH/netcat)"
	@echo "  make check             lint + test (vollständiger Lint-Report und Tests)"
	@echo "  make install-deps      ShellCheck, bats und netcat installieren (Debian/Ubuntu)"
	@echo "  make install-build-deps  Debian-Paketbau-Abhaengigkeiten installieren"
	@echo "  make deb               Debian-Paket im uebergeordneten Verzeichnis bauen"

lint:
	@command -v shellcheck > /dev/null 2>&1 || \
		{ echo "shellcheck nicht gefunden. Installation: make install-deps"; exit 1; }
	shellcheck -x $(SCRIPTS)

# Build-relevantes Gate: nur echte Fehler (severity=error) lassen die CI scheitern.
# Schwelle kann später auf "warning"/"style" verschärft werden, sobald die im
# vollen Report (make lint) gelisteten Punkte abgearbeitet sind.
lint-gate:
	@command -v shellcheck > /dev/null 2>&1 || \
		{ echo "shellcheck nicht gefunden. Installation: make install-deps"; exit 1; }
	shellcheck -x --severity=error $(SCRIPTS)

test:
	@command -v bats > /dev/null 2>&1 || \
		{ echo "bats nicht gefunden. Installation: make install-deps"; exit 1; }
	bats tests/

test-verbose:
	@command -v bats > /dev/null 2>&1 || \
		{ echo "bats nicht gefunden. Installation: make install-deps"; exit 1; }
	DDPAR_VERBOSE=1 bats tests/

test-log:
	@command -v bats > /dev/null 2>&1 || \
		{ echo "bats nicht gefunden. Installation: make install-deps"; exit 1; }
	DDPAR_LOG=/tmp/ddpar-test.log bats tests/
	@echo "Log geschrieben nach /tmp/ddpar-test.log"

# Blockgerät- und Remote-Tests separat (benötigen root bzw. SSH-zu-Testhost).
test-integration:
	@command -v bats > /dev/null 2>&1 || \
		{ echo "bats nicht gefunden. Installation: make install-deps"; exit 1; }
	bats tests/blockdev.bats tests/remote.bats

check: lint test

install-deps:
	sudo apt-get install -y shellcheck bats bash-completion python3 netcat-openbsd

# Build as the calling user; debian/rules declares Rules-Requires-Root: no.
deb:
	dpkg-buildpackage -us -uc -b

install-build-deps:
	sudo apt-get install -y build-essential debhelper dpkg-dev make bats bash-completion python3 shellcheck file mawk
