# ddpar

**dd parallel** — Bash-Skripte zum parallelen Klonen, Sichern und
Wiederherstellen von Blockgeräten und großen Dateien mit `dd`.

Die Eingabe wird in gleich große Segmente geteilt, die gleichzeitig von
mehreren `dd`-Prozessen verarbeitet werden. Beliebige Eingabegrößen werden
unterstützt: Ein nicht gleichmäßig verteilbarer Rest wird vom letzten Teil
übertragen. Übertragung auf einen Remote-Host ist per SSH + netcat möglich.

| Skript | Aufgabe |
|---|---|
| `ddpar.sh` | Klonen (`-m clone`, Default) oder Sichern (`-m backup`), lokal und remote |
| `ddpar-restore.sh` | Wiederherstellen eines mit `ddpar.sh -m backup` erstellten Backups |
| `ddpar-common.sh` | Gemeinsame Validierung, SSH-Verwaltung und Datenstromprüfung (wird eingelesen) |
| `ddpar-check.sh` | Integritätsprüfung via SHA256 (Quelle↔Backup, Backup↔Ziel oder Quelle↔Ziel) |

## Voraussetzungen

**Installation:** Alle vier `ddpar*.sh`-Dateien müssen im selben Verzeichnis liegen.
Symlinks auf die Einstiegsskripte (z.B. `/usr/local/bin/ddpar -> /opt/ddpar/ddpar.sh`)
werden aufgelöst; die Hilfsdatei wird neben dem eigentlichen Skript gesucht.

- Linux mit `/proc`, Bash ab 4.4 (`wait` auf Prozesssubstitutionen), GNU coreutils (`dd` mit `count_bytes`/`skip_bytes`/`seek_bytes`), `file`, `blockdev`
- `gzip` (bei Kompression), `sha256sum` (bei Checksummen)
- Für Remote-Betrieb: `ssh`, `nc` (netcat-openbsd), `ss`; optional `sshpass` für Passwort-Login.
  Auf dem Remote-Host zusätzlich Bash (ab 4.4, der Remote-Clone nutzt dort
  denselben Segment-Schreiber) für die Fehlerweitergabe der Pipelines,
  `setsid` (util-linux), ein beschreibbares `/tmp` für die Statusdateien und
  `gzip` bei `-r c` (bei `-r n` **nicht** nötig)

## Bash-Completion

Mit installiertem `bash-completion` (ab 2.1) kann die Completion im Checkout
direkt geladen werden:

```bash
source /usr/share/bash-completion/bash_completion
source completions/ddpar
```

Fuer dauerhaftes Laden ohne root-Rechte alle Dateien und Symlinks aus
`completions/` nach `${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions/`
kopieren. Diese Verzeichnisse bei Bedarf zuerst anlegen. Bash-Completion muss
in der interaktiven Shell aktiviert sein; danach wird beim ersten Tab geladen.

Unterstuetzt werden `ddpar`, `ddpar-restore`, `ddpar-check`, ihre `.sh`-Namen
und das Entwicklerwerkzeug `testing-docker/run-remote-tests.sh`. Die eingelesene
Bibliothek `ddpar-common.sh` und der Container-Entrypoint haben keine Benutzer-CLI.
Die Completion bietet alle vom jeweiligen Parser unterstuetzten Optionen,
`clone`/`backup`, die implementierten Remote-Modi `n`/`c`, Zahlenvorschlaege,
lokale Dateien/Blockgeraete und SSH-Hosts (auch `user@host`) an. Zahlenvorschlaege
begrenzen die zulaessigen Werte nicht. Kurzoptionen mit angehaengten Werten und
Flag-Kombinationen werden ebenfalls erkannt.

Restore-Eingaben (`-i`/`--input`) und Check-Backups (`-b`) vervollstaendigen
den Basisnamen aus `*-metadata.txt`, einschliesslich Verzeichnissen zum
Navigieren. Im Backup-Modus bietet `ddpar -o` Verzeichnisse an; `-n` erwartet
einen frei gewaehlten Namen. Remote-Pfade muessen von Hand eingegeben werden;
Tab startet weder SSH-Verbindungen noch eines der ddpar-Programme. Dafuer
`-r`/`-R` vor dem jeweiligen Remote-Pfad angeben. Nach `--` werden keine
Argumente vorgeschlagen, da die Programme keine Positionsargumente akzeptieren.

## Schnellstart

```bash
# Backup einer Platte in 4 parallelen Teilen, mit Checksummen (-s)
./ddpar.sh -i /dev/sdb -o /mnt/backup -m backup -s

# Backup komprimiert (-c)
./ddpar.sh -i /dev/sdb -o /mnt/backup -m backup -s -c

# Backup mit eigenem Basisnamen (-n): erzeugt /mnt/backup/mein-backup-0.part usw.
./ddpar.sh -i /dev/sdb -o /mnt/backup -m backup -s -n mein-backup

# Backup gegen die Quelle prüfen
./ddpar-check.sh -s /dev/sdb -b /mnt/backup/sdb

# Wiederherstellen (Jobs/Blockgröße kommen aus der Metadatendatei)
./ddpar-restore.sh -i /mnt/backup/sdb -o /dev/sdc

# Wiederhergestelltes Ziel gegen das Backup prüfen
./ddpar-check.sh -b /mnt/backup/sdb -d /dev/sdc

# Klonen Gerät -> Gerät mit 8 Jobs
./ddpar.sh -i /dev/sdb -o /dev/sdc -j 8

# Clone prüfen (ohne Backup-Metadaten: -j/-B wie beim Clone angeben)
./ddpar-check.sh -s /dev/sdb -d /dev/sdc -j 8
```

`./ddpar.sh -h`, `./ddpar-restore.sh -h` und `./ddpar-check.sh -h` zeigen alle Optionen.

### Remote (SSH + netcat)

```bash
# Clone auf einen Remote-Host: Daten laufen unverschlüsselt über netcat
./ddpar.sh -i /dev/sdb -o /dev/sdc -r n -R user@zielhost

# Remote-Backup und -Restore (unkomprimiert)
./ddpar.sh -i /dev/sdb -o /remote/backup -m backup -r n -R user@zielhost
./ddpar-restore.sh -i /remote/backup/sdb -o /dev/sdc -r n -R user@zielhost

# Remote-Backup komprimiert (-c): gzip läuft lokal, der Remote-Host braucht kein gzip
./ddpar.sh -i /dev/sdb -o /remote/backup -m backup -c -r n -R user@zielhost
# Restore daraus: zcat läuft ebenfalls lokal (die Kompression steht in den Metadaten)
./ddpar-restore.sh -i /remote/backup/sdb -o /dev/sdc -r n -R user@zielhost

# Dasselbe mit Kompression auf der Gegenseite (-r c): dort wird gzip benötigt
./ddpar.sh -i /dev/sdb -o /remote/backup -m backup -c -r c -R user@zielhost
./ddpar-restore.sh -i /remote/backup/sdb -o /dev/sdc -r c -R user@zielhost

# Clone komprimiert übertragen: nur mit -r c (die Gegenseite dekomprimiert)
./ddpar.sh -i /dev/sdb -o /dev/sdc -m clone -c -r c -R user@zielhost

# Remote-Check (nur SHA256-Hashes laufen über SSH)
./ddpar-check.sh -s /dev/sdb -b /remote/backup/sdb -r n -R user@zielhost
```

**Kompression im Remote-Modus (`-c`)** gibt es in zwei Varianten — die erzeugten
`.gz`-Teile sind identisch, ein Backup aus einem Modus lässt sich also im
jeweils anderen wiederherstellen und prüfen:

- **`-r n` — *local [de]compression*:** `gzip` bzw. `zcat` laufen auf der
  lokalen Maschine, über das Netz geht nur der komprimierte Strom, die
  Gegenseite schreibt bzw. liest die `.gz`-Teile mit `dd`. Das spart Bandbreite
  und setzt auf dem Remote-Host **kein** `gzip` voraus. Beim Check werden die
  `.gz`-Teile über SSH geholt und lokal ausgepackt.
- **`-r c` — *remote [de]compression*:** `gzip` bzw. `zcat` laufen auf dem
  Remote-Host (dort also **erforderlich**). Beim Backup/Restore gehen die
  Rohdaten über das Netz — das entlastet die lokale CPU, spart aber keine
  Bandbreite. Der Check lässt die Gegenseite auspacken und hashen, es geht nur
  der Hash über SSH. Beim **Clone** ist es umgekehrt: dort komprimiert die
  lokale Seite und die Gegenseite packt vor dem Schreiben wieder aus — nur so
  ist `-c` im Clone-Modus überhaupt möglich (mit `-r n` folgt eine Warnung und
  der Clone läuft unkomprimiert).

Verglichen werden in allen Fällen die Hashes der Rohdaten.

**Sicherheitshinweise zum Remote-Modus:**

- Der Verbindungsaufbau und die Steuerung laufen über SSH, die **Nutzdaten in
  den Modi `n` und `c` jedoch unverschlüsselt über netcat** (Kompression ist
  keine Verschlüsselung). Nur in vertrauenswürdigen Netzen verwenden. Ein
  vollständig verschlüsselter Modus (`l`) ist geplant, aber noch nicht
  implementiert. Ein Aufruf mit `-r l` bricht ab und sendet keine Nutzdaten.
- Host-Keys werden mit `StrictHostKeyChecking=accept-new` behandelt: Unbekannte
  Hosts werden beim Erstkontakt akzeptiert, ein **geänderter** Host-Key führt
  zum Abbruch.
- Passwörter (optional via `sshpass`) werden über die Umgebung übergeben und
  tauchen nicht in der Prozessliste auf. Im Debug-Modus (`-d`) können
  Passwörter im Klartext ausgegeben werden.

## Integrität und Zielschutz

Ein Clone auf eine vorhandene Datei benötigt `-f`, auch wenn `-o` ein
Verzeichnis ist. Ein noch nicht vorhandenes Dateiziel wird direkt angelegt.
Symlinks zu Dateien und Blockgeräten werden beim Bestimmen von Typ und Größe
aufgelöst; Quelle und Ziel dürfen lokal nicht dieselbe Datei sein.

Vor einem Restore werden alle Teile auf ihre tatsächliche Rohdatenlänge
geprüft. Komprimierte Teile werden dabei vollständig dekomprimiert, einschließlich
CRC-Prüfung. Lokal vorhandene `.sha256`-Dateien werden ebenfalls geprüft.
Reguläre Zieldateien erhalten exakt die gesicherte Länge; größere Blockgeräte
behalten ihren Bereich hinter dem gesicherten Abbild.

Der lokale Check benötigt weiterhin mit `-s` erzeugte Prüfsummen, liest jetzt
aber auch die tatsächlichen Backup-Teile. Ein unverändertes Original allein
kann daher kein beschädigtes oder fehlendes Backup mehr als korrekt bestätigen.
Remote-Checks vergleichen die tatsächlichen Teile direkt mit Quelle oder Ziel.

Neue Backups enthalten `BACKUP_STATE=incomplete`, bis alle Jobs und die
Längenprüfung erfolgreich abgeschlossen sind. Erst dann wird der Status
`complete` gesetzt. Restore und Check lehnen unvollständige Backups ab.
Ältere Backups ohne dieses Feld bleiben lesbar. Ein erneutes Backup überschreibt
weiterhin seine bisherigen Teile; für getrennte Generationen eigene Basisnamen
oder Verzeichnisse verwenden. Während der Operation müssen Quelle und
Backup-Dateien unverändert bleiben; ddpar erzeugt keinen Dateisystem-Snapshot.

Jeder Remote-Aufruf verwendet einen eigenen privaten SSH-Control-Socket.
SSH-Aliase werden für netcat über `ssh -G` in ihre `HostName`-Adresse aufgelöst;
diese Adresse muss vom ausführenden Host direkt erreichbar sein. Ein SSH
`ProxyJump` transportiert den separaten netcat-Datenkanal nicht automatisch.
Die netcat-Clients begrenzen Verbindungsaufbau und Netzwerk-Inaktivität auf
300 Sekunden; `DDPAR_NETWORK_TIMEOUT` überschreibt diesen Wert (positive ganze
Sekunden). Der abschließende Schreibvorgang auf der Gegenseite hat weiterhin
kein pauschales Zeitlimit. Tote oder als Zombie verbliebene Remote-Wrapper
werden als Fehler erkannt. SIGINT/SIGTERM beendet lokale Prozessbäume und die
zu diesem Aufruf gehörenden Remote-Prozessgruppen.

## Exit-Codes

Alle Skripte enden mit Exit-Code `0` nur, wenn sämtliche parallelen
Teil-Prozesse erfolgreich waren. Schlägt ein Teil fehl (z.B. Lesefehler,
volle Platte, abgerissene Verbindung) oder meldet `ddpar-check.sh` eine
Abweichung, ist der Exit-Code `!= 0` — damit sind die Skripte in eigenen
Automatisierungen/CI verwendbar.

## Tests und Entwicklung

```bash
make install-deps      # shellcheck, bats, netcat (Debian/Ubuntu)
make check             # ShellCheck-Gate + bats-Testsuite
make test-integration  # Blockgerät- (root) und Remote-Tests (SSH)
```

Details: [tests/README.md](tests/README.md), [TESTING.md](TESTING.md) (manuelle
Szenarien), [testing-docker/](testing-docker/) (Zwei-Host-Testumgebung),
[ARCHITECTURE.md](ARCHITECTURE.md) (Design).

## Funktionsstatus

### Lokal
#### uncompressed

| | clone (check) || backup (check) | restore (check) |
|----------|----------|-|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) || :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) || :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### compressed
| | backup gzip (check) | restore gzip (check) |
|-----------|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

<br>

### Remote — SSH
#### general remote functionality (ssh)
| |state|
|-|-|
| establish_ssh_connection | :heavy_check_mark: |
| execute_command | :heavy_check_mark: |
| execute_remote_command | :heavy_check_mark: |
| execute_remote_background_command | :heavy_check_mark: |
| close_ssh_connection | :heavy_check_mark: |
| check_remote_commands_availability | :heavy_check_mark: |
| remote_port_generation | :heavy_check_mark: |
| check_remote_port_availability | :heavy_check_mark: |
| output_analysis | :heavy_check_mark: |
| remote_cloning_commands | :heavy_check_mark: |
| remote_backup_commands | :heavy_check_mark: |

<br>

### Remote — netcat
#### uncompressed
| | clone (check) | | backup (check) | restore (check) |
|-|----------|-|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### local [de]compression
Kompression/Dekompression laufen lokal, über netcat geht nur der komprimierte
Strom; die Remote-Seite benötigt kein `gzip`.

| | backup gzip (check) | restore gzip (check) |
|-|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### remote [de]compression (`-r c`)
`gzip`/`zcat` laufen auf der Gegenseite (dort erforderlich); über netcat gehen
die Rohdaten. Der Check hasht remote, es geht nur der Hash über SSH.

| | backup gzip (check) | restore gzip (check) |
|-----------|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### compressed transfer (compression+decompression before and after transfer)
Clone mit `-c` + `-r c`: lokal wird komprimiert, die Gegenseite dekomprimiert
vor dem Schreiben.

| | clone |
|----------|----------|
| block dev | :heavy_check_mark: |
| file | :heavy_check_mark: |

## To Do

- ddpar.sh:
  - Checksummen im Clone-Modus (analog Backup-Modus). Kompression im
    Clone-Modus ist mit `-r c` möglich; lokal wird `-c` dort weiterhin mit einer
    Warnung ignoriert
  - `-s` im Remote-Modus: `.sha256`-Dateien auf der Gegenseite ablegen (heute
    prüft man Remote-Backups mit `ddpar-check.sh -r` über Laufzeit-Hashes)
- `BASE_NAME` als Pfad für Checksummen-Dateien von Clones nutzen (wenn Checksummen angefordert)
- Kompression + `-s`: Checksumme optional auch für die komprimierten Dateien berechnen (derzeit nur für die Rohdaten)
- Remoting:
  - Verschlüsselter Datenkanal (`-r l`)
  - Remote-Eingabe mit lokaler Ausgabe (noch nicht durchdacht)
