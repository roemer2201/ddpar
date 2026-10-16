# Vollständiges Review von ddpar

Datum: 17.10.2026. Ausgangspunkt: `main` bei
`67e3ec98552a175d4d699b00f79bc3e132c05c03`.
Korrekturen: Branch `codex/full-review-integrity`.

Geprüft wurden sämtliche produktiven Skripte, alle Bats-Dateien und Helfer,
Makefile, CI, Docker-Harness und Projektdokumentation. Der Schwerpunkt lag auf
Datenintegrität, versehentlichem Überschreiben, Eingabevalidierung sowie
Rückgabestatus und Lebenszyklus der lokalen und entfernten Prozesse. Der ältere
Bericht `ChatGPT6Sol-Review.md` bleibt als historischer Befund erhalten.

## Befunde und umgesetzte Korrekturen

Alle folgenden Befunde wurden in diesem Branch behoben. Die Einstufung bezieht
sich auf den Ausgangsstand, nicht auf einen noch offenen Fehler.

| Priorität | Befund im Ausgangsstand | Korrektur und Nachweis |
|---|---|---|
| P1 | `check_backuped_image`/`check_restored_image` lasen lokal nur Quelle oder Ziel gegen `.sha256`; das Backup selbst konnte fehlen oder beschädigt sein und der Check dennoch Erfolg melden. Mit unveränderter Quelle und ersetztem Teil reproduziert: Exit 0. | Tatsächliche Teile auf Rohdatenlänge und gzip-Fehler prüfen, Hash des Teils mit Sidecar und Vergleichspartner vergleichen. Tests ändern oder löschen ausdrücklich den Backup-Teil. |
| P1 | `restore_split_image` schrieb mit `conv=notrunc`, ohne vorhandene Zieldateien zu kürzen. Reproduziert: 10-Byte-Abbild auf 100-Byte-Datei, Exit 0 und Länge 100. | Vor den parallelen Schreibern genau einmal auf die gesicherte Länge kürzen. Leere Abbilder umgehen das für Länge 0 ungeeignete fallocate. Tests für roh/gzip, bestehende/leere Dateiziele und `-P`. |
| P1 | Ein formal gültiges gzip mit zu wenig Rohdaten bestand die bisherige Restore-Vorprüfung. `dd` meldet frühes EOF nicht als Fehler. Reproduziert: 1 Byte statt 10 Bytes, Exit 0 und aufgefülltes Dateiziel. | Alle gzip-Teile vor Öffnen des Ziels vollständig dekomprimieren und Rohdatenmenge prüfen, einschließlich CRC. Tests für kurze, zu lange und beschädigte gzip-Teile; vorhandenes Ziel bleibt bei Ablehnung unverändert. |
| P1 | `clone_file` prüfte beim Verzeichnisziel nur das Verzeichnis. Eine bereits vorhandene Datei darin wurde ohne `-f` überschrieben. Bei fehlendem Dateiziel wurde stattdessen ein Verzeichnis angelegt und anschließend als Datei geöffnet. | Erst den tatsächlichen Dateipfad bestimmen und anschließend Existenz, Typ und Überschreibberechtigung prüfen. Tests für Ablehnung, erzwungenes Überschreiben und neue Datei. |
| P1 | Typ- und Größenanalyse folgte Symlinks nicht. Ein Dateilink konnte nur anhand der Linklänge verarbeitet werden; Links unter `/dev/disk/by-id` wurden nicht als Blockgerät erkannt. | Typ/Größe dereferenzieren, reguläre Dateien und Blockgeräte explizit prüfen, aufgelöstes Restore-Ziel erneut prüfen. Datei-Symlink-Regression; Blockgeräte werden zusätzlich in CI mit Loop-Devices geprüft. |
| P1 | Generierte Backup-Dateien konnten die Quelle selbst öffnen; Restore-Ziele konnten mit einem Backup-Teil identisch sein. Ein aus Metadaten übernommenes `FILE_NAME=../…` verließ das angegebene Zielverzeichnis. | Generierte Symlinks und lokale Quellen-Aliase vor Ausgabe ablehnen; Restore-Aliase prüfen; FILE_NAME auf einen einzelnen sicheren Basisnamen begrenzen. Tests mit identischer Datei, Symlink und Pfad-Traversal. |
| P1 | Alle Skripte teilten `/tmp/ssh_socket_ddpar`. Gleichzeitige Aufrufe konnten die Verbindung eines anderen Laufs schließen oder dessen authentifizierten Remote-Host verwenden. | Privates `mktemp`-Verzeichnis und ControlPath pro Aufruf, nur eigene Verbindung schließen, EXIT-Cleanup auch für frühe Fehler. Test mit zwei gleichzeitigen Remote-Clones. |
| P1 | Remote-Hash-Pipelines liefen ohne explizites `pipefail` in der Login-Shell. Ein gzip-CRC-Fehler nach Ausgabe sämtlicher korrekter Rohdaten konnte durch den erfolgreichen Hashprozess verdeckt werden. | Sämtliche Remote-Kommandos explizit in Bash mit `pipefail`; Regression beschädigt nur den gzip-CRC und erwartet trotz passender Rohdaten einen Fehler. |
| P1 | `-s` nutzte `tee >(sha256sum …)`, ohne den Prüfsummenprozess zu warten. Fehler beim Schreiben der Sidecars konnten als erfolgreiche Sicherung erscheinen. | Prüfsumme nach erfolgreichem Schreiben innerhalb desselben gewarteten Jobs erzeugen. Ein absichtlich fehlschlagender sha256sum-Worker muss den Aufruf fehlschlagen lassen. |
| P1 | Ein fehlerhafter oder abgebrochener neuer Backup-Lauf konnte normal aussehende Metadaten und eine Mischung aus alten/neuen Teilen hinterlassen. Erneutes Backup ohne `-s` ließ veraltete Sidecars stehen. | Neue Metadaten zunächst `BACKUP_STATE=incomplete`; erst nach Erfolg aller Jobs und Längenprüfungen auf `complete` setzen. Restore/Check verweigern unvollständige neue Backups. Veraltete Sidecars bei Sicherung ohne `-s` entfernen. |
| P1 | Erfolgreiche dd-/nc-Exitcodes belegten keine vollständig empfangene Rohdatenmenge beim Clone/Restore. | `ddpar_write_segment` begrenzt die Schreibmenge und zählt zugleich alle empfangenen Bytes über einen explizit gewarteten Prozess. Tests für frühes EOF und `/dev/full`. |
| P1 | Abbruchbehandlung mit `jobs -p` erreichte nur Prozessgruppenführer und konnte weitere dd/nc-Prozesse weiterlaufen lassen. | Lokale Prozessbäume rekursiv beenden; Remote-Jobs über `setsid` in eigenen Gruppen starten und nur diese Gruppen beenden. TERM-Regression prüft einen blockierten Worker samt Kindprozess. |
| P1 | Die Auswahl des nicht implementierten verschlüsselten Modus `l` setzte den Transfer trotz Warnung unverschlüsselt fort. | Vor Verbindungsaufbau/Datenübertragung mit Fehler abbrechen. CLI-Test und korrigierte Sicherheitsdokumentation. |
| P2 | Regex-Prüfungen allein verhinderten weder Zahlenüberlauf noch ungültige Produkt-/Offsetwerte; doppelte Metadatenschlüssel und Dateinamen mit `=` wurden mit grep/cut nicht sauber behandelt. | Gemeinsamer Datenparser mit Duplikatprüfung, kanonischen Dezimalzahlen und 64-Bit-Grenzen; Faktoren vor Multiplikation prüfen. Ältere Metadaten ohne INPUT_SIZE bleiben lesbar. Negativtests und Roundtrip mit `a=b#c&d`. |
| P2 | SSH-Verbindungsfehler konnten als erfolgreicher Aufbau ausgegeben werden. Netcat nutzte den Aliasnamen statt dessen SSH-HostName. Remote-Checks mit vielen Jobs konnten MaxSessions überschreiten. | Fehler direkt weitergeben; Adresse über `ssh -G` auflösen; höchstens vier lange Hash-Sitzungen zugleich. 12-Segment-Remote-Check ergänzt. |
| P2 | Nicht erreichbare Gegenstellen konnten netcat-Clients lange blockieren; `kill -0` hielt Zombie-Wrapper für laufend. | Netcat-Verbindungs-/Inaktivitätslimit 300 s, konfigurierbar über DDPAR_NETWORK_TIMEOUT, SSH-Keepalives und explizite Zombie-Erkennung. Der gesunde abschließende Remote-Schreibvorgang bleibt ohne pauschales Zeitlimit. |
| P2 | Unbekannte Restore-/Check-Optionen wurden nur ausgegeben und danach ignoriert; dokumentierte lange Aliase funktionierten nicht, Restore-Hilfe endete mit Fehlerstatus. | Bekannte lange Aliase normalisieren, zusätzliche Argumente und unbekannte Optionen ablehnen, Hilfe mit Status 0. Tests für alle drei Einstiegsskripte. |
| P2 | Der vollständige ShellCheck-Report durfte in CI fehlschlagen; doppelte SSH-/Metadatenimplementierungen drifteten auseinander. Veraltete Dokumentations-Stubs konnten ohne Datenübertragung Erfolg simulieren. | Gemeinsame Hilfsdatei, vollständiger sauberer ShellCheck als CI-Gate einschließlich Docker-Skripten; Dokumentation und Tests auf tatsächliche Daten statt reine Kommandoausgabe ausrichten. |

## Validierung

- Ausgangsstand: 30 lokale CLI-/Dateitests erfolgreich; die oben beschriebenen
  Integritätsfehler waren dadurch nicht abgedeckt und wurden separat reproduziert.
- Der Branch enthält 68 Bats-Tests, davon 20 neu: 17 lokale Integritäts-/Abbruchtests
  und drei zusätzliche Remote-Regressionen.
- `make lint`: vollständiger ShellCheck-Report ohne Befunde, einschließlich der
  gemeinsam eingelesenen Hilfsdatei und der Docker-Harness-Skripte.
- Lokale CLI-/Datei-/Integritätstests und Remote-Steuerpfade mit echtem netcat
  werden in der Arbeitsumgebung ausgeführt. Für Letztere wird nur die
  SSH-Steuerung nachgebildet: Ein echter lokaler sshd kann hier wegen fehlender
  chroot-Berechtigung nicht starten. Loop-Devices stehen hier ebenfalls nicht
  zur Verfügung. Das ist kein Nachweis einer realen SSH-Verbindung.
- Der dedizierte GitHub-Actions-Job prüft echte SSH-Verbindungen zu localhost
  und Blockgeräte als Loop-Devices. Maßgeblich ist dessen Ergebnis für den
  jeweiligen PR-Commit, zusätzlich zu den unprivilegierten Datei- und Lint-Jobs.

## Auswirkungen und verbleibende Grenzen

- Alle vier `ddpar*.sh`-Dateien gemeinsam ausliefern. Die neue Hilfsdatei ist zur
  Laufzeit erforderlich. Das Docker-Harness bindet das vollständige Repository ein.
- Neue Backups sind mit `BACKUP_STATE` als vollständig/unvollständig markiert.
  Ältere Backups bleiben lesbar, können aber nachträglich keinen solchen
  Vollständigkeitsnachweis erhalten. Ältere ddpar-Versionen ignorieren das Feld;
  für die neue Schutzwirkung auch Restore/Check aktualisieren.
- Zusätzliche Vorprüfungen lesen gzip-Teile vollständig. Prüfsummenerzeugung und
  Abschlussprüfung kosten zusätzliche I/O; bei komprimiertem Remote-Backup im
  Modus n kann die Abschlussprüfung die komprimierten Daten erneut übertragen.
  Diese Mehrarbeit verhindert falsche Erfolgsmeldungen durch kurze Datenströme.
- Backup mit gleichem Basisnamen überschreibt weiterhin die bisherigen Teile.
  Bei Fehlern ist diese Generation unvollständig und keine automatische
  Wiederherstellung der vorherigen Generation möglich. Für Generationen
  getrennte Namen/Verzeichnisse verwenden; gleichzeitige Schreiber auf denselben
  Basisnamen und Änderungen an Quelle/Backup während des Laufs sind nicht unterstützt.
- Netcat n/c bleibt ein unverschlüsselter, nicht authentifizierter Datenkanal
  für vertrauenswürdige Netze. Implementierung eines verschlüsselten Kanals ist
  eine zusätzliche Funktion; der bisherige unsichere Fallback wurde entfernt.
  SSH-Jumphosts tunneln diesen separaten Datenkanal nicht automatisch.
- Lokale Backup-Checks setzen weiterhin mit `-s` erzeugte Sidecars voraus;
  Remote-Backups werden direkt gegen Quelle/Ziel verglichen. Restore prüft
  vorhandene lokale Sidecars. Die Prüfsummen sind keine Signaturen und schützen
  nicht gegen jemanden, der Daten und Prüfsummen gemeinsam ersetzen kann.
- Kein Hardwaretest mit realen Laufwerken, kein Nachweis von Stromausfallsicherheit
  und kein Zwei-Host-Docker-Lauf in dieser Umgebung. Unveränderte Live-Dateisysteme
  bzw. geeignete Snapshots bleiben Voraussetzung für konsistente Abbilder.

## Primärreferenzen zu den korrigierten Mechanismen

- [GNU dd](https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html):
  count/fullblock, Byte-Offsets und conv=notrunc.
- [Bash-Pipelines](https://www.gnu.org/software/bash/manual/html_node/Pipelines.html):
  pipefail und Exitstatus.
- [Bash-Prozesssubstitution](https://www.gnu.org/software/bash/manual/html_node/Process-Substitution.html):
  asynchron gestartete Prozesse.
