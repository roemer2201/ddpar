# Architektur und Backup-Format

## Segmentierung

`ddpar`, `ddpar-restore` und `ddpar-check` laden `ddpar-common.sh` neben dem
aufgelösten Einstiegsskript. Jeder Worker verarbeitet einen Bytebereich.
Die normale Teilgröße ergibt sich aus ganzzahliger Division.

```text
SPLIT_SIZE = max(BLOCKSIZEBYTES, (INPUT_SIZE / NUM_JOBS / BLOCKSIZEBYTES) * BLOCKSIZEBYTES)
START      = Segmentnummer * SPLIT_SIZE
```

Der letzte Worker übernimmt den Rest. Liegt ein Startoffset hinter dem
Eingabeende, hat das Segment Länge null. Auch leere Eingaben besitzen somit
die in den Metadaten angegebene Anzahl von Teilen. Die GNU-dd-Flags
`count_bytes`, `skip_bytes` und `seek_bytes` geben Längen und Offsets in Bytes
an. `conv=notrunc` verhindert das gegenseitige Kürzen durch parallele Schreiber.

## Backup-Dateien

| Datei | Inhalt |
|---|---|
| `<Basis>-metadata.txt` | Geometrie, Dateiname, Format und Status |
| `<Basis>-N.part` oder `<Basis>-N.gz` | Rohdaten oder ein eigenständiger gzip-Strom für das nullbasiert nummerierte Segment N |
| `<Basis>-N.sha256` | Optionaler SHA256-Wert der **unkomprimierten** Daten im stdin-Format von `sha256sum` |
| `<Basis>-metadata.txt.old` | Vorherige Metadaten bei Wiederverwendung des Basisnamens. Die früheren Teile werden überschrieben. |

Beispiel eines abgeschlossenen lokalen Backups mit zwei komprimierten Teilen
und Prüfsummen, bei dem der letzte Teil ein zusätzliches Byte enthält.

```text
BACKUP_STATE=complete
NUM_JOBS=2
PART_CHECKSUMS=1
FILE_NAME=disk
BLOCKSIZEBYTES=4096
INPUT_SIZE=8193
INPUT_FILE_NAME=source.img
FILE_TYPE=data
SPLIT_SIZE=4096
COMPRESSION=1
COMPRESSION_LEVEL=6
```

Der Parser trennt jede Zeile am ersten Gleichheitszeichen. Zahlen werden vor
der Bash-Arithmetik auf Wertebereich und Produkte geprüft. Ein gesetzter
`FILE_NAME` muss ein einzelner Dateiname sein. `INPUT_FILE_NAME` und `FILE_TYPE`
beschreiben die Quelle. Beim Restore in ein Verzeichnis bestimmt `FILE_NAME`
den Zieldateinamen, ersatzweise der mit `-i` angegebene Basisname.

Während des Backups steht `BACKUP_STATE=incomplete` in den Metadaten.
Erst wenn alle Worker erfolgreich waren und alle Teile die erwartete
Rohdatenlänge haben, setzt der Ersteller `complete`. Ältere Backups dürfen
`BACKUP_STATE` und `PART_CHECKSUMS` weglassen. Fehlt `INPUT_SIZE`, gilt
die frühere Konvention `NUM_JOBS * SPLIT_SIZE`.

## Integritätsprüfung

Der Restore prüft vor dem Öffnen des Ziels die Länge jedes Teils.
Bei gzip liest er den Strom bis zum Trailer. Bei `PART_CHECKSUMS=1` müssen
alle Prüfsummen vorliegen und stimmen. Bei älteren Backups prüft er
vorhandene Prüfsummen. Ein separater lokaler Backup-Vergleich mit
`ddpar-check` benötigt für jeden Teil eine Prüfsumme.

Beim Schreiben zählt `ddpar_write_segment` die empfangenen Bytes mit einem
explizit abgewarteten `wc`-Prozess und begrenzt `dd` auf die Segmentlänge.
So wird ein zu früher EOF auch dann erkannt, wenn `dd` erfolgreich endet.
Bestehende reguläre Restore-Ziele werden auf die Bildlänge gebracht. Bei
Blockgeräten bleibt ein größerer Bereich hinter dem Ende des Bildes erhalten.

## Remote-Worker und Fehlerbehandlung

Jeder Aufruf steuert den Remote-Host über einen eigenen SSH-Control-Socket in
einem privaten temporären Verzeichnis. Befehle laufen in Bash mit `pipefail`.
Der Datenkanal für Backup, Restore und Clone nutzt OpenBSD-netcat im
vertrauenswürdigen Netz. Die unterschiedlichen Kompressionspfade beschreibt
die [Bedienungsanleitung](README.md#remote-ssh--netcat).

Für jeden Transfer startet der Remote-Host einen Listener auf einem freien
TCP-Port im Bereich 10000 bis 42767. `ss` prüft den lokalen TCP-Listen-Port
auf dem Remote-Host. Die Worker starten mit `nohup setsid`, damit ein großer
Lauf keine dauerhafte SSH-Sitzung pro Worker belegt. Ein privates Verzeichnis
`/tmp/ddpar-status.*` enthält pro Worker die folgenden Dateien.

| Endung | Zweck |
|---|---|
| `.pid` und `.proc` | Prozessgruppen-ID für den Abbruch und PID im sichtbaren Linux-procfs |
| `.rc` | Exitstatus der Pipeline, per Umbenennen veröffentlicht |
| `.log` | Diagnoseausgabe der Pipeline |

Der Aufrufer wartet auf die lokalen Prozesse und fragt anschließend die
Remote-Ergebnisse ab. Ein Fehler eines Workers, eine unterbrochene Verbindung
oder ein fehlender Status lässt den Auftrag fehlschlagen. Das Inaktivitätslimit
gilt für die netcat-Clients. Für das abschließende Schreiben des Remote-Workers
gibt es kein festes Zeitlimit.
Der Remote-Check vergleicht über SSH und begrenzt die Zahl gleichzeitig
laufender Hash-Sitzungen auf vier.
