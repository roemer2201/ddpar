SCRIPTS := ddpar.sh ddpar-restore.sh ddpar-check.sh

.PHONY: lint lint-gate test test-integration check install-deps help

help:
	@echo "Verfügbare Targets:"
	@echo "  make lint              ShellCheck auf alle .sh-Dateien ausführen (voller Report)"
	@echo "  make lint-gate         ShellCheck nur auf echte Fehler prüfen (CI-Gate, severity=error)"
	@echo "  make test              bats-Testsuite ausführen (Integrationstests werden ohne"
	@echo "                         root/SSH automatisch übersprungen)"
	@echo "  make test-integration  Nur Blockgerät- (losetup) und Remote-Tests (SSH/netcat)"
	@echo "  make check             lint-gate + test (alles, was der schnelle CI-Job prüft)"
	@echo "  make install-deps      ShellCheck, bats und netcat installieren (Debian/Ubuntu)"

lint:
	@command -v shellcheck > /dev/null 2>&1 || \
		{ echo "shellcheck nicht gefunden. Installation: make install-deps"; exit 1; }
	shellcheck $(SCRIPTS)

# Build-relevantes Gate: nur echte Fehler (severity=error) lassen die CI scheitern.
# Schwelle kann später auf "warning"/"style" verschärft werden, sobald die im
# vollen Report (make lint) gelisteten Punkte abgearbeitet sind.
lint-gate:
	@command -v shellcheck > /dev/null 2>&1 || \
		{ echo "shellcheck nicht gefunden. Installation: make install-deps"; exit 1; }
	shellcheck --severity=error $(SCRIPTS)

test:
	@command -v bats > /dev/null 2>&1 || \
		{ echo "bats nicht gefunden. Installation: make install-deps"; exit 1; }
	bats tests/

# Blockgerät- und Remote-Tests separat (benötigen root bzw. SSH-zu-Testhost).
test-integration:
	@command -v bats > /dev/null 2>&1 || \
		{ echo "bats nicht gefunden. Installation: make install-deps"; exit 1; }
	bats tests/blockdev.bats tests/remote.bats

check: lint-gate test

install-deps:
	sudo apt-get install -y shellcheck bats netcat-openbsd
