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
automatisch.

### Remote Check eines komprimierten Backups

Der Check überträgt normalerweise keine Nutzdaten: bei unkomprimierten Backups
läuft `sha256sum` auf dem Remote-Host, nur der Hash geht über SSH. Für
komprimierte Backups wird die `.gz`-Datei über SSH geholt und **lokal**
ausgepackt, damit auch hier kein `gzip` auf der Gegenseite nötig ist:

```
ssh HOST "cat BASE-N.gz" | zcat | sha256sum      (lokal)
```

Verglichen werden in beiden Fällen die Hashes der **Rohdaten** des Segments.

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
| `n` + `-c` | Netcat, Kompression/Dekompression auf der lokalen Seite | ✅ (Backup/Restore/Check) |
| `l` | Vollständig über SSH (verschlüsselt) | ⚙️ teilweise |
| `c` | Kompression auf der Remote-Seite | ⚙️ teilweise |

`-c` im **Clone**-Modus ist noch nicht umgesetzt: der Clone müsste auf der
Gegenseite wieder dekomprimiert werden (remote decompression). Das Skript gibt
dort eine Warnung aus und klont unkomprimiert.

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
| `append_metadata` | Schreibt eine Zeile in die Metadatendatei (lokal oder remote) |
| `register_job` / `wait_for_jobs` | Sammeln der Exit-Codes aller parallelen Teil-Jobs |
