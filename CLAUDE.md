# CLAUDE.md – Projektkontext für Claude Code

## Projektübersicht

**ddpar** (dd parallel) ist eine Sammlung von Bash-Skripten zum parallelen Klonen,
Sichern und Wiederherstellen von Block-Devices und Dateien mittels `dd`.
Die Parallelisierung erfolgt durch Aufteilung der Eingabe in gleichgroße Segmente,
die gleichzeitig über separate `dd`-Prozesse verarbeitet werden.

## Dateien

| Datei | Aufgabe |
|---|---|
| `ddpar.sh` | Hauptskript: Clone- und Backup-Modus, lokal und remote |
| `ddpar-restore.sh` | Wiederherstellen eines mit `ddpar.sh -m backup` erstellten Backups |
| `ddpar-check.sh` | Prüfung der Integrität via SHA256 (Quelle↔Backup oder Backup↔Ziel) |
| `ddpar-common.sh` | Gemeinsame Metadaten-, Datenstrom- und SSH-Helfer; neben den Einstiegsskripten ausliefern |
| `completions/ddpar` | Bash-Completion für alle Programme; die übrigen Dateien in `completions/` sind Symlinks für Lazy Loading |
| `debian/` | Natives Debian-Paket (Handbuchseiten unter `debian/manpages/`, Smoke-Test/autopkgtest unter `debian/tests/`) |
| `tests/` | bats-Tests (`make test`); `completion_readline.py` prüft echte Tab-Eingaben |
| `TESTING.md` | Manuelle Testszenarien mit Beispielkommandos |
| `ARCHITECTURE.md` | Design-Dokumentation: Parallelisierung, Pipes, Remote-Konzept |
| `CHANGELOG.md` | Versionshistorie und Bug-Fix-Dokumentation |

## Coding-Konventionen

- **Shell:** Bash (`#!/bin/bash`), keine POSIX-only-Syntax erforderlich
- **Linter:** ShellCheck (siehe `.shellcheckrc`). Vor jedem Commit ausführen: `make lint`
- **Variablen:** Immer in doppelten Anführungszeichen, wenn sie Pfade enthalten können
- **Shell-Befehle:** Lokale Argumente als Array übergeben; dynamische Remote-Pfade
  vor dem Einbetten in einen SSH-Befehl als einzelne Shell-Argumente quotieren
- **Tests:** `[ -z "$VAR" ]` mit Quotes — nie `[ -z $VAR ]`
- **Metadaten:** Den Datenparser in `ddpar-common.sh` verwenden; nicht sourcen oder mit getrennten grep/cut-Aufrufen zerlegen.
- **Farb-Echo:** Immer `echo -e` wenn ANSI-Codes (`${INFOCOLOR}` etc.) ausgegeben werden
- **Port-Prüfung:** `grep -qE ":PORT[^0-9]"` — niemals `:PORT` ohne Suffix (Substring-Matching)

## Metadaten-Format

Backup-Metadatei `<BACKUP_BASE>-metadata.txt` — zeilenweise `KEY=VALUE`:

```
NUM_JOBS=4
FILE_NAME=sdb
BLOCKSIZEBYTES=1048576
INPUT_SIZE=68719476736
INPUT_FILE_NAME=sdb
FILE_TYPE=block special (8/16)
SPLIT_SIZE=17179869184
COMPRESSION=1          # nur vorhanden wenn komprimiert
COMPRESSION_LEVEL=6    # nur vorhanden wenn komprimiert
```

## Änderungen validieren

```bash
make lint        # ShellCheck auf alle .sh-Dateien und completions/ddpar
make test        # bats-Tests (Blockgeräte/SSH werden ohne root/SSH übersprungen)
make deb         # Debian-Paket bauen (führt lint und lokale Tests aus)
```

Neue Optionen in den Programmen auch in `completions/ddpar`, den
Handbuchseiten unter `debian/manpages/` und `tests/completion.bats` nachziehen.

Manuelle Tests: siehe `TESTING.md`.

## Bekannte Einschränkungen / offene Baustellen

- Remote Clone, Backup, Restore und Checks (netcat) sind implementiert — unkomprimiert, mit **lokaler [De]Kompression** (`-c` + `-r n`: gzip/zcat laufen lokal, die Gegenseite schreibt/liest nur `.gz`-Dateien und braucht kein gzip) und mit **Remote-[De]Kompression** (`-c` + `-r c`: gzip/zcat laufen auf der Gegenseite, dort erforderlich)
- `-c` im Clone-Modus ist nur mit `-r c` möglich (die Gegenseite dekomprimiert vor dem Schreiben); ohne `-r c` folgt eine Warnung und der Clone läuft unkomprimiert
- Offen bleibt der verschlüsselte Datenkanal (`-r l`, wird mit Fehlerstatus abgelehnt)
- Die `.gz`-Teile aus `-r n` und `-r c` sind identisch — Backups sind zwischen den Modi austauschbar
- `-s` (Checksummen-Dateien) wird im Remote-Modus nicht angewendet; Remote-Backups prüft man mit `ddpar-check.sh -r` über Laufzeit-Hashes
- Remote Checks (`ddpar-check.sh -r`) vergleichen nur SHA256-Hashes je Segment (lokal vs. per SSH) — kein netcat-Datentransfer nötig
- `RANDOM` in Bash liefert nur 0–32767 → Remote-Ports werden aus dem Bereich 10000–42767 gewählt
- `fallocate` funktioniert nicht auf Block-Devices (wird korrekt übersprungen)
- Nach dem Ende der lokalen Sender kann die Gegenseite noch schreiben (im Modus `c` puffert dort gzip); Remote-Pipelines laufen per `nohup` abgekoppelt (keine dauerhaften SSH-Sitzungen wegen sshd `MaxSessions`), ein Wrapper schreibt PID und Exit-Status (Bash `pipefail`) in ein Statusverzeichnis `/tmp/ddpar-status.*` auf der Gegenseite, das `wait_for_jobs()` abfragt — ohne festes Zeitlimit
- Beliebige Eingabegrößen: `SPLIT_SIZE` wird auf die Blockgröße abgerundet, der letzte Teil überträgt den Rest (`part_bytes`, dd-Flags `count_bytes`/`skip_bytes`/`seek_bytes`)
- Von den Remote-Modus-Flags (`-r l/n/c`) sind `n` und `c` implementiert, `l` nicht

## Branch-Strategie

- `main` — stabiler Stand
- `claude/*` — von Claude Code erstellte Feature-/Fix-Branches

## Integritätsregeln

- Neue Backups erst nach erfolgreicher Teile- und Jobprüfung als `complete` markieren.
- Jeder Clone-/Restore-Schreiber muss die tatsächliche Datenmenge kontrollieren.
- Zielpfade vor dem Öffnen vollständig auflösen; Backups nicht durch den Restore überschreiben.
- Private SSH-Sockets je Aufruf; Remote-Befehle mit Bash `pipefail` ausführen.
- Remote-Gruppen via `setsid` isolieren; bei Abbruch eigene Prozessbäume beenden.
- `make lint` prüft auch die Hilfsdatei und Docker-Skripte; der volle Report ist CI-Gate.
