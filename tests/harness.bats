#!/usr/bin/env bats
# Verify the two-host runner's handling of the checker exit status.

load helpers

@test "Docker harness reports a failed check even after a successful segment" {
  mkdir "${TMP}/bin"
  cat > "${TMP}/bin/docker" <<'STUB'
#!/bin/bash
case "${*: -1}" in
  *ddpar-check.sh*)
    echo 'Segment 0: OK'
    echo 'Segment 1: read error'
    exit 1 ;;
  *sha256sum*) echo 'fixture-digest  source.img' ;;
esac
STUB
  chmod +x "${TMP}/bin/docker"
  vrun env PATH="${TMP}/bin:${PATH}" "${REPO_ROOT}/testing-docker/run-remote-tests.sh" --no-build
  [ "${status}" -eq 1 ]
  for entry in '/backup/source.img (mode n)' '/backup_gz/source.img (mode n)' '/backup_rc/source.img (mode c)'; do
    [[ "${output}" == *"[FAIL] Remote check: ${entry}"* ]]
  done
  [[ "${output}" != *'ALLE Remote-Szenarien bestanden'* ]]
  [[ "${output}" == *'[PASS] Remote-Clone komprimiert'* || "${output}" == *'[PASS] Remote-Clone (-r c -c)'* ]]
}
