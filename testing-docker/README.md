# Remote-Tests mit zwei Containern

Die Compose-Dienste `source` und `target` haben getrennte Dateisysteme. Auf
`source` erzeugt der Entrypoint eine Zufallsdatei. Die Programme im Repository
sind in beiden Containern unter `/opt/ddpar` schreibgeschützt eingebunden.
SSH steuert den Test, OpenBSD-netcat überträgt die Daten über das Compose-Netz.

## Automatischer Lauf

Docker und das Compose-Plugin müssen verfügbar sein. Aufruf im Repository-Root:

```bash
./testing-docker/run-remote-tests.sh
```

Der Runner prüft einen rohen und einen komprimierten Clone sowie Backup,
Restore und Vergleich mit lokaler und entfernter gzip-Verarbeitung. Er
vergleicht die SHA256-Werte der Dateien auf den beiden Hosts und wertet den
Exitstatus jedes `ddpar-check` aus. Ein mit `-r c` erzeugtes Backup wird
zusätzlich mit `-r n` wiederhergestellt. Jeder Aufruf verwendet die
Testverzeichnisse `/backup*`, `/clone_dest*` und `/restore` neu.

| Option | Wirkung |
|---|---|
| `--no-build` | Vorhandenes Image für den Lauf verwenden |
| `--verbose` | Ausgabe der ddpar-Aufrufe anzeigen |
| `--keep` | Container nach dem Test zum Untersuchen weiterlaufen lassen |
| `--help` | Aufrufoptionen anzeigen |

Die CI führt diesen Ablauf mit einer 4-MiB-Datei aus. Manuell beträgt der
Standardwert 64 MiB. Änderungen an den ddpar-Skripten sind sofort sichtbar.
Änderungen am Dockerfile oder Entrypoint erfordern einen neuen Build.

## Manueller Lauf

```bash
cd testing-docker
TEST_SIZE_MB=16 docker compose up -d --build
docker compose exec source ssh -o StrictHostKeyChecking=accept-new root@target hostname
docker compose exec source bash
```

Im Container `source` lässt sich ein einzelner Übertragungsweg nachstellen:

```bash
./ddpar.sh -i /data/source.img -o /backup -m backup -c -r c -R root@target
./ddpar-check.sh -s /data/source.img -b /backup/source.img -r c -R root@target
./ddpar-restore.sh -i /backup/source.img -o /restore/result.img -r n -R root@target -y
cmp /data/source.img /restore/result.img
```

Jeder Container erzeugt beim ersten Start eigene SSH-Host- und Benutzerschlüssel.
In zwei Compose-Volumes liegen die öffentlichen Benutzerschlüssel. Jeder
Dienst kann seinen Schlüssel aktualisieren und den Schlüssel des Partners
lesen. Standardmäßig ist nur Schlüsselanmeldung aktiviert. Für einen
ausdrücklichen Passworttest kann beim Start `ROOT_PASSWORD` gesetzt werden.
Compose veröffentlicht keine Host-Ports.

`TEST_SIZE_MB` wirkt beim Anlegen von `/data/source.img`. Für eine neue
Dateigröße beide Testcontainer abbauen und mit dem neuen Wert starten.
Für Blockgerätetests verwendet die [Integrationstestsuite](../TESTING.md#integration)
temporäre Loop-Geräte. Der Standardaufbau hier arbeitet ohne privilegierte Container.

Nach dem manuellen Lauf auf dem Host aus dem Verzeichnis `testing-docker/`:

```bash
docker compose down -v
```
