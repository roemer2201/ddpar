# Changelog

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
