SCRIPTS := ddpar.sh ddpar-restore.sh ddpar-check.sh

.PHONY: lint install-deps help

help:
	@echo "Verfügbare Targets:"
	@echo "  make lint          ShellCheck auf alle .sh-Dateien ausführen"
	@echo "  make install-deps  ShellCheck installieren (Debian/Ubuntu)"

lint:
	@command -v shellcheck > /dev/null 2>&1 || \
		{ echo "shellcheck nicht gefunden. Installation: make install-deps"; exit 1; }
	shellcheck $(SCRIPTS)

install-deps:
	sudo apt-get install -y shellcheck
