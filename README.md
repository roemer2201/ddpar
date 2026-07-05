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
| `ddpar-check.sh` | Integritätsprüfung via SHA256 (Quelle↔Backup, Backup↔Ziel oder Quelle↔Ziel) |

## Voraussetzungen

- Bash, GNU coreutils (`dd` mit `count_bytes`/`skip_bytes`/`seek_bytes`), `file`, `blockdev`
- `gzip` (bei Kompression), `sha256sum` (bei Checksummen)
- Für Remote-Betrieb: `ssh`, `nc` (netcat-openbsd), `ss`; optional `sshpass` für Passwort-Login

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

# Klonen mit Checksummen (-s): schreibt /tmp/clone-sums-N.sha256 + Metadaten
./ddpar.sh -i /dev/sdb -o /dev/sdc -s -n /tmp/clone-sums

# Clone gegen die Checksummen prüfen (ohne die Quelle erneut zu lesen)
./ddpar-check.sh -b /tmp/clone-sums -d /dev/sdc

# Clone prüfen (ohne Checksummen/Metadaten: -j/-B wie beim Clone angeben)
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

# Remote-Backup komprimiert: -r n -c = gzip lokal (.gz wird übertragen),
# -r c = gzip auf dem Remote-Host (Rohdaten werden übertragen)
./ddpar.sh -i /dev/sdb -o /remote/backup -m backup -r n -c -R user@zielhost
./ddpar.sh -i /dev/sdb -o /remote/backup -m backup -r c -R user@zielhost

# Restore eines komprimierten Remote-Backups (Erkennung über Metadaten):
# -r n entpackt lokal, -r c entpackt auf dem Remote-Host
./ddpar-restore.sh -i /remote/backup/sdb -o /dev/sdc -r n -R user@zielhost

# Remote-Check (nur SHA256-Hashes laufen über SSH)
./ddpar-check.sh -s /dev/sdb -b /remote/backup/sdb -r n -R user@zielhost
```

**Sicherheitshinweise zum Remote-Modus:**

- Der Verbindungsaufbau und die Steuerung laufen über SSH, die **Nutzdaten im
  Modus `n` jedoch unverschlüsselt über netcat**. Nur in vertrauenswürdigen
  Netzen verwenden. Ein vollständig verschlüsselter Modus (`l`) ist geplant,
  aber noch nicht implementiert.
- Host-Keys werden mit `StrictHostKeyChecking=accept-new` behandelt: Unbekannte
  Hosts werden beim Erstkontakt akzeptiert, ein **geänderter** Host-Key führt
  zum Abbruch.
- Passwörter (optional via `sshpass`) werden über die Umgebung übergeben und
  tauchen nicht in der Prozessliste auf. Im Debug-Modus (`-d`) können
  Passwörter im Klartext ausgegeben werden.

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

#### local [de]compression (`-r n -c`: gzip lokal, .gz wird übertragen)
| | backup gzip (check) | restore gzip (check) |
|-|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### remote [de]compression (`-r c`: Rohdaten übertragen, gzip auf dem Remote-Host)
| | backup gzip (check) | restore gzip (check) |
|-----------|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### compressed transfer (compression+decompression before and after transfer)
| | clone |
|----------|----------|
| block dev | :heavy_check_mark: |
| file | :heavy_check_mark: |

## To Do

- Kompression + `-s`: Checksumme optional auch für die komprimierten Dateien berechnen (derzeit nur für die Rohdaten)
- Remoting:
  - Verschlüsselter Datenkanal (`-r l`)
  - `-s` beim Remote-Backup: .sha256-Dateien auf dem Remote-Host erzeugen (derzeit Warnung; Prüfung via `ddpar-check.sh -r` funktioniert ohne sie)
  - Remote-Eingabe mit lokaler Ausgabe (noch nicht durchdacht)
