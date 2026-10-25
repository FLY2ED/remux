#!/usr/bin/env bash
set -euo pipefail

# Runs the launcher that RemoteProgramCommand builds, compiled from the app's own source, under /bin/sh the way
# sshd runs a command: a clean environment, with the home folder as the working directory. Each case sets up a
# scratch home and folders, then checks where the launcher finds the program, or that it finds nothing.

test_root="$(mktemp -d)"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat > "${test_root}/main.swift" <<'SWIFT'
print(RemoteProgramCommand.command(program: CommandLine.arguments[1], body: [#"printf "%s\n" "$resolved""#]))
SWIFT
xcrun swiftc -o "${test_root}/launcher" "${test_root}/main.swift" \
  RemuxApp/Sources/SSH/RemoteProgramCommand.swift RemuxApp/Sources/SSH/RemoteShellArgument.swift

# A name nothing on the machine has, so the system's own folders never answer.
name="remux-launcher-probe"
status=0

new_home() {
  local home="${test_root}/$1"
  mkdir -p "${home}"
  printf '%s' "${home}"
}

install_program() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nexit 0\n' > "$1"
  chmod "${2:-755}" "$1"
}

run_launcher() {
  local home="$1" program="$2" login_path="$3" command
  command="$("${test_root}/launcher" "${program}")"
  set +e
  (cd "${home}" && env -i HOME="${home}" USER="$(id -un)" PATH="${login_path}" /bin/sh -c "${command}") \
    > "${test_root}/stdout" 2> "${test_root}/stderr"
  status=$?
  set -e
}

assert_found() {
  local expected="$1" case_name="$2"
  test "${status}" = 0 || fail "${case_name}: exit ${status}: $(cat "${test_root}/stderr")"
  grep -q -x 'remux-ready:1' "${test_root}/stdout" || fail "${case_name}: no ready marker on stdout"
  grep -q -x 'remux-ready:1' "${test_root}/stderr" || fail "${case_name}: no ready marker on stderr"
  test "$(tail -n 1 "${test_root}/stdout")" = "${expected}" || fail "${case_name}: found $(tail -n 1 "${test_root}/stdout")"
}

assert_not_found() {
  local program="$1" case_name="$2"
  test "${status}" = 127 || fail "${case_name}: expected exit 127, got ${status}"
  test "$(cat "${test_root}/stderr")" = "remux: not found: ${program}" || fail "${case_name}: $(cat "${test_root}/stderr")"
  ! grep -q 'remux-ready:1' "${test_root}/stdout" || fail "${case_name}: ready marker printed"
}

login_bin="${test_root}/login-bin"
login_path="${login_bin}:/usr/bin:/bin"

home="$(new_home on-path)"
install_program "${login_bin}/${name}"
run_launcher "${home}" "${name}" "${login_path}"
assert_found "${login_bin}/${name}" "on the login PATH"

home="$(new_home path-first)"
install_program "${home}/.local/bin/${name}"
run_launcher "${home}" "${name}" "${login_path}"
assert_found "${login_bin}/${name}" "the login PATH comes before the install folders"
rm "${login_bin}/${name}"

home="$(new_home local-bin)"
install_program "${home}/.local/bin/${name}"
run_launcher "${home}" "${name}" "${login_path}"
assert_found "${home}/.local/bin/${name}" "only in ~/.local/bin"

home="$(new_home mise)"
install_program "${home}/.local/share/mise/shims/${name}"
run_launcher "${home}" "${name}" "${login_path}"
assert_found "${home}/.local/share/mise/shims/${name}" "only as a mise shim"

home="$(new_home folder-in-home)"
mkdir -p "${home}/${name}"
run_launcher "${home}" "${name}" "${login_path}"
assert_not_found "${name}" "a folder with the program's name in the home folder"

home="$(new_home file-in-home)"
install_program "${home}/${name}" 644
run_launcher "${home}" "${name}" "${login_path}"
assert_not_found "${name}" "a file with the program's name in the home folder"

home="$(new_home path-set)"
install_program "${test_root}/tools/${name}"
run_launcher "${home}" "${test_root}/tools/${name}" "${login_path}"
assert_found "${test_root}/tools/${name}" "a path set to a program that runs"

home="$(new_home path-set-not-executable)"
install_program "${test_root}/plain/${name}" 644
run_launcher "${home}" "${test_root}/plain/${name}" "${login_path}"
assert_not_found "${test_root}/plain/${name}" "a path set to a file that can't run"

printf 'remote program launcher tests passed\n'
