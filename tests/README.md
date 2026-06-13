# Automatisierte Tests

Automatisierte Tests für ddpar, ausgeführt via [bats-core](https://github.com/bats-core/bats-core)
und in der GitHub-Actions-Pipeline (`.github/workflows/ci.yml`).

Dies ergänzt das manuelle/szenariobasierte Testkonzept aus [`../TESTING.md`](../TESTING.md)
und dem Docker-Harness unter [`../testing-docker/`](../testing-docker/): bats deckt den
schnellen, automatisierten Kernablauf ohne Root/Blockgeräte ab, das Docker-Harness die
Remote- (SSH/netcat) und Blockgerät-Szenarien.

## Voraussetzungen

```sh
make install-deps        # shellcheck, bats, netcat-openbsd (Debian/Ubuntu)
```

## Ausführen

```sh
make test        # bats-Testsuite
make lint        # ShellCheck, voller Report (alle Schweregrade)
make lint-gate   # ShellCheck, nur build-relevante Fehler (CI-Gate)
make check       # lint-gate + test (alles, was die CI prüft)
```

## Inhalt

- `cli.bats` – Verhalten der Kommandozeile: Hilfe (`-h`), `-y`-Flag,
  fehlende/ungültige Parameter.
- `roundtrip.bats` – End-to-End auf Datei-Basis (kein sudo nötig):
  `backup` → `check` → `restore`, Vergleich Original vs. Wiederhergestellt,
  jeweils komprimiert und unkomprimiert, plus eine Negativ-Probe (manipuliertes
  Backup wird von `check` als `FAILED` erkannt).
- `helpers.bash` – gemeinsames `setup`/`teardown` (isoliertes Temp-Verzeichnis)
  und `make_testfile`.

## Nicht hier abgedeckt (siehe Docker-Harness / TESTING.md)

- Klonen/Wiederherstellen auf echte **Blockgeräte** (Loop-Devices via `losetup`,
  benötigt Root-Rechte).
- **Remote**-Pfade über SSH/netcat (zwei-Host-Setup via `testing-docker/`).
- Unit-Tests einzelner Funktionen (z. B. `size_calculation`); dafür müsste der
  Hauptteil der Skripte sourcebar gekapselt werden.
