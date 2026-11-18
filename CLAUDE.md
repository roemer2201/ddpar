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
| `TESTING.md` | Automatisierte Suite, Integrationsvoraussetzungen und manuelle Beispiele |
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
- **Port-Prüfung:** Den TCP-Listen-Port mit dem exakten Portfilter von `ss` prüfen.

## Metadaten-Format

Felder, Bedeutung und Regeln für ältere Backups stehen in
[Architektur und Backup-Format](ARCHITECTURE.md#backup-dateien).

## Änderungen validieren

```bash
make lint        # ShellCheck auf alle .sh-Dateien und completions/ddpar
make test        # bats-Tests (Blockgeräte/SSH werden ohne root/SSH übersprungen)
make deb         # Debian-Paket bauen (führt lint und lokale Tests aus)
```

Neue Optionen in den Programmen auch in `completions/ddpar`, den
Handbuchseiten unter `debian/manpages/` und `tests/completion.bats` nachziehen.

Manuelle Tests: siehe `TESTING.md`.

## Remote-Modi

Bedienung und Grenzen stehen in der [README](README.md#remote-ssh--netcat).
Worker, Statusverzeichnis und Fehlerbehandlung beschreibt die
[Architektur](ARCHITECTURE.md#remote-worker-und-fehlerbehandlung).

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
