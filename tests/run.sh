#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
APP="$REPO_DIR/src/proxmox-ultimate-updater-notify"
INSTALLER="$REPO_DIR/install.sh"
PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

not_grep_fixed() {
  local needle=$1
  local file=$2
  ! grep -Fq -- "$needle" "$file"
}

new_fixture() {
  FIXTURE=$(mktemp -d)
  mkdir -p "$FIXTURE/bin" "$FIXTURE/state" "$FIXTURE/updater/VMs" "$FIXTURE/etc"
  printf 'secret-test-token\n' >"$FIXTURE/token"
  cat >"$FIXTURE/config" <<EOF
NTFY_URL="https://ntfy.example.invalid/topic"
NTFY_TOKEN_FILE="$FIXTURE/token"
NTFY_TITLE_PREFIX="Ultimate Updater"
EOF
  cat >"$FIXTURE/updater/update.conf" <<'EOF'
CHECK_WITH_HOST="false"
CHECK_WITH_LXC="false"
CHECK_WITH_VM="true"
CHECK_RUNNING_CONTAINER="true"
CHECK_STOPPED_CONTAINER="true"
CHECK_RUNNING_VM="true"
CHECK_STOPPED_VM="true"
CHECK_PAUSED_VM="true"
ONLY_UPDATE_CHECK=""
EXCLUDE_UPDATE_CHECK=""
ERROR_LOG_FILE="ERROR_LOG_PLACEHOLDER"
EOF
  sed -i "s|ERROR_LOG_PLACEHOLDER|$FIXTURE/updater-error.log|" "$FIXTURE/updater/update.conf"
  cat >"$FIXTURE/updater/tag-filter.sh" <<'EOF'
apply_only_exclude_tags() { return 0; }
EOF
  cat >"$FIXTURE/updater/VMs/101" <<'EOF'
IP="192.0.2.101"
USER="ronald"
SSH_VM_PORT="22"
EOF
  printf 'Inst package-a [1.0] (1.1 stable [amd64])\n' >"$FIXTURE/apt-output"
  : >"$FIXTURE/curl-args"
  : >"$FIXTURE/curl-stdin"
  : >"$FIXTURE/curl-count"
  : >"$FIXTURE/ssh-log"

  cat >"$FIXTURE/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_FIXTURE/curl-args"
cat >>"$TEST_FIXTURE/curl-stdin"
printf '1\n' >>"$TEST_FIXTURE/curl-count"
if [[ "${TEST_CURL_FAIL:-false}" == "true" ]]; then
  exit 22
fi
exit 0
EOF

  cat >"$FIXTURE/bin/qm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list)
    printf ' VMID NAME       STATUS\n 101 docker     running\n'
    ;;
  status)
    printf 'status: running\n'
    ;;
  config)
    printf 'name: docker\nostype: l26\nagent: 1\n'
    ;;
  *) exit 1 ;;
esac
EOF

  cat >"$FIXTURE/bin/pct" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf 'VMID Status Name\n' ;;
  *) exit 1 ;;
esac
EOF

  cat >"$FIXTURE/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_FIXTURE/ssh-log"
cmd=${*: -1}
case "$cmd" in
  true) exit 0 ;;
  *"command -v apt-get"*) exit 0 ;;
  *"sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update"*)
    [[ "${TEST_REFRESH_FAIL:-false}" == "true" ]] && exit 1
    exit 0
    ;;
  *"LC_ALL=C apt-get -s upgrade"*) cat "$TEST_FIXTURE/apt-output" ;;
  *"test -f /var/run/reboot-required.pkgs"*) exit 1 ;;
  *) exit 0 ;;
esac
EOF

  chmod +x "$FIXTURE/bin/"*
  export TEST_FIXTURE="$FIXTURE"
  export PATH="$FIXTURE/bin:$PATH"
  export PUUN_CONFIG_FILE="$FIXTURE/config"
  export PUUN_STATE_DIR="$FIXTURE/state"
  export PUUN_UPDATER_DIR="$FIXTURE/updater"
  export PUUN_UPDATER_CONFIG="$FIXTURE/updater/update.conf"
  export PUUN_UPDATER_LOG="$FIXTURE/ultimate-updater.log"
}

cleanup_fixture() {
  rm -rf "$FIXTURE"
  unset TEST_FIXTURE TEST_REFRESH_FAIL TEST_CURL_FAIL PUUN_CONFIG_FILE PUUN_STATE_DIR PUUN_UPDATER_DIR PUUN_UPDATER_CONFIG PUUN_UPDATER_LOG
}

count_curl() {
  wc -l <"$FIXTURE/curl-count" | tr -d ' '
}

# Syntax and static safety.
assert "main script parses" bash -n "$APP"
assert "installer parses" bash -n "$INSTALLER"
assert "test script parses" bash -n "$0"
if grep -nE '(^|[^-])\b(dnf|yum)[[:space:]].*(update|upgrade)|pacman[[:space:]].*-Syu|apk[[:space:]].*upgrade|apt-get[[:space:]]+(upgrade|dist-upgrade|full-upgrade)' "$APP"; then
  fail "automatic checker contains no package-install command"
else
  pass "automatic checker contains no package-install command"
fi
if grep -nE '\b(qm|pct)[[:space:]]+(start|stop|shutdown|resume|suspend|reboot)\b' "$APP"; then
  fail "automatic checker contains no guest power-state mutation"
else
  pass "automatic checker contains no guest power-state mutation"
fi

# Manual observation: version/help-like log must not notify.
new_fixture
cat >"$FIXTURE/ultimate-updater.log" <<'EOF'
Script is UpToDate
Version: 5.0
Finished, all updates done.
EOF
bash "$APP" observe-manual
assert "non-update success marker does not notify" test "$(count_curl)" -eq 0
cleanup_fixture

# Manual observation: actual run success deduplicates path-event bursts.
new_fixture
cat >"$FIXTURE/ultimate-updater.log" <<'EOF'
Transient first line removed by upstream cleanup
Updating Host : 192.0.2.1 | (pve)
--- PVE UPDATE ---
Finished, all updates done.
EOF
bash "$APP" observe-manual
# Simulate the upstream cleanup rewrite that removes only the unstable first line.
cat >"$FIXTURE/ultimate-updater.log" <<'EOF'
Updating Host : 192.0.2.1 | (pve)
--- PVE UPDATE ---
Finished, all updates done.
EOF
bash "$APP" observe-manual
assert "manual success notifies once across log-cleanup path events" test "$(count_curl)" -eq 1
assert "ntfy token is absent from curl argv" not_grep_fixed "secret-test-token" "$FIXTURE/curl-args"
assert "ntfy token is delivered through curl stdin" grep -Fq "Authorization: Bearer secret-test-token" "$FIXTURE/curl-stdin"
cleanup_fixture

# Manual 'Finished, with errors' must be failure even when upstream exits zero.
new_fixture
printf 'VM 101: docker\nError code: 100\n' >"$FIXTURE/updater-error.log"
cat >"$FIXTURE/ultimate-updater.log" <<'EOF'
Updating Host : 192.0.2.1 | (pve)
Updating VM 101 : docker
Finished, with errors.
EOF
bash "$APP" observe-manual
assert "Finished, with errors triggers a notification" test "$(count_curl)" -eq 1
assert "Finished, with errors is classified as failure" grep -Fq "Manual update finished with errors" "$FIXTURE/curl-stdin"
assert "manual failure includes updater error details" grep -Fq "Error code: 100" "$FIXTURE/curl-args"
cleanup_fixture

# Safe non-root SSH APT metadata refresh and update-state deduplication.
new_fixture
bash "$APP" check
assert "non-root SSH metadata refresh uses passwordless sudo" grep -Fq "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update" "$FIXTURE/ssh-log"
assert "first available-update state notifies" test "$(count_curl)" -eq 1
bash "$APP" check
assert "unchanged update state is deduplicated" test "$(count_curl)" -eq 1
printf 'Inst package-b [2.0] (2.1 stable [amd64])\n' >"$FIXTURE/apt-output"
bash "$APP" check
assert "changed update state notifies" test "$(count_curl)" -eq 2
: >"$FIXTURE/apt-output"
bash "$APP" check
assert "cleared update state notifies" test "$(count_curl)" -eq 3
cleanup_fixture

# Failed ntfy delivery must not poison failure dedupe state.
new_fixture
export TEST_REFRESH_FAIL=true
export TEST_CURL_FAIL=true
set +e
bash "$APP" check
notify_fail_rc=$?
set -e
assert "ntfy delivery failure keeps check non-zero" test "$notify_fail_rc" -ne 0
assert "failed ntfy delivery does not persist failure dedupe state" test ! -e "$FIXTURE/state/check-status"
unset TEST_CURL_FAIL
set +e
bash "$APP" check
retry_rc=$?
bash "$APP" check
second_rc=$?
set -e
assert "same check failure retries after ntfy recovers" test "$retry_rc" -ne 0
assert "repeated metadata refresh failure remains non-zero" test "$second_rc" -ne 0
assert "delivered identical check failure is then deduplicated" test "$(count_curl)" -eq 2
unset TEST_REFRESH_FAIL
bash "$APP" check
assert "recovered check state notifies" test "$(count_curl)" -eq 4
# Recovery from failure with available updates sends recovery + available state.
cleanup_fixture

# Install -> reinstall -> uninstall, config preservation, cron replacement/restoration.
INSTALL_FIXTURE=$(mktemp -d)
mkdir -p "$INSTALL_FIXTURE/bin" "$INSTALL_FIXTURE/root"
CRON_STORE="$INSTALL_FIXTURE/crontab"
cat >"$CRON_STORE" <<'EOF'
5 * * * * echo keep-me
15 2 * * * /etc/ultimate-updater/update.sh host
0 7,19 * * * /usr/local/sbin/update -check >/dev/null 2>&1
EOF
cat >"$INSTALL_FIXTURE/bin/crontab" <<'EOF'
#!/usr/bin/env bash
store=$TEST_CRON_STORE
case "${1:-}" in
  -l) cat "$store" 2>/dev/null || true ;;
  -r) : >"$store" ;;
  *) cat "$1" >"$store" ;;
esac
EOF
chmod +x "$INSTALL_FIXTURE/bin/crontab"
export TEST_CRON_STORE="$CRON_STORE"
PUUN_ROOT_PREFIX="$INSTALL_FIXTURE/root" PUUN_CRONTAB="$INSTALL_FIXTURE/bin/crontab" bash "$INSTALLER" install
assert "installer removes upstream update-check cron" not_grep_fixed "update -check" "$CRON_STORE"
assert "installer preserves unrelated cron" grep -Fq "keep-me" "$CRON_STORE"
assert "installer does not remove scheduled non-check update.sh commands" grep -Fq "/etc/ultimate-updater/update.sh host" "$CRON_STORE"
CONFIG_PATH="$INSTALL_FIXTURE/root/etc/proxmox-ultimate-updater-notify/config"
printf '\nLOCAL_OPERATOR_VALUE="preserve-me"\n' >>"$CONFIG_PATH"
PUUN_ROOT_PREFIX="$INSTALL_FIXTURE/root" PUUN_CRONTAB="$INSTALL_FIXTURE/bin/crontab" bash "$INSTALLER" install
assert "reinstall preserves operator config" grep -Fq 'LOCAL_OPERATOR_VALUE="preserve-me"' "$CONFIG_PATH"
PUUN_ROOT_PREFIX="$INSTALL_FIXTURE/root" PUUN_CRONTAB="$INSTALL_FIXTURE/bin/crontab" bash "$INSTALLER" uninstall
assert "uninstall restores original update-check cron" grep -Fq "/usr/local/sbin/update -check" "$CRON_STORE"
assert "uninstall preserves operator config and token directory" grep -Fq 'LOCAL_OPERATOR_VALUE="preserve-me"' "$CONFIG_PATH"
rm -rf "$INSTALL_FIXTURE"
unset TEST_CRON_STORE

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
