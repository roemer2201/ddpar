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
| `TESTING.md` | Manuelle Testszenarien mit Beispielkommandos |
| `ARCHITECTURE.md` | Design-Dokumentation: Parallelisierung, Pipes, Remote-Konzept |
| `CHANGELOG.md` | Versionshistorie und Bug-Fix-Dokumentation |

## Coding-Konventionen

- **Shell:** Bash (`#!/bin/bash`), keine POSIX-only-Syntax erforderlich
- **Linter:** ShellCheck (siehe `.shellcheckrc`). Vor jedem Commit ausführen: `make lint`
- **Variablen:** Immer in doppelten Anführungszeichen, wenn sie Pfade enthalten können
- **`eval`:** Immer `eval "${VAR}"` mit Quotes — nie `eval $VAR`
- **Tests:** `[ -z "$VAR" ]` mit Quotes — nie `[ -z $VAR ]`
- **grep in Metadaten:** Immer mit `^`-Anker, z.B. `grep "^KEY="`, um Prefix-Matches zu vermeiden
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
make lint        # ShellCheck auf alle .sh-Dateien
```

Manuelle Tests: siehe `TESTING.md`.

## Bekannte Einschränkungen / offene Baustellen

- Remote Backup und Remote Restore (netcat, unkomprimiert, ohne Check) sind implementiert; komprimierter Remote-Transfer fehlt noch (🛑 in README)
- Clone-Check (`ddpar-check.sh` nach Clone) ist noch nicht implementiert
- `RANDOM` in Bash liefert nur 0–32767 → Remote-Ports werden aus dem Bereich 10000–42767 gewählt
- `fallocate` funktioniert nicht auf Block-Devices (wird korrekt übersprungen)
- Eingabegröße muss durch `NUM_JOBS × BLOCKSIZEBYTES` ganzzahlig teilbar sein
- Remote-Modus-Flags (`-r l/n/c`) sind noch nicht vollständig implementiert

## Branch-Strategie

- `main` — stabiler Stand
- `claude/*` — von Claude Code erstellte Feature-/Fix-Branches
