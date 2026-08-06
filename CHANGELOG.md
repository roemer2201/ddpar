# Changelog

## [Unreleased] – branch claude/remote-netcat-decompression-fdxwqa (Remote netcat mit Remote-[De]Kompression)

### Hinzugefügt
- **Remote-Modus `c` (`-r c`) umgesetzt:** `gzip`/`zcat` laufen auf der
  **Gegenseite** statt lokal. Der Modus wird in allen drei Skripten ausgewertet
  (bisher nur eine „noch nicht implementiert“-Warnung):
  - **Backup (`-c -r c`):** über netcat gehen die Rohdaten, der Remote-Host
    komprimiert sie direkt in die `.gz`-Teile
    (`nc -N -l PORT | gzip -LEVEL > BASE-N.gz`). Das entlastet die lokale CPU,
    spart aber keine Bandbreite — dafür bleibt `-r n` die richtige Wahl
  - **Restore (`-r c`):** der Remote-Host packt selbst aus und sendet Rohdaten
    (`zcat BASE-N.gz | nc -N -l PORT`), lokal wird nur noch geschrieben
  - **Check (`-r c`):** `zcat … | sha256sum` läuft auf der Gegenseite, über SSH
    geht nur der Hash (Modus `n` holt weiterhin die `.gz`-Teile und packt lokal aus)
- **Kompression im Clone-Modus (`-c -r c`):** lokal wird komprimiert, die
  Gegenseite dekomprimiert vor dem Schreiben
  (`nc -N -l PORT | gzip -dc | dd of=…`). Damit ist der Clone-Transfer erstmals
  komprimiert möglich; ohne `-r c` bleibt es bei der Warnung und einem
  unkomprimierten Clone
- **`wait_for_remote_listeners`:** `ddpar.sh` wartet vor dem Schließen der
  SSH-Verbindung, bis die Remote-Empfänger fertig geschrieben haben
  (`pgrep -f "nc -N -l [P]ORT"` auf den `sh -c`-Elternprozess; die
  Zeichenklasse verhindert, dass die per SSH gestartete Shell sich selbst
  matcht). Ohne das konnte ein direkt anschließender `ddpar-check.sh` eine noch
  unvollständige Zieldatei lesen — im Modus `c` puffert dort zusätzlich `gzip`.
  Fehlt `pgrep` auf der Gegenseite, wird wie bisher nicht gewartet
- **Tests:** `tests/remote.bats` deckt Modus `c` ab (Backup→Restore inkl. nicht
  glatt teilbarer Größe, Clone mit `-c`, Check positiv/negativ, Warnung bei `-c`
  ohne `-r c`, Restore eines `-r c`-Backups mit `-r n`); `tests/cli.bats` prüft
  Hilfetext und Ablehnung ungültiger Modi; `testing-docker/run-remote-tests.sh`
  bekommt die Szenarien 5 (Backup/Restore/Check mit `-r c`) und 6 (Clone `-c -r c`)

### Geändert
- **Verfügbarkeits-Prüfungen folgen dem Modus:** `gzip` wird auf dem Remote-Host
  nur bei `-r c` verlangt, lokal beim Remote-Backup mit `-r c` dagegen nicht
  mehr; `ddpar-restore.sh`/`ddpar-check.sh` prüfen `zcat` auf der jeweils
  auspackenden Seite
- **`-r` ohne Modusangabe** funktioniert jetzt wie in der Hilfe dokumentiert
  (`-r [lnc]`) und bedeutet Modus `n`: bisher verschluckte `getopts` die
  folgende Option als Argument (`-r -R host` → Modus „-R“, Host nie gesetzt)
  bzw. ignorierte `-r` am Zeilenende samt `REMOTE=1` stillschweigend. Ein
  ungültiger Modus führt zu einer Fehlermeldung und Exit 1, `-r l` warnt
  weiterhin und fällt auf `n` zurück
- **Fehlende Optionsargumente** (z.B. `-j` ohne Zahl) brechen mit einer
  Meldung ab, statt still ignoriert zu werden
- Die `.gz`-Teile sind in beiden Modi identisch: ein mit `-r c` erzeugtes Backup
  lässt sich mit `-r n` wiederherstellen und prüfen — und umgekehrt
- Dokumentation (README-Matrix, ARCHITECTURE, TESTING, CLAUDE.md, Test-READMEs)
  auf die beiden Kompressionsvarianten umgestellt

## [Unreleased] – branch claude/remote-netcat-local-compression-z8sk5b (Remote netcat mit lokaler [De]Kompression)

### Hinzugefügt
- **Remote-Backup komprimiert (`-c` + `-r n`):** `gzip` läuft auf der lokalen
  Maschine, über netcat geht nur der komprimierte Strom, die Gegenseite schreibt
  ihn per `dd` in die `.gz`-Teile (*local compression*). Der Remote-Host benötigt
  dafür kein `gzip`. `COMPRESSION`/`COMPRESSION_LEVEL` landen jetzt auch bei
  Remote-Backups in der Metadatendatei
- **Remote-Restore komprimiert:** der Remote-Host sendet die `.gz`-Teile
  unverändert, `zcat` läuft lokal (*local decompression*). Der bisherige Abbruch
  „Remote-Restore unterstützt derzeit nur unkomprimierte Backups“ entfällt;
  erkannt wird der Fall automatisch über `COMPRESSION` aus den Metadaten
- **Remote-Check komprimierter Backups:** `ddpar-check.sh -r` holt die
  `.gz`-Teile über SSH und packt sie lokal aus; verglichen werden weiterhin die
  SHA256-Hashes der Rohdaten je Segment (unkomprimiert bleibt es beim
  `sha256sum` auf der Gegenseite, es geht nur der Hash über die Leitung)
- **Tests:** `tests/remote.bats` deckt Backup→Restore mit `-c` (inkl. nicht
  glatt teilbarer Größe) sowie Remote-Check komprimierter Backups positiv und
  negativ ab; `testing-docker/run-remote-tests.sh` bekommt ein Szenario für den
  komprimierten Zwei-Host-Durchlauf

### Geändert
- **Warnungen statt stillem Ignorieren:** `-c` im Clone-Modus und `-s` im
  Remote-Modus werden erkennbar gemeldet, statt wirkungslos zu bleiben
- **`check_remote_commands_availability`:** verlangt kein `gzip` mehr auf dem
  Remote-Host (komprimiert wird lokal); `ddpar-restore.sh` prüft dafür lokal auf
  `zcat` sowie im Remote-Modus auf `ssh`/`nc`

### Behoben
- **ddpar-restore.sh Port-Prüfung:** `grep -qE ":PORT[^0-9]"` statt `grep -q
  ":PORT"` — ein belegter Port 12345 galt sonst auch für Port 1234 als belegt

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
