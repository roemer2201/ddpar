# TESTING

Dieses Dokument enthält Beispiel-Kommandos zum Testen aller implementierten Funktionen von ddpar.

---

## Voraussetzungen

### Variablen definieren

Die folgenden Variablen in der Shell setzen und in allen Kommandos verwenden:

```bash
# Lokal – Quelllaufwerk (Block Device)
SOURCE_DEV=/dev/sdb

# Lokal – Ziellaufwerk für Clone (Block Device, mindestens so groß wie SOURCE_DEV)
DEST_DEV=/dev/sdc

# Lokal – Testdatei (wird unter "Testdaten erstellen" angelegt)
SOURCE_FILE=/tmp/ddpar_test.img

# Lokal – Zielverzeichnis für File-Clone
DEST_DIR=/tmp/ddpar_clone_dest

# Lokal – Backup-Verzeichnis
BACKUP_DIR=/mnt/backup

# Remote – SSH-Verbindung
REMOTE_HOST=user@192.168.1.100

# Remote – Ziellaufwerk auf dem Remote-Host (Block Device)
REMOTE_DEST_DEV=/dev/sdb

# Remote – Zielverzeichnis für File-Clone auf dem Remote-Host
REMOTE_DEST_DIR=/tmp/ddpar_clone_dest
```

### Testdaten erstellen

Eine 64 MiB große Testdatei anlegen (teilbar durch 4 Jobs × 1 MiB Blocksize):

```bash
dd if=/dev/urandom of=$SOURCE_FILE bs=1M count=64
```

Zielverzeichnisse anlegen:

```bash
mkdir -p $DEST_DIR
mkdir -p $BACKUP_DIR
```

---

## 1. Lokale Tests – unkomprimiert

### 1.1 Clone – Block Device

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $DEST_DEV -m clone
```

> **Hinweis:** `$DEST_DEV` muss mindestens so groß sein wie `$SOURCE_DEV`.

### 1.2 Clone – Datei

```bash
./ddpar.sh -i $SOURCE_FILE -o $DEST_DIR -m clone
```

> **Hinweis:** Der Output `-o` muss ein vorhandenes Verzeichnis sein. Das geklonte
> File wird dort als `ddpar_test.img` abgelegt.

### 1.3 Backup – Block Device

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $BACKUP_DIR -m backup
```

Erzeugte Dateien: `$BACKUP_DIR/sdb-0.part` … `sdb-3.part` + `sdb-metadata.txt`

### 1.4 Backup – Datei

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup
```

Erzeugte Dateien: `$BACKUP_DIR/ddpar_test.img-0.part` … + `ddpar_test.img-metadata.txt`

### 1.5 Restore – Block Device

```bash
sudo ./ddpar-restore.sh -i $BACKUP_DIR/sdb -o $DEST_DEV
```

> **Hinweis:** Erfordert ein vorher erstelltes Backup aus Test 1.3.
> Der Parameter `-i` ist der Basispfad **ohne** das abschließende `-`.

### 1.6 Restore – Datei

```bash
./ddpar-restore.sh -i $BACKUP_DIR/ddpar_test.img -o $DEST_DIR/ddpar_test.img
```

> **Hinweis:** Erfordert ein vorher erstelltes Backup aus Test 1.4.

---

## 2. Lokale Tests – komprimiert (gzip)

### 2.1 Backup – Block Device (gzip)

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $BACKUP_DIR -m backup -c
```

Erzeugte Dateien: `$BACKUP_DIR/sdb-0.gz` … `sdb-3.gz` + `sdb-metadata.txt`

### 2.2 Backup – Datei (gzip)

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -c
```

### 2.3 Restore – Block Device (gzip)

```bash
sudo ./ddpar-restore.sh -i $BACKUP_DIR/sdb -o $DEST_DEV
```

> **Hinweis:** Erfordert ein vorher erstelltes komprimiertes Backup aus Test 2.1.
> Das Skript erkennt die Komprimierung automatisch über die Metadaten.

### 2.4 Restore – Datei (gzip)

```bash
./ddpar-restore.sh -i $BACKUP_DIR/ddpar_test.img -o $DEST_DIR/ddpar_test.img
```

> **Hinweis:** Erfordert ein vorher erstelltes komprimiertes Backup aus Test 2.2.

---

## 3. Prüfung (ddpar-check.sh)

> **Hinweis:** Die Prüfung eines Clones ist laut Status-Tabelle noch nicht implementiert (🛑).
> Die folgenden Tests setzen ein vorhandenes Backup voraus.

### 3.1 Quelle gegen Backup prüfen (Source ↔ Backup)

Block Device:
```bash
sudo ./ddpar-check.sh -b $BACKUP_DIR/sdb -s $SOURCE_DEV
```

Datei:
```bash
./ddpar-check.sh -b $BACKUP_DIR/ddpar_test.img -s $SOURCE_FILE
```

### 3.2 Backup gegen Ziel prüfen (Backup ↔ Destination)

Block Device:
```bash
sudo ./ddpar-check.sh -b $BACKUP_DIR/sdb -d $DEST_DEV
```

Datei:
```bash
./ddpar-check.sh -b $BACKUP_DIR/ddpar_test.img -d $DEST_DIR/ddpar_test.img
```

---

## 4. Remote Tests – SSH + Netcat

> **Voraussetzung:** SSH-Zugang zu `$REMOTE_HOST` muss eingerichtet sein
> (passwortlos per Key oder interaktiv per Passwort).
> `nc` (netcat) und `ss` müssen auf dem Remote-Host verfügbar sein.

### 4.1 Remote Clone – Block Device, unkomprimiert (Modus n)

Modus `n`: SSH-Verbindungsaufbau verschlüsselt, Dateiübertragung über Netcat unverschlüsselt.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r n -R $REMOTE_HOST
```

### 4.2 Remote Clone – Datei, unkomprimiert (Modus n)

> **Abweichung:** `-o` ist hier ein Verzeichnis auf dem Remote-Host.

```bash
./ddpar.sh -i $SOURCE_FILE -o $REMOTE_DEST_DIR -m clone -r n -R $REMOTE_HOST
```

### 4.3 Remote Clone – Block Device, vollständig verschlüsselt (Modus l)

Modus `l`: Gesamte Übertragung läuft durch den SSH-Tunnel.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r l -R $REMOTE_HOST
```

### 4.4 Remote Clone – Block Device, lokale Kompression (Modus n + -c)

Daten werden lokal mit gzip komprimiert, dann per Netcat übertragen und remote dekomprimiert.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r n -c -R $REMOTE_HOST
```

### 4.5 Remote Clone – Block Device, remote Kompression (Modus c)

Kompression findet auf der Remote-Seite statt.

```bash
sudo ./ddpar.sh -i $SOURCE_DEV -o $REMOTE_DEST_DEV -m clone -r c -R $REMOTE_HOST
```

### 4.6 Remote Backup – nicht implementiert 🛑

Remote Backup (`-m backup` mit `-r`) ist laut Status-Tabelle noch nicht implementiert.

### 4.7 Remote Restore – nicht implementiert 🛑

Remote Restore über `ddpar-restore.sh` ist laut Status-Tabelle noch nicht implementiert.

---

## 5. Zusatzoptionen

Die folgenden Optionen können mit den meisten Szenarien oben kombiniert werden.

### 5.1 Checksummen aktivieren (-s)

Beim Backup wird pro Teil eine SHA256-Checksumme erstellt:

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -s
```

### 5.2 Anzahl der Jobs anpassen (-j)

> **Abweichung:** Die Eingabegröße muss durch die Anzahl der Jobs und die Blockgröße
> gleichmäßig teilbar sein. Bei `$SOURCE_FILE` (64 MiB) sind z.B. 2 oder 8 Jobs möglich.

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -j 2
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -j 8
```

### 5.3 Blockgröße anpassen (-b)

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -b 4194304
```

### 5.4 Debug-Modus (-d)

> **Achtung:** Im Debug-Modus werden Passwörter im Klartext ausgegeben.

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -d
```

### 5.5 Force-Modus (-f)

Überschreibt vorhandene Dateien oder ignoriert Speicherplatz-Warnungen:

```bash
./ddpar.sh -i $SOURCE_FILE -o $BACKUP_DIR -m backup -f
```
