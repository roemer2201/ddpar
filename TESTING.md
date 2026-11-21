# ddpar testen

## Automatisierte Suite

Im Repository-Root ausführen. Die lokalen Tests verwenden temporäre Dateien.

```bash
make install-deps
make check
```

| Tests | Prüfumfang |
|---|---|
| `tests/cli.bats` | Hilfe, Pflichtargumente und Fehlerstatus |
| `tests/roundtrip.bats`, `tests/integrity.bats` | Bytegenauer Clone und Restore, gzip, Prüfsummen, ältere Metadaten, Abbruch, Alias- und Überschreibschutz |
| `tests/completion.bats`, `tests/completion_readline.py` | Befehlsnamen, lokale und entfernte Argumente, echte Tab-Eingaben in einer interaktiven Bash |
| `tests/blockdev.bats` | Clone, Backup, Restore und Vergleich auf eigens angelegten Loop-Geräten |
| `tests/remote.bats` | SSH und netcat, beide Kompressionsmodi, beschädigte Teile, Fehlerstatus und parallele Verbindungen |
| `tests/harness.bats` | Fehlerweitergabe des Docker-Testskripts bei teilweise erfolgreichen Segmentvergleichen |

`make test-verbose` zeigt Befehle und Ausgaben. `make test-log` schreibt sie
nach `/tmp/ddpar-test.log`. `make lint` führt ShellCheck einschließlich des
gemeinsamen Skripts, der Completion und der Docker-Skripte aus.

## Integration

`make test-integration` führt die Blockgeräte- und Remote-Suites aus. Die
Loop-Tests benötigen root und nutzbare Loop-Geräte. Die SSH-Tests verwenden
standardmäßig einen passwortlosen Zugang zu `localhost`, OpenBSD-netcat und
`ss`. Bei einem über `DDPAR_REMOTE_TEST_HOST` gesetzten Host müssen die lokalen
temporären Testverzeichnisse **unter denselben Pfaden** auf beiden Seiten
zugänglich sein. Für getrennte Dateisysteme gibt es das Zwei-Container-Harness.

```bash
./testing-docker/run-remote-tests.sh
```

Lokal überspringt Bats fehlende Integrationsvoraussetzungen. Der Integrationstest
in GitHub Actions verlangt, dass alle Fälle laufen. Dort werden außerdem das
Debian-Paket, ShellCheck, die lokale Suite und der echte Zwei-Container-Aufbau
geprüft. [Docker-Testumgebung](testing-docker/README.md)

## Manueller Dateitest

Diese Bash-Befehle prüfen denselben Inhalt als Quelle, Backup, wiederhergestellte
Datei und Clone. Die ungerade Länge erzwingt ein ungleich großes letztes Segment.

```bash
(
  set -eu
  workdir=$(mktemp -d)
  trap 'rm -rf -- "${workdir}"' EXIT
  mkdir "${workdir}/backup"
  head -c 1048593 /dev/urandom > "${workdir}/source.img"

  ./ddpar.sh -i "${workdir}/source.img" -o "${workdir}/backup" -m backup -c -s -j 3 -b 4096
  base="${workdir}/backup/source.img"
  ./ddpar-check.sh -s "${workdir}/source.img" -b "${base}"
  ./ddpar-restore.sh -i "${base}" -o "${workdir}/restored.img" -y
  ./ddpar-check.sh -b "${base}" -d "${workdir}/restored.img"
  cmp "${workdir}/source.img" "${workdir}/restored.img"

  ./ddpar.sh -i "${workdir}/source.img" -o "${workdir}/clone.img"
  ./ddpar-check.sh -s "${workdir}/source.img" -d "${workdir}/clone.img"
)
```

## Debian-Paket prüfen

```bash
make install-build-deps
make deb
deb="../ddpar_$(dpkg-parsechangelog -S Version)_all.deb"
lintian --fail-on error "${deb}"
(
  set -eu
  pkgroot=$(mktemp -d)
  trap 'rm -rf -- "${pkgroot}"' EXIT
  dpkg-deb -x "${deb}" "${pkgroot}"
  python3 debian/tests/smoke --root "${pkgroot}"
)
```

Der Paketbau führt die lokalen Skript- und Completion-Tests aus. Der Smoke-Test
prüft alle sechs installierten Aufrufnamen, den registrierten Completion-Handler
und einen Dateirundlauf. Auf einem System mit installiertem Paket genügt
`python3 debian/tests/smoke`.
