#!/usr/bin/env bats
# Validate completion against each command's CLI without running transfers.
# Flow: load real bash-completion; simulate Readline input; check candidates.
# Usage: bats tests/completion.bats
# Version: 1.0.0 (2026-10-17)

# Load the real helper library so quoting and word-break handling are tested.
setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    source /usr/share/bash-completion/bash_completion
    source "${REPO_ROOT}/completions/ddpar"
    # Outside Readline, compgen does not dequote escaped prefixes. Unit inputs
    # are logical words; the separate PTY test covers actual Readline quoting.
    _quote_readline_by_ref() { printf -v "${2}" '%s' "${1}"; }
    cd "${BATS_TEST_TMPDIR}"
    mkdir -p 'backup dir' 'input dir'
    touch 'input image' 'backup dir/disk image-metadata.txt' \
        'backup dir/disk image-0.part' 'backup dir/disk image-0.sha256'
}

# Simulate logical words supplied by Readline; use real _init_completion.
complete_words() {
    COMP_WORDS=("$@")
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    COMP_LINE="${*}"
    COMP_POINT="${#COMP_LINE}"
    COMP_TYPE=9
    # Completion helpers use failure as flow control; Bats enables errexit.
    _ddpar || :
}

# Assert exact array membership, preserving whitespace and shell metacharacters.
has_reply() {
    local item
    for item in "${COMPREPLY[@]}"; do
        [[ "${item}" != "${1}" ]] || return 0
    done
    printf 'Missing reply: %s; got: %s\n' "${1}" "${COMPREPLY[*]}" >&2
    return 1
}

@test "all command names including aliases register without default fallback" {
    local name
    for name in ddpar ddpar.sh ddpar-restore ddpar-restore.sh ddpar-check ddpar-check.sh run-remote-tests.sh; do
        [[ "$(complete -p "${name}")" == "complete -F _ddpar ${name}" ]]
    done
}

@test "ddpar offers every supported option" {
    complete_words ./ddpar.sh ''
    local option
    for option in -i --input -o --output -m -j -b -n -c -s -f -r -R -h --help -d; do
        has_reply "${option}"
    done
    [ "${#COMPREPLY[@]}" -eq 16 ]
}

@test "restore offers every supported option and no clone-only flags" {
    complete_words ddpar-restore ''
    local option
    for option in -i --input -o --output -r -R -y -P -h --help; do
        has_reply "${option}"
    done
    [ "${#COMPREPLY[@]}" -eq 10 ]
}

@test "check offers every supported option, with no invalid long aliases" {
    complete_words /opt/ddpar/ddpar-check.sh ''
    local option
    for option in -b -s -d -j -B -r -R -h --help; do
        has_reply "${option}"
    done
    [ "${#COMPREPLY[@]}" -eq 9 ]
}

@test "developer runner completes only its actual flags" {
    complete_words ./testing-docker/run-remote-tests.sh --keep --
    has_reply --no-build
    has_reply --keep
    has_reply --verbose
    has_reply --help
    [ "${#COMPREPLY[@]}" -eq 4 ]
    complete_words run-remote-tests.sh -- ''
    [ "${#COMPREPLY[@]}" -eq 0 ]
}

@test "mode and remote values are filtered; unsupported encrypted mode is absent" {
    complete_words ddpar -m b
    [ "${COMPREPLY[*]}" = backup ]
    complete_words ddpar -mc
    [ "${COMPREPLY[*]}" = -mclone ]
    local tool
    for tool in ddpar ddpar-restore ddpar-check; do
        complete_words "${tool}" -r ''
        has_reply n
        has_reply c
        has_reply -R
        complete_words "${tool}" -rl
        [ "${#COMPREPLY[@]}" -eq 0 ]
        complete_words "${tool}" -rc
        [ "${COMPREPLY[*]}" = -rc ]
    done
}

@test "optional remote value does not swallow the following option" {
    complete_words ddpar -r -m b
    [ "${COMPREPLY[*]}" = backup ]
    complete_words ddpar-restore -r -o 'input i'
    has_reply 'input image'
    complete_words ddpar-check -r -j 1
    has_reply 1
    has_reply 16
}

@test "clusters and attached option values follow getopts" {
    complete_words ddpar -csmba
    [ "${COMPREPLY[*]}" = -csmbackup ]
    complete_words ddpar -cs -m backup -o 'input '
    has_reply 'input dir'
    [ "${#COMPREPLY[@]}" -eq 1 ]
    complete_words ddpar-restore -yPo'input i'
    has_reply '-yPoinput image'
    complete_words ddpar-check -j8 -B1
    [ "${COMPREPLY[*]}" = -B1048576 ]
}

@test "numeric arguments offer decimal values instead of files or options" {
    complete_words ddpar -j 3
    [ "${COMPREPLY[*]}" = 32 ]
    complete_words ddpar -b 10
    [ "${COMPREPLY[*]}" = 1048576 ]
    complete_words ddpar-check -B 4
    has_reply 4096
    has_reply 4194304
    complete_words ddpar -j 999
    [ "${#COMPREPLY[@]}" -eq 0 ]
}

@test "input and clone/restore outputs complete files including spaces" {
    local tool option
    for tool in ddpar ddpar-restore; do
        for option in -o --output; do
            complete_words "${tool}" "${option}" 'input '
            has_reply 'input image'
            has_reply 'input dir'
        done
    done
    complete_words ddpar --input 'input i'
    has_reply 'input image'
}

@test "backup output completes directories only, also after attached mode" {
    complete_words ddpar -mbackup --output 'input '
    [ "${#COMPREPLY[@]}" -eq 1 ]
    has_reply 'input dir'
    complete_words ddpar -m backup -m clone -o 'input i'
    has_reply 'input image'
}

@test "restore and check complete backup bases from metadata only" {
    complete_words ddpar-restore --input 'backup dir/disk'
    [ "${#COMPREPLY[@]}" -eq 1 ]
    has_reply 'backup dir/disk image'
    complete_words ddpar-check -b 'backup dir/disk'
    [ "${#COMPREPLY[@]}" -eq 1 ]
    has_reply 'backup dir/disk image'
    complete_words ddpar-check -b'backup dir/disk'
    has_reply '-bbackup dir/disk image'
}

@test "backup selection allows directory navigation and does not require parts" {
    complete_words ddpar-restore -i 'backup '
    has_reply 'backup dir'
    rm 'backup dir/disk image-0.part' 'backup dir/disk image-0.sha256'
    complete_words ddpar-restore -i 'backup dir/disk'
    has_reply 'backup dir/disk image'
}

@test "check s and d are paths, while ddpar s and d are flags" {
    complete_words ddpar-check -s 'input i'
    has_reply 'input image'
    complete_words ddpar-check -d 'input i'
    has_reply 'input image'
    complete_words ddpar -s -d ''
    has_reply -m
    has_reply -i
}

@test "free basename values and end-of-options never fall back to files" {
    complete_words ddpar -n ''
    [ "${#COMPREPLY[@]}" -eq 0 ]
    complete_words ddpar -ninput
    [ "${#COMPREPLY[@]}" -eq 0 ]
    complete_words ddpar -- ''
    [ "${#COMPREPLY[@]}" -eq 0 ]
    complete_words ddpar -i -- -m b
    [ "${COMPREPLY[*]}" = backup ]
    complete_words ddpar --input --help -m b
    [ "${COMPREPLY[*]}" = backup ]
}

@test "remote paths stay manual and local endpoints remain completable" {
    # A helper regression must not start SSH, ddpar or a network lookup.
    ssh() { touch ssh-was-called; return 1; }
    local tool
    for tool in ddpar ddpar-restore ddpar-check; do
        case "${tool}" in
            ddpar) complete_words "${tool}" -R invalid-host -o 'input i' ;;
            ddpar-restore) complete_words "${tool}" -r c -i 'backup dir/disk' ;;
            ddpar-check) complete_words "${tool}" -rn -b 'backup dir/disk' ;;
        esac
        [ "${#COMPREPLY[@]}" -eq 0 ]
    done
    complete_words ddpar-check -R invalid-host -d 'input i'
    [ "${#COMPREPLY[@]}" -eq 0 ]
    complete_words ddpar -R invalid-host -i 'input i'
    has_reply 'input image'
    complete_words ddpar-restore -Rinvalid-host -o 'input i'
    has_reply 'input image'
    complete_words ddpar-check -r -s 'input i'
    has_reply 'input image'
    complete_words ddpar-check -R invalid-host -b /remote/backup -d 'input i'
    has_reply 'input image'
    [ ! -e ssh-was-called ]
}

@test "SSH completion keeps user prefix and reads local config aliases" {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.ssh"
    printf 'Host ddpar-test-host\n    HostName 192.0.2.42\n' > "${HOME}/.ssh/config"
    complete_words ddpar -R ddpar-test-
    has_reply ddpar-test-host
    complete_words ddpar-restore -R admin@ddpar-test-
    has_reply admin@ddpar-test-host
    complete_words ddpar-check -Radmin@ddpar-test-
    has_reply -Radmin@ddpar-test-host
}

@test "filenames with shell syntax are data, never evaluated" {
    touch '$(touch INJECTED)-metadata.txt' "quote' image-metadata.txt"
    complete_words ddpar-restore -i '$('
    has_reply '$(touch INJECTED)'
    complete_words ddpar-check -b "quote'"
    has_reply "quote' image"
    [ ! -e INJECTED ]
}

@test "Bash redirections use the real file completion helper" {
    complete_words ddpar -h '>' 'input i'
    has_reply 'input image'
}

@test "invalid long equals syntax is not suggested or parsed as supported" {
    complete_words ddpar --input= ''
    [ "${#COMPREPLY[@]}" -eq 0 ]
    complete_words ddpar-check --input ''
    [ "${#COMPREPLY[@]}" -eq 0 ]
}

@test "completion leaves caller working directory and shell options intact" {
    local original_pwd="${PWD}" original_options
    original_options="$(set +o; shopt -p)"
    complete_words ddpar-restore -i 'backup dir/disk'
    [ "${PWD}" = "${original_pwd}" ]
    [ "$(set +o; shopt -p)" = "${original_options}" ]
}

@test "real Readline Tab handles quoting, attached paths and backup bases" {
    run python3 "${REPO_ROOT}/tests/completion_readline.py"
    [ "${status}" -eq 0 ] || { printf '%s\n' "${output}" >&2; return 1; }
}
