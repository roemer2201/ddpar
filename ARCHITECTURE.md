# Architektur

## Grundprinzip: Paralleles `dd`

ddpar teilt die Eingabe in `NUM_JOBS` gleichgroße Segmente auf. Jedes Segment
wird von einem eigenen `dd`-Prozess gelesen und geschrieben. Die Prozesse laufen
gleichzeitig im Hintergrund (`&`), am Ende wartet das Skript mit `wait` auf alle.

### Segmentberechnung

```
SPLIT_SIZE = INPUT_SIZE / NUM_JOBS

Segment N (Offsets und Länge in Bytes, letztes Segment inkl. Rest):
  Lesen:     dd if=INPUT  iflag=count_bytes,skip_bytes count=$(part_bytes N) skip=$((N * SPLIT_SIZE))
  Schreiben: dd of=OUTPUT oflag=seek_bytes seek=$((N * SPLIT_SIZE)) conv=notrunc
```

Beliebige Eingabegrößen werden unterstützt: `size_calculation()` rundet
`SPLIT_SIZE` auf ein Vielfaches der Blockgröße ab; den nicht gleichmäßig
verteilbaren Rest überträgt der letzte Teil (`part_bytes()`), byte-genau über
die dd-Flags `count_bytes`/`skip_bytes`/`seek_bytes`.

---

## Pipe-Architektur

Je nach aktivierten Optionen wird die Pipe dynamisch zusammengebaut in `$FULL_CMD`
und dann per `eval "${FULL_CMD}"` ausgeführt.

### Backup lokal, unkomprimiert

```
dd if=INPUT ... | dd of=OUTPUT_PART ...  &
```

### Backup lokal, mit Checksumme

```
dd if=INPUT ... | tee >(sha256sum > PART.sha256) | dd of=OUTPUT_PART ...  &
```

### Backup lokal, mit gzip-Kompression

```
dd if=INPUT ... | gzip -LEVEL > OUTPUT_PART.gz  &
```

### Backup lokal, mit Checksumme + gzip

```
dd if=INPUT ... | tee >(sha256sum > PART.sha256) | gzip -LEVEL > OUTPUT_PART.gz  &
```

### Remote Clone (Netcat)

**Lokal:**
```
dd if=INPUT ... | nc REMOTE_HOST PORT  &
```

**Remote (startet zuerst als Listener):**
```
nc -N -l PORT | dd of=OUTPUT ...  &   (läuft im Hintergrund via nohup + SSH)
```

Das Skript prüft nach dem Start des Remote-Listeners per `ss -tln`, ob der Port
tatsächlich belegt ist (bis zu 3 Versuche mit 1 s Pause) bevor der lokale
`nc`-Client verbindet.

### Remote Backup (Netcat), unkomprimiert

**Lokal:**
```
dd if=INPUT ... | nc REMOTE_HOST PORT  &
```

**Remote:**
```
nc -N -l PORT | dd of=BASE-N.part bs=BLOCKSIZE  &
```

### Remote Clone (Netcat) mit Remote-Dekompression (`-c` + `-r c`)

Ein Clone muss auf der Gegenseite als Rohdaten ankommen. Komprimiert übertragen
lässt er sich daher nur, wenn dort wieder dekomprimiert wird — deshalb ist `-c`
im Clone-Modus ausschließlich mit `-r c` möglich.

**Lokal:**
```
dd if=INPUT ... | gzip -LEVEL | nc REMOTE_HOST PORT  &
```

**Remote:**
```
nc -N -l PORT | gzip -dc | dd of=OUTPUT ... seek=... conv=notrunc  &
```

### Remote Backup (Netcat) mit lokaler Kompression (`-c`)

`gzip` läuft auf der **lokalen** Maschine; über das Netz geht nur der
komprimierte Strom. Die Gegenseite schreibt ihn unverändert in die `.gz`-Datei
und benötigt selbst kein `gzip` (*local compression*).

**Lokal:**
```
dd if=INPUT ... | gzip -LEVEL | nc REMOTE_HOST PORT  &
```

**Remote:**
```
nc -N -l PORT | dd of=BASE-N.gz bs=BLOCKSIZE  &
```

### Remote Backup (Netcat) mit Remote-Kompression (`-c` + `-r c`)

`gzip` läuft auf dem **Remote-Host** und schreibt dort direkt die `.gz`-Datei.
Über das Netz gehen die Rohdaten: das entlastet die lokale CPU, spart aber
keine Bandbreite (dafür `-r n`).

**Lokal:**
```
dd if=INPUT ... | nc REMOTE_HOST PORT  &
```

**Remote:**
```
nc -N -l PORT | gzip -LEVEL > BASE-N.gz  &
```

### Remote Restore (Netcat) mit lokaler Dekompression

Beim Restore ist die Richtung umgekehrt: der Remote-Host ist der Sender, das
lokale Ziel der Empfänger. `zcat` läuft ebenfalls lokal (*local decompression*).

**Remote (Sender):**
```
dd if=BASE-N.gz bs=BLOCKSIZE iflag=fullblock | nc -N -l PORT   (bzw. BASE-N.part unkomprimiert)
```

**Lokal (Empfänger):**
```
nc REMOTE_HOST PORT </dev/null | zcat | dd of=OUTPUT ... seek=...  &
```

Ob der komprimierte Pfad genutzt wird, entscheidet `COMPRESSION` aus der
Metadatendatei — Restore und Check erkennen komprimierte Backups also
automatisch. **Wo** aus- bzw. eingepackt wird, bestimmt dagegen `-r`.

### Remote Restore (Netcat) mit Remote-Dekompression (`-r c`)

**Remote (Sender):**
```
zcat BASE-N.gz | nc -N -l PORT
```

**Lokal (Empfänger):**
```
nc REMOTE_HOST PORT </dev/null | dd of=OUTPUT ... seek=...  &
```

Die `.gz`-Teile sind in beiden Modi identisch: ein mit `-r c` erzeugtes Backup
lässt sich mit `-r n` wiederherstellen und umgekehrt.

### Remote Check eines komprimierten Backups

Der Check überträgt keine Nutzdaten über netcat: bei unkomprimierten Backups
läuft `sha256sum` auf dem Remote-Host, nur der Hash geht über SSH. Für
komprimierte Backups hängt es vom Modus ab:

```
ssh HOST "cat BASE-N.gz" | zcat | sha256sum        (-r n: lokal auspacken)
ssh HOST "zcat BASE-N.gz | sha256sum"              (-r c: remote auspacken)
```

Modus `n` braucht kein `gzip` auf der Gegenseite, überträgt dafür die
komprimierten Daten; Modus `c` überträgt nur den Hash. Verglichen werden in
allen Fällen die Hashes der **Rohdaten** des Segments.

### Abschluss der Remote-Empfänger

Beim Remote-Clone und Remote-Backup schreibt die Gegenseite: wenn der lokale
Sender fertig ist, kann dort noch gepuffertes Material unterwegs sein — im Modus
`c` muss zusätzlich `gzip` den Rest der Pipe verarbeiten. `wait_for_remote_listeners()`
wartet daher vor dem Schließen der SSH-Verbindung, bis der `sh -c`-Elternprozess
jedes Listeners beendet ist (`pgrep -f "nc -N -l [P]ORT"`; die erste Ziffer steht
in einer Zeichenklasse, damit die per SSH gestartete Shell sich nicht selbst
matcht). Ohne dieses Warten könnte ein direkt anschließender `ddpar-check.sh`
eine noch unvollständige Datei lesen. Fehlt `pgrep` auf der Gegenseite, wird
nicht gewartet.

---

## Metadaten-Datei

Beim Backup schreibt `ddpar.sh` eine Metadaten-Datei `<BASE>-metadata.txt`,
die alle Parameter enthält, die `ddpar-restore.sh` und `ddpar-check.sh` für
die Rekonstruktion benötigen:

```
NUM_JOBS=4
FILE_NAME=sdb
BLOCKSIZEBYTES=1048576
INPUT_SIZE=68719476736
INPUT_FILE_NAME=sdb
FILE_TYPE=block special (8/16)
SPLIT_SIZE=17179869184
COMPRESSION=1          # nur wenn komprimiert
COMPRESSION_LEVEL=6    # nur wenn komprimiert
```

**Wichtig:** Alle `grep`-Zugriffe auf diese Datei müssen mit `^`-Anker arbeiten
(`grep "^KEY="`), da sonst Präfix-Matches auftreten können (z.B. `COMPRESSION`
matcht auch `COMPRESSION_LEVEL`).

---

## Remote-Konzept

### SSH-Multiplexing

`ddpar.sh` öffnet eine persistente SSH-Master-Verbindung über einen Unix-Socket
(`SSH_SOCKET_PATH`). Alle weiteren SSH-Aufrufe (Befehle, Hintergrundprozesse)
laufen über diesen Kontroll-Socket, ohne erneute Authentifizierung.

```
ssh -o ControlMaster=auto -o ControlPersist=yes -S SOCKET HOST true
```

### Port-Auswahl

Für jeden Job wird ein Port aus dem Bereich **10000–42767** zufällig gewählt
(`REMOTE_PORT + PART_NUM`). Vor der Nutzung prüft `check_remote_port_availability()`
via `ss -tln`, ob der Port auf dem Remote-Host frei ist. Bei Kollision wird
ein neuer Port generiert.

### Remote-Modi (`-r`)

| Flag | Bedeutung | Implementierungsstatus |
|---|---|---|
| `n` | Netcat ohne Datenverschlüsselung | ✅ |
| `n` + `-c` | Netcat, [De]Kompression auf der lokalen Seite | ✅ (Backup/Restore/Check) |
| `c` + `-c` | Netcat, [De]Kompression auf der Remote-Seite | ✅ (Clone/Backup/Restore/Check) |
| `l` | Vollständig über SSH (verschlüsselt) | 🛑 nicht implementiert (fällt mit Warnung auf `n` zurück) |

Wer was komprimiert und was über das Netz geht:

| Vorgang | `-r n -c` | `-r c -c` |
|---|---|---|
| Clone | 🛑 nicht möglich (Warnung, unkomprimierter Clone) | lokal `gzip`, remote `gzip -dc` → **komprimierter** Transfer |
| Backup | lokal `gzip` → **komprimierter** Transfer | remote `gzip` → Rohdaten über das Netz, lokale CPU entlastet |
| Restore | remote sendet `.gz`, lokal `zcat` → **komprimierter** Transfer | remote `zcat` → Rohdaten über das Netz |
| Check | `.gz` über SSH holen, lokal auspacken | remote auspacken und hashen → nur der Hash über SSH |

Modus `n` braucht **kein** `gzip` auf der Gegenseite, Modus `c` schon
(`check_remote_commands_availability` prüft das). `-r c` ohne `-c` hat nichts zu
[de]komprimieren und verhält sich wie `n`; das Skript weist darauf hin.

---

## Funktionsübersicht (`ddpar.sh`)

| Funktion | Aufgabe |
|---|---|
| `option_analysis` | Kommandozeilenparameter parsen und validieren |
| `set_colors` | ANSI-Farbvariablen setzen (nur wenn Terminal Farben unterstützt) |
| `establish_ssh_connection` | SSH-Verbindung aufbauen (mit oder ohne Passwort via sshpass) |
| `connect_ssh` | SSH-Verbindung prüfen und ggf. aufbauen |
| `is_ssh_socket_alive` | Prüft ob der SSH-Kontroll-Socket noch aktiv ist |
| `execute_command` | Befehl lokal oder remote ausführen |
| `execute_remote_command` | Befehl immer remote via SSH ausführen |
| `execute_remote_background_command` | Befehl remote im Hintergrund starten (nohup) |
| `close_ssh_connection` | SSH-Multiplexing-Verbindung schließen |
| `check_commands_availability` | Prüft ob benötigte Tools lokal vorhanden sind |
| `check_remote_commands_availability` | Prüft ob benötigte Tools remote vorhanden sind |
| `input_analysis` | Typ und Größe der Eingabe bestimmen |
| `output_analysis` | Typ und Größe des Ziels bestimmen |
| `remote_port_generation` | Zufälligen Port im Bereich 10000–42767 generieren |
| `check_remote_port_availability` | Prüft ob ein Port auf dem Remote-Host frei ist |
| `size_calculation` | SPLIT_SIZE berechnen (auf Blockgröße abgerundet) |
| `part_bytes` | Bytes je Teil; der letzte Teil übernimmt den Rest |
| `clone_file` | Paralleler Clone einer regulären Datei |
| `clone_block` | Paralleler Clone eines Block-Devices |
| `run_clone_parts` | Gemeinsame Teil-Schleife für Clone (lokal und remote) |
| `backup_mode` | Backup in Teil-Dateien inkl. Metadaten (lokal und remote, optional komprimiert) |
| `setup_remote_listener` | Startet je Teil einen `nc`-Empfänger auf dem Remote-Host |
| `remote_compression_active` | Wahr, wenn [De]Kompression auf der Remote-Seite läuft (`-r c` + `-c`) |
| `wait_for_remote_listeners` | Wartet, bis die Remote-Empfänger (inkl. `gzip`) fertig geschrieben haben |
| `append_metadata` | Schreibt eine Zeile in die Metadatendatei (lokal oder remote) |
| `register_job` / `wait_for_jobs` | Sammeln der Exit-Codes aller parallelen Teil-Jobs |
