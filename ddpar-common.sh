#!/bin/bash
# Shared validation and SSH helpers for ddpar; source from the three commands.
# Flow: validate decimal metadata; verify complete parts; isolate SSH sessions;
# release private resources on every exit path.
# Version: 1.0.2 (2026-10-17)

# Convert documented long aliases without changing data after -i/-o or --.
# $1 is the caller's getopts string: only options with a required value
# (X:, not X::) protect their next argument, independent of the script name.
ddpar_normalize_args() {
  local optstring="${1}" arg opt needs_value=0 literal=0
  shift
  DDPAR_ARGS=()
  for arg in "$@"; do
    if [ "${needs_value}" -eq 1 ] || [ "${literal}" -eq 1 ]; then
      DDPAR_ARGS+=("${arg}")
      needs_value=0
      continue
    fi
    case "${arg}" in
      --) literal=1; DDPAR_ARGS+=(--) ;;
      --help) DDPAR_ARGS+=(-h) ;;
      --input) DDPAR_ARGS+=(-i); needs_value=1 ;;
      --output) DDPAR_ARGS+=(-o); needs_value=1 ;;
      -?)
        DDPAR_ARGS+=("${arg}")
        opt="${arg#-}"
        if [ "${opt}" != : ] && [[ "${optstring}" == *"${opt}:"* && "${optstring}" != *"${opt}::"* ]]; then
          needs_value=1
        fi
        ;;
      *) DDPAR_ARGS+=("${arg}") ;;
    esac
  done
}

# Keep all arithmetic within Bash's signed 64-bit range. Canonical decimal
# strings also prevent octal interpretation and evaluation of shell expressions.
ddpar_uint() {
  local value="${1}" max=9223372036854775807
  # shellcheck disable=SC2071 # Lexical bound check must precede integer conversion.
  [[ "${value}" =~ ^(0|[1-9][0-9]*)$ ]] &&
    { [ "${#value}" -lt 19 ] ||
      { [ "${#value}" -eq 19 ] && [[ "${value}" < "${max}" || "${value}" == "${max}" ]]; }; }
}

# Validate the factors before multiplication, including offsets for empty parts.
ddpar_geometry() {
  if ! { ddpar_uint "${NUM_JOBS}" && [ "${NUM_JOBS}" -gt 0 ] &&
    ddpar_uint "${BLOCKSIZEBYTES}" && [ "${BLOCKSIZEBYTES}" -gt 0 ] &&
    [ "${NUM_JOBS}" -le "$((9223372036854775807 / BLOCKSIZEBYTES))" ]; }; then
      echo 'Error: jobs and block size must be positive whole numbers within the supported range.' >&2
      return 2
  fi
}

# A basename is stored in a line-based format and may never select a parent path.
ddpar_basename() {
  [[ -n "${1}" && "${1}" != */* && "${1}" != . && "${1}" != .. &&
     "${1}" != *$'\n'* && "${1}" != *$'\r'* ]]
}

# Parse data, never source it. Reject duplicate keys and unsafe numeric values
# before using them in arithmetic or interpolating them into remote commands.
ddpar_read_metadata() {
  local key value
  local -A seen=()
  NUM_JOBS='' BLOCKSIZEBYTES='' SPLIT_SIZE='' INPUT_SIZE=''
  FILE_NAME='' COMPRESSION='' BACKUP_STATE=''
  while IFS='=' read -r key value || [ -n "${key}" ]; do
    case "${key}" in
      NUM_JOBS|BLOCKSIZEBYTES|SPLIT_SIZE|INPUT_SIZE|FILE_NAME|COMPRESSION|BACKUP_STATE)
        if [[ -v seen[${key}] ]]; then
          echo "Error: duplicate metadata key: ${key}" >&2
          return 1
        fi
        seen[${key}]=1
        printf -v "${key}" '%s' "${value}"
        ;;
    esac
  done < "${1}"
  ddpar_geometry || return 1
  if ! ddpar_uint "${SPLIT_SIZE}" || [ "${SPLIT_SIZE}" -eq 0 ] ||
     [ "${NUM_JOBS}" -gt "$((9223372036854775807 / SPLIT_SIZE))" ]; then
    echo 'Error: invalid or overflowing segment size in metadata.' >&2
    return 1
  fi
  # Legacy metadata omitted INPUT_SIZE and always used equally sized parts.
  if [[ ! -v seen[INPUT_SIZE] ]]; then
    INPUT_SIZE=$((SPLIT_SIZE * NUM_JOBS))
  fi
  ddpar_uint "${INPUT_SIZE}" || { echo 'Error: invalid INPUT_SIZE in metadata.' >&2; return 1; }
  if [ -n "${FILE_NAME}" ] && ! ddpar_basename "${FILE_NAME}"; then
    echo 'Error: unsafe FILE_NAME in metadata.' >&2
    return 1
  fi
  case "${COMPRESSION}" in
    ''|0) COMPRESSION='' ;;
    1) ;;
    *) echo 'Error: unsupported COMPRESSION in metadata.' >&2; return 1 ;;
  esac
  case "${BACKUP_STATE}" in
    ''|complete) ;;
    *) echo 'Error: backup is incomplete.' >&2; return 1 ;;
  esac
}

# Decode an entire part so gzip CRC/trailer errors cannot be hidden by dd's
# count limit. The caller's pipefail setting preserves every producer error.
ddpar_part_stream() {
  if [ -n "${COMPRESSION}" ]; then
    gzip -dc -- "${1}"
  else
    cat -- "${1}"
  fi
}

# Check actual raw length before opening any restore target. gzip -l is not
# sufficient: its size field wraps at 4 GiB and concatenated members are valid.
ddpar_verify_part() {
  local path="${1}" expected="${2}" actual
  if [ -n "${COMPRESSION}" ]; then
    actual=$(ddpar_part_stream "${path}" | wc -c) || return 1
  else
    if [ ! -f "${path}" ] || [ ! -r "${path}" ]; then
      echo "Error: missing or unreadable backup part: ${path}" >&2
      return 1
    fi
    actual=$(stat -Lc %s -- "${path}") || return 1
  fi
  if [ "${actual}" -ne "${expected}" ]; then
    echo "Fehler: Teil ${path} hat ${actual} Bytes statt der erwarteten ${expected} Bytes." >&2
    return 1
  fi
}

# Read only the digest of a stdin checksum record. Never let an untrusted
# sidecar make sha256sum open an arbitrary path via its filename field.
ddpar_checksum() {
  local digest marker extra
  IFS=' ' read -r digest marker extra < "${1}" || return 1
  [[ "${digest}" =~ ^[[:xdigit:]]{64}$ && "${marker}" == '-' && -z "${extra}" ]] || {
    echo "Error: invalid checksum record: ${1}" >&2; return 1;
  }
  [ "$(wc -l < "${1}")" -eq 1 ] || return 1
  printf '%s\n' "${digest,,}"
}

# Count the received stream as well as checking dd's status: EOF is not a dd
# error. Explicitly wait for the count process (unlike an unwaited tee >(...)).
ddpar_write_segment() (
  local target="${1}" expected="${2}" start="${3}" count_file count_fd count_pid rc=0 actual
  count_file=$(mktemp) || return 1
  trap 'rm -f -- "${count_file}"' EXIT
  exec {count_fd}> >(wc -c > "${count_file}")
  count_pid=$!
  tee "/dev/fd/${count_fd}" |
    dd of="${target}" bs="${BLOCKSIZEBYTES}" iflag=fullblock,count_bytes \
      count="${expected}" oflag=seek_bytes seek="${start}" conv=notrunc || rc=1
  exec {count_fd}>&-
  wait "${count_pid}" || rc=1
  actual=$(cat -- "${count_file}")
  rm -f -- "${count_file}"
  if [ "${actual}" != "${expected}" ]; then
    echo "Error: incomplete segment: received ${actual} bytes; expected ${expected}." >&2
    rc=1
  fi
  return "${rc}"
)

# Quote one argument for the remote login shell without interpreting its data.
shell_quote() {
  local escaped="${1//\'/\'\\\'\'}"
  printf "'%s'" "${escaped}"
}

DDPAR_OWNER_PID=${BASHPID}
META_SRC=''
METADATA_SRC=''
NETWORK_TIMEOUT="${DDPAR_NETWORK_TIMEOUT:-300}"
SSH_SOCKET_DIR=''
SSH_CONNECTED=0

# Each invocation owns a private ControlPath, so concurrent runs and different
# hosts can never borrow or close one another's authenticated connection.
connect_ssh() {
  if [[ -z "${REMOTE_HOST:-}" || "${REMOTE_HOST}" == -* || "${REMOTE_HOST}" == *[[:space:]]* ]]; then
    echo 'Error: a valid remote host (-R) is required.' >&2
    return 1
  fi
  if ! ddpar_uint "${NETWORK_TIMEOUT}" || [ "${NETWORK_TIMEOUT}" -lt 1 ] || [ "${NETWORK_TIMEOUT}" -gt 2147483647 ]; then
    echo 'Error: DDPAR_NETWORK_TIMEOUT must be between 1 and 2147483647 seconds.' >&2
    return 1
  fi
  SSH_SOCKET_DIR=$(mktemp -d /tmp/ddpar-ssh.XXXXXX) || return 1
  SSH_SOCKET_PATH="${SSH_SOCKET_DIR}/control"
  local output password
  if output=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ControlMaster=yes -o ControlPersist=yes -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" true 2>&1); then
    SSH_CONNECTED=1
  elif [[ "${output}" == *'Permission denied'* ]] && [ -t 0 ] && command -v sshpass >/dev/null; then
    read -r -s -p "SSH password for ${REMOTE_HOST}: " password
    printf '\n' >&2
    SSHPASS="${password}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ControlMaster=yes -o ControlPersist=yes -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" true || return 1
    SSH_CONNECTED=1
  else
    printf '%s\n' "${output}" >&2
    return 1
  fi
  # SSH aliases may name a different network address. Netcat must use that
  # hostname too, rather than trying to resolve the alias as a DNS name.
  REMOTE_ADDRESS=$(ssh -G "${REMOTE_HOST}" | awk '$1 == "hostname" {print $2}') || return 1
  [ -n "${REMOTE_ADDRESS}" ]
}

# Control commands only address this invocation's socket.
is_ssh_socket_alive() {
  [ "${SSH_CONNECTED}" -eq 1 ] && ssh -S "${SSH_SOCKET_PATH}" -O check "${REMOTE_HOST}" 2>/dev/null
}

# The remote login shell need not be Bash; explicitly enable pipefail in Bash
# so a failed dd/zcat cannot be masked by a successful sha256sum.
execute_remote_command() {
  ssh -S "${SSH_SOCKET_PATH}" "${REMOTE_HOST}" "bash -o pipefail -c $(shell_quote "${1}")"
}

# A killed wrapper may remain as a zombie until init reaps it. kill -0 alone
# would then report "running" forever; inspect the Linux process state as well.
remote_job_state() {
  # shellcheck disable=SC2016 # The query is evaluated only on the remote host.
  local query='base=$1
if [ -f "$base.rc" ]; then printf "rc "; cat "$base.rc"; exit; fi
if [ -f "$base.pid" ]; then
  read -r pid < "$base.pid"
  proc_pid=$pid
  [ -f "$base.proc" ] && read -r proc_pid < "$base.proc"
  if [[ "$pid" =~ ^[1-9][0-9]*$ && "$proc_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    state=unknown
    if [ -r "/proc/$proc_pid/stat" ]; then
      read -r stat < "/proc/$proc_pid/stat" || true
      fields=${stat##*) }
      state=${fields%% *}
    fi
    if [ "$state" != Z ]; then echo running; exit; fi
  fi
fi
if [ -f "$base.rc" ]; then printf "rc "; cat "$base.rc"; else echo missing; fi'
  execute_remote_command "bash -c $(shell_quote "${query}") ddpar-state $(shell_quote "${1}")"
}

# Close only a connection that this invocation actually created.
close_ssh_connection() {
  if [ "${SSH_CONNECTED}" -eq 1 ]; then
    ssh -S "${SSH_SOCKET_PATH}" -O exit "${REMOTE_HOST}" || return 1
    SSH_CONNECTED=0
  fi
}

# Translate /proc-visible child IDs into this shell's PID namespace. /proc can
# be mounted from an ancestor namespace (as in some execution sandboxes).
ddpar_namespace_pid() {
  local proc_pid="${1}" key values
  local -a ids=()
  # Without a readable status the /proc ID may belong to another namespace;
  # never signal it untranslated, it could name an unrelated process here.
  [ -r "/proc/${proc_pid}/status" ] || return 1
  while read -r key values; do
    if [ "${key}" = NSpid: ]; then
      read -r -a ids <<< "${values}"
      printf '%s\n' "${ids[DDPAR_PID_LEVEL]}"
      return 0
    fi
  done 2>/dev/null < "/proc/${proc_pid}/status" || return 1
  printf '%s\n' "${proc_pid}"
}

# Find the namespace depth without launching a process whose /proc/self would
# refer to that child instead of this shell.
DDPAR_PID_LEVEL=0
while read -r ddpar_key ddpar_values; do
  if [ "${ddpar_key}" = NSpid: ]; then
    read -r -a ddpar_ids <<< "${ddpar_values}"
    DDPAR_PID_LEVEL=$((${#ddpar_ids[@]} - 1))
    break
  fi
done < /proc/thread-self/status

# The kernel's children file is optional (CONFIG_CHECKPOINT_RESTORE). Fall
# back to PPid fields when it is absent, keeping IDs in /proc's namespace.
ddpar_child_pids() {
  local parent="${1}" status_file key value
  DDPAR_CHILDREN=''
  if [ -r "/proc/${parent}/task/${parent}/children" ]; then
    read -r DDPAR_CHILDREN < "/proc/${parent}/task/${parent}/children" || true
    return 0
  fi
  for status_file in /proc/[0-9]*/status; do
    [ -r "${status_file}" ] || continue
    # A process can disappear while scanning /proc; that race is harmless.
    while read -r key value; do
      if [ "${key}" = PPid: ]; then
        if [ "${value}" = "${parent}" ]; then
          value=${status_file#/proc/}
          DDPAR_CHILDREN+=" ${value%/status}"
        fi
        break
      fi
    done < "${status_file}" 2>/dev/null
  done
}

# Stop descendants before their parent, including all stages of pipelines.
# Linux /proc provides the child list without matching unrelated process names.
ddpar_stop_tree() {
  local proc_pid="${1}" pid children child
  pid=$(ddpar_namespace_pid "${proc_pid}") || return 0
  [ -n "${pid}" ] || return 0
  kill -STOP "${pid}" 2>/dev/null || return 0
  ddpar_child_pids "${proc_pid}"
  children=${DDPAR_CHILDREN}
  for child in ${children}; do ddpar_stop_tree "${child}"; done
  kill -TERM "${pid}" 2>/dev/null || true
  kill -CONT "${pid}" 2>/dev/null || true
}

# Signal handlers cannot rely on jobs -p alone: that lists only the process
# group leader and can leave other dd/nc processes writing after cancellation.
# shellcheck disable=SC2317 # Called indirectly by trap.
ddpar_cancel() {
  trap - INT TERM
  local children child own_proc_pid
  read -r own_proc_pid _ < /proc/thread-self/stat
  ddpar_child_pids "${own_proc_pid}"
  children=${DDPAR_CHILDREN}
  for child in ${children}; do ddpar_stop_tree "${child}"; done
  wait
  exit 130
}

# Cover validation failures as well as successful and explicitly cancelled runs.
ddpar_cleanup() {
  local rc=$?
  [ "${BASHPID}" -eq "${DDPAR_OWNER_PID}" ] || return "${rc}"
  if [ "${SSH_CONNECTED}" -eq 1 ]; then
    if [ "${rc}" -ne 0 ] && declare -F stop_remote_listeners >/dev/null; then
      stop_remote_listeners "${REMOTE_LISTENER_PORTS[@]}"
    fi
    if declare -F remove_remote_status_dir >/dev/null; then remove_remote_status_dir; fi
    close_ssh_connection
  fi
  if [ -n "${SSH_SOCKET_DIR}" ]; then rm -rf -- "${SSH_SOCKET_DIR}"; fi
  if [ "${REMOTE:-0}" -eq 1 ]; then
    [ -n "${METADATA_SRC:-}" ] && rm -f -- "${METADATA_SRC}"
    [ -n "${META_SRC:-}" ] && rm -f -- "${META_SRC}"
  fi
  return "${rc}"
}
trap ddpar_cleanup EXIT
