# Code-Review: ddpar

Stand: `main` bei Commit `8ded04a49b211027c67a6a4939b16bb9e7649d7c` (26.09.2026). Geprüft wurden die drei ausführbaren Hauptskripte, die Tests, der CI-Workflow und die Projektdokumentation. Der Schwerpunkt liegt auf Datenintegrität, Rückgabestatus und Remote-Fehlern.

## Befunde

### 1. [P1] Ein Dateiname kann lokale Shell-Befehle ausführen

**Fundstelle:** [`ddpar.sh:267–286`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L267-L286), aufgerufen unter anderem in [`check_output_access():399–404`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L394-L405).

`execute_command` setzt einen Befehl aus einem Pfad zusammen und parst ihn lokal erneut mit `eval`. Die doppelten Anführungszeichen um den Pfad verhindern bei dieser zweiten Auswertung keine Command Substitution. Reproduziert mit einem bereits angelegten Zielverzeichnis, dessen Name wörtlich `out$(touch executed)` lautet: Während des Clone-Aufrufs wurde die Datei `executed` angelegt. Ein präparierter Pfad kann somit Befehle mit den Rechten des ausführenden Benutzers auslösen, gerade beim üblichen Root-Aufruf für Blockgeräte.

**Empfehlung:** Lokale Operationen direkt mit Argument-Arrays ausführen; Remote-Befehle separat und für die Remote-Shell sicher quotieren. Pfade niemals als ausführbaren Shell-Quelltext behandeln. Regressionstest mit `$()`, Leerzeichen und einfachen Anführungszeichen in Dateinamen.

### 2. [P1] Verweigerter Clone meldet Erfolg

**Fundstelle:** [`ddpar.sh:530–541`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L530-L541) und [`ddpar.sh:933–971`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L933-L971).

Ist die Zieldatei bereits vorhanden und `-f` fehlt, liefert `clone_file` korrekt 1. Der Aufrufer ignoriert diesen Status, `wait_for_jobs` sieht keine gestarteten Jobs und setzt den Gesamterfolg auf 0. Reproduziert: Zielinhalt blieb `original`, Prozessstatus war trotzdem 0. Dasselbe Muster betrifft den abgelehnten Dialog zur Anlage eines Zielverzeichnisses.

**Empfehlung:** Rückgabewerte der vorbereitenden Clone-Funktionen unmittelbar auswerten und beim Fehlschlag einen Fehlerstatus setzen; bei null gestarteten Jobs keinen Erfolg ausgeben.

### 3. [P1] Restore akzeptiert verkürzte Backup-Teile als vollständig

**Fundstelle:** [`ddpar-restore.sh:334–395`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar-restore.sh#L334-L395).

Bei einem unkomprimierten Teil endet das lesende `dd` am EOF erfolgreich, und auch das schreibende `dd` akzeptiert weniger als `count=COUNT_BYTES` gelieferte Bytes. `pipefail` erkennt daher keinen Fehler. Reproduziert mit einer 1200-Byte-Quelle und zwei Teilen: zweiten Teil nach dem Backup auf 10 Bytes gekürzt; der Restore lieferte Status 0, die wiederhergestellte Datei unterschied sich von der Quelle. Bei einem Blockgerät können an dieser Stelle alte Daten stehen bleiben.

**Empfehlung:** Vor beziehungsweise während des Restore für jeden Teil die tatsächlich gelesene Rohdatenlänge mit `part_bytes` vergleichen. Fehlende/verkürzte Teile als Abbruch melden; zusätzlich vorhandene Prüfsummen prüfen, sofern verfügbar. Regressionstest mit abgeschnittenem letztem Teil.

### 4. [P1] Der Check kann null Segmente prüfen und trotzdem „erfolgreich“ melden

**Fundstelle:** [`ddpar-check.sh:494–521`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar-check.sh#L494-L521) und [`ddpar-check.sh:543–549`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar-check.sh#L543-L549).

Die zwei getrennten Typbedingungen starten den Vergleich nur, wenn der in den Metadaten hinterlegte Typ und der aktuelle Typ beide Blockgerät oder beide Nicht-Blockgerät sind. Sonst wird keine Vergleichsfunktion aufgerufen. `wait_for_jobs` erhält eine leere Jobliste und meldet Erfolg. Reproduziert: `FILE_TYPE` in der Metadatendatei auf `block special (8/0)` gesetzt und die reguläre Quelldatei nach dem Backup verändert; der Check gab Status 0 und „Alle Segmente stimmen überein“ aus, ohne ein Segment zu prüfen. Auch ein echter Vergleich eines Blockgeräte-Backups mit einem ausgelesenen Dateiabbild fällt in diesen Pfad.

**Empfehlung:** Die passenden zwei Pfade unabhängig von der Typkombination vergleichen oder eine nicht unterstützte Kombination ausdrücklich mit Fehler beenden. Vor der Erfolgsmeldung verifizieren, dass genau `NUM_JOBS` Vergleiche gestartet und abgeschlossen wurden.

### 5. [P1] Remote-Empfängerfehler gehen verloren

**Fundstelle:** [`ddpar.sh:303–315`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L303-L315), [`ddpar.sh:630–684`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L630-L684) und [`ddpar.sh:849–879`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L849-L879).

Remote wird eine `nc | dd`- oder `nc | gzip`-Pipeline abgekoppelt gestartet. SSH bestätigt nur den Start, nicht den Abschlussstatus dieser Pipeline. Lokal werden ausschließlich Sender-Jobs gewartet; `wait_for_remote_listeners` beobachtet per `pgrep` nur, ob ein Prozess noch existiert. Auch nach einem Timeout wird bloß gewarnt und der Gesamtablauf kann Status 0 liefern. Bei Schreibfehler, vollem Dateisystem oder fehlgeschlagener Kompression kann das Backup bzw. der Clone daher als erfolgreich gelten, obwohl das Remote-Ziel unvollständig ist. Dieser Befund wurde aus dem Kontrollfluss abgeleitet; ein Zwei-Host-Fehlertest wurde hier nicht ausgeführt.

**Empfehlung:** Pro Remote-Job dessen Exit-Status einschließlich aller Pipeline-Glieder über einen verlässlichen Rückkanal einholen. Timeout und fehlende Statusmeldung als Fehler behandeln; anschließend einen gezielten Test mit absichtlich fehlschlagendem Remote-Schreibvorgang ergänzen. Auch `ddpar-restore.sh:163–171,199–244` startet Remote-Sender ohne Rückmeldung ihres Abschlussstatus.

### 6. [P1] `-j 0` erzeugt ein leeres Backup mit Exit-Code 0

**Fundstelle:** [`ddpar.sh:62–69`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L62-L69), [`ddpar.sh:461–478`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L461-L478) und [`ddpar.sh:753–809`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L753-L809).

Für `-j` und `-b` fehlt eine Bereichsprüfung. Reproduziert mit `-j 0 -m backup`: Bash meldete Division durch 0, es wurde kein Teil-Job gestartet, das Skript endete aber mit Status 0 und einer Erfolgsmeldung. Ein solcher Aufruf kann als erfolgreiches Backup in einer Automatisierung gewertet werden.

**Empfehlung:** Ganzzahlige Werte strikt prüfen (`NUM_JOBS >= 1`, `BLOCKSIZEBYTES >= 1`) und bei fehlerhafter Arithmetik sofort abbrechen. Auch einen nicht gestarteten Job-Satz als Fehler behandeln.

### 7. [P2] Erzwungener Clone einer größeren Zieldatei lässt alte Enddaten stehen

**Fundstelle:** [`ddpar.sh:530–541`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L530-L541) und [`ddpar.sh:582–615`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L582-L615).

Der Clone schreibt mit `conv=notrunc`, kürzt eine bestehende reguläre Zieldatei aber nicht. Reproduziert: 1200-Byte-Quelle auf 2200-Byte-Ziel mit `-f`; Status 0, Ziel weiterhin 2200 Bytes und kein bytegleiches Abbild. Ein segmentweiser Check bis zur Quellgröße bemerkt den Anhang ebenfalls nicht.

**Empfehlung:** Reguläre Zieldateien vor dem Schreiben auf genau `INPUT_SIZE` setzen und bei Datei-Checks die Gesamtgröße vergleichen. Blockgeräte dürfen dabei nicht gekürzt werden.

### 8. [P2] Leerzeichen im Backup-Basisnamen beschädigen Wiederholung und Restore

**Fundstelle:** [`ddpar.sh:722–726`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar.sh#L722-L726) und [`ddpar-restore.sh:399–407`](https://github.com/roemer2201/ddpar/blob/8ded04a49b211027c67a6a4939b16bb9e7649d7c/ddpar-restore.sh#L399-L407).

Die vorhandene Metadatendatei wird wegen unquotierter Expansion bei `[ -f ${METADATA_FILE} ]` nicht erkannt. Ein zweites Backup mit `-n 'with space'` hängt deshalb neue Metadaten an (im Test zweimal `NUM_JOBS=`). Im Restore zerlegen `dirname $INPUT` und `basename $INPUT` denselben Pfad; die Metadatendatei wird unter falschem Namen gesucht. Beide Backup-Aufrufe meldeten Status 0, der Restore schlug fehl.

**Empfehlung:** Dateinamen an allen Übergabestellen als einzelne, quotierte Argumente behandeln; vor erneutem Backup Metadaten und Teile konsistent ersetzen. Einen Roundtrip mit Leerzeichen im Basisnamen testen.

## Prüfung und Grenzen

- `bash -n ddpar.sh ddpar-restore.sh ddpar-check.sh` war erfolgreich.
- Die reproduzierten Fälle wurden mit kleinen temporären regulären Dateien getestet; dabei wurden keine Blockgeräte beschrieben.
- `bats` und `shellcheck` waren in der Ausführungsumgebung nicht installiert. Die vorhandenen Bats-Tests und `make lint` wurden daher nicht ausgeführt.
- Der Remote-Befund beruht auf der Analyse des Codes. Ein Integrationstest gegen einen SSH-/netcat-Testhost sollte seine Auswirkungen auf die verschiedenen Remote-Modi absichern.
