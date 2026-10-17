#!/usr/bin/env bats
# Regression tests for data integrity and destination protection.
# Flow: create an isolated backup; inject one defect; assert failure before
# destination changes, or compare the complete successful result byte for byte.

load helpers

# A tiny, uneven input exercises partial and empty segments with default jobs.
small_backup() {
  printf '1234567890123456789' > "${TMP}/source"
  mkdir -p "${TMP}/backup"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -m backup "$@"
  [ "${status}" -eq 0 ]
}

@test "Local check reads actual parts, including missing and corrupt backups" {
  for mode in raw gzip; do
    local args=(-s)
    [ "${mode}" = gzip ] && args+=(-c)
    small_backup "${args[@]}"
    local part="${TMP}/backup/source-0.part"
    if [ "${mode}" = gzip ]; then
      part="${TMP}/backup/source-0.gz"
      printf 'xxxxxxxxxxxxxxxxxxx' | gzip > "${part}"
    else
      printf 'xxxxxxxxxxxxxxxxxxx' > "${part}"
    fi
    vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/source" -b "${TMP}/backup/source"
    [ "${status}" -ne 0 ]
    rm -- "${part}"
    vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/source" -b "${TMP}/backup/source"
    [ "${status}" -ne 0 ]
  done
}

@test "Restore truncates existing targets and handles empty files" {
  for mode in raw gzip; do
    local args=()
    [ "${mode}" = gzip ] && args+=(-c)
    small_backup "${args[@]}"
    printf '%0100d' 0 > "${TMP}/target"
    vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y -P
    [ "${status}" -eq 0 ]
    cmp "${TMP}/source" "${TMP}/target"
    : > "${TMP}/source"
    vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -m backup "${args[@]}"
    [ "${status}" -eq 0 ]
    vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
    [ "${status}" -eq 0 ]
    [ ! -s "${TMP}/target" ]
  done
}

@test "Restore rejects valid gzip with short or long payload before touching target" {
  for payload in x 12345678901234567890; do
    small_backup -c
    printf '%s' "${payload}" | gzip > "${TMP}/backup/source-0.gz"
    printf 'preserve' > "${TMP}/target"
    vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
    [ "${status}" -ne 0 ]
    [ "$(cat "${TMP}/target")" = preserve ]
  done
}

@test "Restore validates gzip CRC and available raw checksums" {
  small_backup -c -s
  printf '\000\000\000\000' | dd of="${TMP}/backup/source-0.gz" bs=1 seek=20 conv=notrunc status=none
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/target" ]

  small_backup -s
  printf 'xxxxxxxxxxxxxxxxxxx' > "${TMP}/backup/source-0.part"
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/target" ]
}

@test "Clone resolves directory target before checking overwrite permission" {
  printf 'source' > "${TMP}/source"
  mkdir "${TMP}/dest"
  printf 'preserve' > "${TMP}/dest/source"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/dest"
  [ "${status}" -ne 0 ]
  [ "$(cat "${TMP}/dest/source")" = preserve ]
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/dest" -f
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source" "${TMP}/dest/source"
}

@test "Clone creates a missing file and follows source and destination symlinks" {
  printf 'source bytes' > "${TMP}/source"
  ln -s "${TMP}/source" "${TMP}/link"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/link" -o "${TMP}/newfile"
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source" "${TMP}/newfile"
  ln -s "${TMP}/newfile" "${TMP}/destlink"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/destlink" -f
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source" "${TMP}/newfile"
  vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/link" -d "${TMP}/destlink"
  [ "${status}" -eq 0 ]
}

@test "Backup refuses generated output aliases before changing input" {
  mkdir "${TMP}/backup"
  printf 'preserve' > "${TMP}/backup/source-0.part"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/backup/source-0.part" -o "${TMP}/backup" -m backup -n source
  [ "${status}" -ne 0 ]
  [ "$(cat "${TMP}/backup/source-0.part")" = preserve ]
  printf 'preserve too' > "${TMP}/source"
  ln -s "${TMP}/source" "${TMP}/backup/source-metadata.txt"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -m backup
  [ "${status}" -ne 0 ]
  [ "$(cat "${TMP}/source")" = 'preserve too' ]
}

@test "Restore refuses backup aliases and traversal in FILE_NAME" {
  small_backup
  cp "${TMP}/backup/source-0.part" "${TMP}/original"
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/backup/source-0.part" -y
  [ "${status}" -ne 0 ]
  cmp "${TMP}/original" "${TMP}/backup/source-0.part"
  sed -i 's#^FILE_NAME=.*#FILE_NAME=../outside#' "${TMP}/backup/source-metadata.txt"
  mkdir "${TMP}/dest"
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/dest" -y
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/outside" ]
}

@test "Invalid metadata arithmetic and duplicate fields fail before output changes" {
  local record
  for record in NUM_JOBS=9223372036854775808 BLOCKSIZEBYTES=9223372036854775807 \
      SPLIT_SIZE=9223372036854775807 INPUT_SIZE=08 COMPRESSION=2 BACKUP_STATE=incomplete; do
    small_backup -s
    sed -i "/^${record%%=*}=/d" "${TMP}/backup/source-metadata.txt"
    printf '%s\n' "${record}" >> "${TMP}/backup/source-metadata.txt"
    vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
    [ "${status}" -ne 0 ]
    [ ! -e "${TMP}/target" ]
    vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/source" -b "${TMP}/backup/source"
    [ "${status}" -ne 0 ]
  done
  small_backup
  printf 'NUM_JOBS=4\n' >> "${TMP}/backup/source-metadata.txt"
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/target" ]
}

@test "Checksum worker failure is waited for and leaves incomplete metadata" {
  mkdir "${TMP}/bin"
  printf '#!/bin/bash\ncat >/dev/null\nexit 1\n' > "${TMP}/bin/sha256sum"
  chmod +x "${TMP}/bin/sha256sum"
  printf 'source' > "${TMP}/source"
  mkdir "${TMP}/backup"
  vrun env PATH="${TMP}/bin:${PATH}" "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -m backup -s
  [ "${status}" -ne 0 ]
  grep -qx BACKUP_STATE=incomplete "${TMP}/backup/source-metadata.txt"
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/target" ]
}

@test "Replacing a backup without checksums removes stale sidecars" {
  small_backup -s
  printf 'different data' > "${TMP}/source"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -m backup
  [ "${status}" -eq 0 ]
  [ ! -e "${TMP}/backup/source-0.sha256" ]
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source" "${TMP}/target"
}

@test "Backup names with equals and sed punctuation roundtrip and check" {
  printf 'source' > "${TMP}/source"
  mkdir "${TMP}/backup"
  local name='a=b#c&d'
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -n "${name}" -m backup -s
  [ "${status}" -eq 0 ]
  vrun "${REPO_ROOT}/ddpar-check.sh" -s "${TMP}/source" -b "${TMP}/backup/${name}"
  [ "${status}" -eq 0 ]
  mkdir "${TMP}/dest"
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/${name}" -o "${TMP}/dest" -y
  [ "${status}" -eq 0 ]
  cmp "${TMP}/source" "${TMP}/dest/${name}"
}

@test "Cancelled restore leaves a nonexistent target nonexistent" {
  small_backup
  vrun bash -c 'printf "n\n" | "$1/ddpar-restore.sh" -i "$2/backup/source" -o "$2/target"' bash "${REPO_ROOT}" "${TMP}"
  [ "${status}" -eq 0 ]
  [ ! -e "${TMP}/target" ]
}

@test "Segment writer rejects early EOF even though dd returns zero" {
  vrun bash -c 'set -o pipefail; source "$1/ddpar-common.sh"; BLOCKSIZEBYTES=4; printf abc | ddpar_write_segment "$2/out" 4 0' bash "${REPO_ROOT}" "${TMP}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'incomplete segment'* ]]
}

@test "Segment writer propagates disk-full errors" {
  [ -e /dev/full ] || skip '/dev/full unavailable'
  vrun bash -c 'set -o pipefail; source "$1/ddpar-common.sh"; BLOCKSIZEBYTES=4; printf abcd | ddpar_write_segment /dev/full 4 0' bash "${REPO_ROOT}"
  [ "${status}" -ne 0 ]
}

@test "TERM stops all descendants of a running worker" {
  mkdir "${TMP}/bin"
  cat > "${TMP}/bin/dd" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "${arg}" in
    if=*) sleep 60 & child=$!; printf '%s\n' "${child}" > "${DDPAR_TEST_PIDFILE}"; wait "${child}"; exit ;;
  esac
done
exec /usr/bin/dd "$@"
EOF
  chmod +x "${TMP}/bin/dd"
  printf source > "${TMP}/source"
  # The test must fail if cancellation merely waits for sleep's natural EOF.
  vrun timeout 10 env PATH="${TMP}/bin:${PATH}" DDPAR_TEST_PIDFILE="${TMP}/child" bash -c '
    "$1/ddpar.sh" -i "$2/source" -o "$2/out" -j 1 & main=$!
    for ((n=0; n<100; n++)); do [ -s "$2/child" ] && break; sleep .05; done
    [ -s "$2/child" ] || { kill -TERM "$main"; exit 1; }
    read -r child < "$2/child"
    kill -TERM "$main"
    wait "$main"; rc=$?
    [ "$rc" -ne 0 ] || exit 1
    if [ -r "/proc/$child/stat" ]; then
      read -r stat < "/proc/$child/stat" || true
      fields=${stat##*) }; state=${fields%% *}
      [ "$state" = Z ] || { kill -TERM "$child"; exit 1; }
    fi
  ' bash "${REPO_ROOT}" "${TMP}"
  [ "${status}" -eq 0 ]
}

@test "Unknown CLI options, trailing arguments and overflow fail closed" {
  small_backup
  for script in ddpar.sh ddpar-restore.sh ddpar-check.sh; do
    vrun "${REPO_ROOT}/${script}" --help
    [ "${status}" -eq 0 ]
    vrun "${REPO_ROOT}/${script}" -Z
    [ "${status}" -ne 0 ]
    vrun "${REPO_ROOT}/${script}" -r l
    [ "${status}" -ne 0 ]
  done
  vrun "${REPO_ROOT}/ddpar-restore.sh" -i "${TMP}/backup/source" -o "${TMP}/target" -y garbage
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/target" ]
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/target" -j 9223372036854775808
  [ "${status}" -ne 0 ]
  [ ! -e "${TMP}/target" ]
}

@test "Backup rejects a basename that would break the metadata format" {
  printf 'source' > "${TMP}/source"
  mkdir "${TMP}/backup"
  vrun "${REPO_ROOT}/ddpar.sh" -i "${TMP}/source" -o "${TMP}/backup" -m backup -n $'two\nlines'
  [ "${status}" -ne 0 ]
  [ -z "$(ls -A "${TMP}/backup")" ]
}

@test "Symlinked entry points find the helper and keep option values" {
  mkdir "${TMP}/bin" "${TMP}/work"
  ln -s "${REPO_ROOT}/ddpar-check.sh" "${TMP}/bin/ddpar-check"
  printf 'same' > "${TMP}/work/--input"
  printf 'same' > "${TMP}/work/--output"
  # Without the .sh suffix the values after -s/-d must still stay literal.
  vrun bash -c 'cd "$1" && "$2" -s --input -d --output -j 1' bash "${TMP}/work" "${TMP}/bin/ddpar-check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'Segment 0: OK'* ]]
}
