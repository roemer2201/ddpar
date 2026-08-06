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
make test              # bats-Testsuite (Integrationstests skippen ohne root/SSH)
make test-integration  # nur Blockgerät- + Remote-Tests (root bzw. SSH nötig)
make lint              # ShellCheck, voller Report (alle Schweregrade)
make lint-gate         # ShellCheck, nur build-relevante Fehler (CI-Gate)
make check             # lint-gate + test (was der schnelle CI-Job prüft)
```

Tests, deren Voraussetzungen fehlen, werden automatisch übersprungen (`skip`),
sodass `make test` auch ohne root/SSH grün bleibt.

## Inhalt

- `cli.bats` – Verhalten der Kommandozeile: Hilfe (`-h`), `-y`-Flag,
  fehlende/ungültige Parameter.
- `roundtrip.bats` – End-to-End auf Datei-Basis (kein sudo nötig):
  `backup` → `check` → `restore`, Vergleich Original vs. Wiederhergestellt,
  jeweils komprimiert und unkomprimiert, plus eine Negativ-Probe (manipuliertes
  Backup wird von `check` als `FAILED` erkannt).
- `blockdev.bats` – **Blockgeräte** über Loop-Devices (`losetup`, benötigt root):
  lokaler Clone Gerät→Gerät, Backup→Restore Gerät und `check` gegen die Quelle.
  Ohne root werden die Tests übersprungen.
- `remote.bats` – **Remote** über SSH+netcat, Testhost standardmäßig
  `localhost` (über `DDPAR_REMOTE_TEST_HOST` überschreibbar):
  Remote-Clone (Datei), Remote-Backup→Remote-Restore (Datei) unkomprimiert
  sowie mit lokaler [De]Kompression (Modus `n` + `-c`, inkl. nicht glatt
  teilbarer Größe) und Remote-Check eines komprimierten Backups (positiv und
  negativ). Für Modus `c` (**[De]Kompression auf der Gegenseite**) zusätzlich:
  Backup→Restore, Clone mit `-c`, Check (positiv/negativ), die Warnung bei
  `-c` ohne `-r c` im Clone-Modus und die Interoperabilität der Modi (mit
  `-r c` erzeugtes Backup, Restore mit `-r n`). Ohne passwortlose
  SSH-Verbindung werden die Tests übersprungen, ohne `gzip` auf dem Testhost
  nur die `-r c`-Tests.
- `helpers.bash` – gemeinsames `setup`/`teardown` (isoliertes Temp-Verzeichnis,
  automatisches Lösen von Loop-Devices/SSH-Socket) sowie `make_testfile`,
  `loop_setup`, `require_block_support`, `require_remote_support`,
  `require_remote_gzip`.

### CI

Der schnelle `test`-Job (`make test`) läuft unprivilegiert; Blockgerät- und
Remote-Tests skippen dort. Ein dedizierter `integration`-Job richtet
SSH-zu-localhost ein und führt `tests/blockdev.bats` + `tests/remote.bats` als
root aus (siehe `.github/workflows/ci.yml`).

## Nicht hier abgedeckt

- Remote-Pfade mit **echtem Zwei-Host-Setup**, Remote-Blockgeräte sowie der
  noch nicht implementierte Modus `l` – dafür das Docker-Harness unter
  [`../testing-docker/`](../testing-docker/) (inkl. `run-remote-tests.sh` für
  einen automatisierten Zwei-Container-Durchlauf) und die Szenarien in
  [`../TESTING.md`](../TESTING.md).
- Unit-Tests einzelner Funktionen (z. B. `size_calculation`); dafür müsste der
  Hauptteil der Skripte sourcebar gekapselt werden.
