# Changelog

## [Unreleased] – branch claude/network-multi-nic-features-4om7f4

### Hinzugefügt
- **Multi-NIC Stufe 2 (Link-Auswahl):** `exchange_remote_nic_info` fragt
  über die SSH-Verbindung Anzahl, Geschwindigkeit und IPv4-Adressen der
  Remote-NICs ab (POSIX-kompatibles Remote-Kommando, gleiche sysfs-Logik
  wie lokal); `select_transfer_link` wählt das Paar aus erreichbarer
  lokaler NIC und Remote-IP mit der höchsten effektiven Geschwindigkeit
  min(lokal, remote) — bei Gleichstand (z.B. unbekannte Geschwindigkeit)
  wird die jeweils schnellere NIC zuerst probiert (stabiler Sort). Der
  netcat-Datenkanal (Clone und Backup) verbindet sich über
  `remote_transfer_addr` mit der gewählten Remote-IP; ohne erfolgreiche
  Auswahl weiterhin mit der SSH-Adresse aus `-R` (Standard-Routing).
  Stufe 3 (Verteilung auf mehrere Links) folgt
- **Multi-NIC Stufe 1 (informativ):** `detect_local_nics` ermittelt alle
  lokalen Interfaces mit aktivem Link samt Geschwindigkeit (sysfs) und
  primärer IPv4-Adresse, absteigend nach Geschwindigkeit sortiert;
  `check_nic_remote_reachability` prüft von der schnellsten NIC abwärts, ob
  das Remote-Ziel erreichbar ist (`ping -I`, Fallback: TCP-Probe auf den
  SSH-Port mit Source-IP-Binding) und liefert `FASTEST_REACHABLE_NIC`.
  Läuft bei Remote-Operationen automatisch vor dem SSH-Aufbau; die
  Übertragung nutzt weiterhin das Standard-Routing (Link-Auswahl folgt in
  Stufe 2)
- Source-Guard `DDPAR_SOURCE_ONLY=1`: `ddpar.sh` lässt sich für Unit-Tests
  sourcen, ohne dass der Hauptteil läuft; `DDPAR_SYSFS_NET` macht den
  sysfs-Pfad für Tests überschreibbar
- `tests/nics.bats`: Unit-Tests für beide Funktionen (Fake-sysfs-Baum,
  `ping`/`nc`-Stubs); TESTING.md-Kapitel 5 mit manuellen Multi-NIC-Szenarien
- README: Multi-NIC-Roadmap (4 Stufen) im To Do und Funktionsstatus-Abschnitt
  „Remote — Multi-NIC"

## [Unreleased] – branch claude/project-improvement-review-fe3jux (konsolidierter Stack)

### Hinzugefügt
- **Beliebige Eingabegrößen:** `size_calculation` rundet `SPLIT_SIZE` auf ein
  Vielfaches der Blockgröße ab statt bei unteilbaren Größen abzubrechen; der
  Rest wird vom letzten Teil übertragen (`part_bytes`, dd-Flags
  `count_bytes`/`skip_bytes`/`seek_bytes`). Damit funktionieren echte
  Plattengrößen ohne manuelles Austarieren von `-j`/`-b`
- **Fehlerbehandlung paralleler Jobs:** `set -o pipefail` in allen Skripten;
  Teil-Jobs werden mit PID registriert (`register_job`/`wait_for_jobs`), ihre
  Exit-Codes einzeln eingesammelt und aggregiert — ein fehlgeschlagener Teil
  führt zu Exit-Code `!= 0` statt stillem Erfolg
- **Signal-Cleanup:** `trap INT/TERM` beendet laufende Teil-Prozesse, räumt
  remote gestartete nc-Listener ab und schließt die SSH-Verbindung
- **ddpar-check.sh:** endet bei Abweichungen mit Exit-Code `!= 0`
  (skripting-/CI-tauglich); liest `INPUT_SIZE` aus den Metadaten
- Tests für nicht glatt teilbare Größen (Backup→Check→Restore und Clone)

### Geändert
- **Refactoring:** gemeinsame Teil-Schleife `run_clone_parts` für
  `clone_file`/`clone_block`; `setup_remote_listener` (vormals
  `remote_backup_commands`) wird von Clone- und Backup-Modus genutzt;
  Backup-Modus in Funktion `backup_mode` extrahiert
- **eval entfernt:** dd/gzip/tee-Pipelines werden direkt gestartet (Bash-Arrays
  bzw. explizite Verzweigungen); Pfade mit Leerzeichen/Metazeichen sind
  ungefährlich. Remote-Befehle laufen weiterhin als String über SSH (dort
  gequotet)
- **Sicherheit:** `StrictHostKeyChecking=accept-new` statt `no` (geänderte
  Host-Keys führen zum Abbruch); `sshpass -e` statt `-p` (Passwort nicht mehr
  in der Prozessliste); nicht implementierte Remote-Modi `l`/`c` erzeugen eine
  Warnung statt still auf unverschlüsselt zurückzufallen
- Clone-Schreibseite mit `conv=notrunc` (kein Truncate-Wettlauf paralleler
  Writer); `mkdir`-Aufruf in `clone_file` expandiert `${OUTPUT}` jetzt korrekt
- README vollständig überarbeitet (Schnellstart, Voraussetzungen,
  Sicherheitshinweise, Exit-Codes, aktualisierte Funktionsmatrix)

## [Unreleased] – branch claude/great-cori-29qjug (auf testing-docker aufbauend)

### Hinzugefügt
- Automatisierte Testpipeline: GitHub-Actions-Workflow (`.github/workflows/ci.yml`)
  mit ShellCheck-Lint (Gate bei `severity=error`, voller Report informativ),
  schnellem bats-Job (CLI + Datei-Roundtrip) und einem Integration-Job
  (Blockgeräte + Remote, mit SSH-zu-localhost-Setup)
- bats-Tests unter `tests/`:
  - `cli.bats` – CLI-Verhalten
  - `roundtrip.bats` – Datei-basierter `backup → check → restore`-Roundtrip
    inkl. komprimiert und Negativ-Probe
  - `blockdev.bats` – Blockgerät-Clone/Backup/Restore/Check über Loop-Devices
    (`losetup`, root; skippt sonst)
  - `remote.bats` – Remote-Clone/Backup/Restore über SSH+netcat (Modus `n`,
    Testhost via `DDPAR_REMOTE_TEST_HOST`, default `localhost`; skippt ohne SSH)
- `Makefile`-Targets `test`, `test-integration`, `lint-gate` und `check`
- `testing-docker/run-remote-tests.sh`: manuelles Orchestrierungs-Skript, das die
  zwei Container startet, die Remote-Szenarien (Clone/Backup/Restore/Check über
  SSH+netcat) `source` → `target` durchführt, die Integrität per SHA256 prüft und
  einen Exitcode liefert (nicht Teil der CI)
- **ddpar-restore.sh:** Flag `-y` zum Überspringen der interaktiven
  Sicherheitsabfrage (ermöglicht nicht-interaktive/automatisierte Restores;
  Verhalten ohne Flag unverändert)

### Behoben
- **ddpar.sh:** Lokaler Blockgerät-Clone scheiterte, weil `execute_command` den
  Befehl lokal unquotiert (`${command}`) ausführte und so die in
  `output_analysis` enthaltenen Quotes (`file -b "${OUTPUT}"`) literal an `file`
  weitergab → Typ-Erkennung des Zielgeräts schlug fehl. Lokale Ausführung nutzt
  nun `eval "${command}"` (analog zur Remote-Seite und zu `eval "${FULL_CMD}"`)

## [Unreleased] – branch claude/review-ddpar-bugs-bc3la

### Hinzugefügt
- `TESTING.md` mit Beispielkommandos für alle Übertragungsvarianten

### Behoben
- **ddpar.sh:** `${}` Bad-Substitution in `size_calculation()` — der Hinweis auf
  die nächsthöhere Thread-Zahl wurde nie ausgegeben, stattdessen ein Shell-Fehler
  produziert (`2a08be9`)
- **ddpar-restore.sh:** `grep "COMPRESSION"` matchte auch `COMPRESSION_LEVEL=`
  und `grep "FILE_NAME"` matchte auch `INPUT_FILE_NAME=`; Muster mit `^`-Anker
  verankert (`266f50d`)
- **ddpar.sh:** `ss -tln` vs. `ss -tuln` Inkonsistenz — alle Port-Prüfungen
  nutzen jetzt einheitlich `ss -tln` (nur TCP, da Netcat TCP verwendet) (`209833e`)
- **ddpar.sh:** Port-Substring-Matching — `grep -q ":PORT"` matchte z.B.
  Port `100` in `:10000`; ersetzt durch `grep -qE ":PORT[^0-9]"` (`16ea99e`)
- **ddpar.sh:** Unquotierte Pfadvariablen `${INPUT}` und `${OUTPUT}` in `file`,
  `stat`, `blockdev`-Aufrufen; Tippfehler `${INPUT_SIZE=}` → `${INPUT_SIZE}`
  (`b617f2a`)
- **ddpar.sh:** Fehlendes `-e` bei `echo` im Backup-Modus — ANSI-Farbcodes
  wurden als Klartext ausgegeben (`124a400`)
- **ddpar-restore.sh:** `fallocate` wurde innerhalb der Job-Schleife für jeden
  Job aufgerufen statt einmal vor der Schleife (`42b6ab0`)
- **ddpar.sh:** `RANDOM % 55001` ist identisch zu `RANDOM` da `RANDOM` max.
  32767 liefert; vereinfacht zu `REMOTE_PORT=$(( RANDOM + 10000 ))`, Kommentar
  korrigiert auf effektiven Bereich 10000–42767 (`05c4fb3`)

---

## [Merged] – PR #1 (branch claude/review-ddpar-bugs-bc3la → main)

### Behoben
- **ddpar.sh:** Off-by-One in Post-Loop-Bedingung — Erfolg beim letzten Versuch
  (ATTEMPT == MAX_ATTEMPTS) wurde fälschlich als Fehler gewertet (`-ge` → `-gt`)
  (`075de3c`)
- **ddpar.sh, ddpar-restore.sh:** Unquotiertes `eval ${FULL_CMD}` — durch
  Word-Splitting und Glob-Expansion konnte es zu unvorhersehbarer Befehlsausführung
  kommen; ersetzt durch `eval "${FULL_CMD}"` (`927b3a8`)
- **ddpar-check.sh:** `[ ! -z $SOURCE ]` und `[ ! -z $DESTINATION ]` ohne Quotes
  — scheitert bei leeren Variablen; Quotes ergänzt (`bf1a62f`)
- **ddpar-restore.sh:** Größenprüfung verglich `BLOCKSIZEBYTES` (~1 MB) mit
  `OUTPUT_SIZE` statt `INPUT_SIZE` (Backup-Größe) — sinnloser Vergleich, der nie
  anschlug (`57b6fce`)
- **ddpar.sh:** Unquotiertes `[ -z ${REMOTE_PORT} ]` — Quotes ergänzt (`323c254`)
