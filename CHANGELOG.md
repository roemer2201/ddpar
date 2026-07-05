# Changelog

## [Unreleased] – branch claude/ddpar-open-items-dawpvl (Clone-Checksummen + komprimierter Remote-Transfer)

### Hinzugefügt
- **Clone-Modus `-s`:** erzeugt lokale `.sha256`-Dateien und eine
  Metadatendatei am Basis-Pfad aus `-n` (Default: Basename der Eingabe im
  aktuellen Verzeichnis). Damit ist ein Clone anschließend mit
  `ddpar-check.sh -b BASE -d ZIEL` prüfbar, ohne die Quelle erneut zu lesen.
  `-n` darf im Clone-Modus ein Pfad sein (im Backup-Modus weiterhin ein
  reiner Name)
- **Komprimierter Remote-Transfer (Backup):** `-r n -c` komprimiert lokal und
  überträgt die `.gz`-Bytes (bandbreitensparend); `-r c` überträgt Rohdaten
  und komprimiert auf der Remote-Maschine (CPU-Entlastung lokal). `-r c`
  impliziert `-c`. `COMPRESSION`/`COMPRESSION_LEVEL` stehen jetzt auch bei
  Remote-Backups in den Metadaten
- **Komprimierter Remote-Restore:** komprimierte Backups werden über die
  Metadaten erkannt; `-r n` überträgt die `.gz`-Bytes und entpackt lokal,
  `-r c` entpackt auf dem Remote-Host und überträgt Rohdaten
- **Komprimierter Clone-Transfer:** Remote-Clone mit `-c` packt lokal und
  entpackt auf der Remote-Seite vor dem Schreiben ins Ziel
- **ddpar-check.sh:** Remote-Checks unterstützen komprimierte Backups
  (`gzip -dc | sha256sum` per SSH); Ablehnung komprimierter Backups entfernt

### Geändert
- `-r`-Modi werden in `REMOTE_MODE` gespeichert; ungültige Modi führen zu
  Exit 1, `l` warnt weiterhin und fällt auf `n` zurück
- Lokaler Clone mit `-c` warnt und ignoriert die Kompression (das Ziel ist
  ein Blockgerät/eine Datei in Originalgröße — es gibt nichts zu speichern)
- Remote-Backup mit `-s` warnt explizit, dass keine `.sha256`-Dateien auf dem
  Remote-Host entstehen (Prüfung via `ddpar-check.sh -r` braucht sie nicht)

## [Unreleased] – branch claude/ddpar-open-items-dawpvl (Quick Wins aus der To-Do-Liste)

### Hinzugefügt
- **ddpar.sh `-n NAME`:** eigener Basisname für die Backup-Dateien (Default
  weiterhin der Basename der Eingabe); `FILE_NAME` in den Metadaten trägt den
  tatsächlich verwendeten Basisnamen, `INPUT_FILE_NAME` weiterhin die Quelle
- **ddpar-restore.sh `-P`:** überspringt die Vorab-Reservierung des Zielplatzes
  (`fallocate`); fehlt `fallocate` auf dem System, wird nur gewarnt statt
  abgebrochen
- **Rechte-Vorabprüfung:** alle drei Skripte prüfen Lese- (Quelle, Teil-Dateien,
  Metadaten) und Schreibrechte (Ziel bzw. Elternverzeichnis, bei Remote über
  SSH) vor dem Start der parallelen Jobs — statt erst mitten im Lauf zu
  scheitern
- **ddpar-check.sh:** prüft vor einem Backup-/Restore-Check, ob die
  `.sha256`-Dateien existieren, und bricht mit klarer Meldung ab, wenn das
  Backup ohne `-s` erstellt wurde

### Geändert
- **Verfügbarkeits-Checks verdrahtet:** `check_commands_availability` bricht
  bei fehlenden Befehlen jetzt ab (Ergebnis wurde bisher ignoriert) und wird
  auch im Remote-Modus ausgeführt; `check_remote_commands_availability`
  (bisher toter Code, 🛑 in der README-Matrix) läuft nach dem SSH-Aufbau und
  prüft die benötigten Befehle auf dem Remote-Host. `nc` wird lokal nur noch
  im Remote-Modus verlangt
- **ddpar-restore.sh:** Restore in ein Verzeichnis hängt den Basename aus den
  Metadaten (`FILE_NAME`) an statt des `-i`-Arguments; fehlender Schreibzugriff
  auf das Zielverzeichnis führt zu Exit 1 (bisher nur Meldung + Weiterlauf)
- **TESTING.md:** veralteten Hinweis „Clone-Check nicht implementiert“
  entfernt und Abschnitt 3.3 (Clone-Check Source ↔ Destination) ergänzt

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
