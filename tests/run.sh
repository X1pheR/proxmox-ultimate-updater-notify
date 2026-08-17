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
LOG_FILE="LOG_FILE_PLACEHOLDER"
ERROR_LOG_FILE="ERROR_LOG_PLACEHOLDER"
EOF
  sed -i "s|LOG_FILE_PLACEHOLDER|$FIXTURE/ultimate-updater.log|; s|ERROR_LOG_PLACEHOLDER|$FIXTURE/updater-error.log|" "$FIXTURE/updater/update.conf"
  cat >"$FIXTURE/updater/tag-filter.sh" <<'EOF'
apply_only_exclude_tags() { return 0; }
EOF
  cat >"$FIXTURE/updater/update.sh" <<'EOF'
#!/usr/bin/env bash
VERSION="5.0"
EOF
  : >"$FIXTURE/crontab"
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

  cat >"$FIXTURE/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-l" ]]; then
  cat "$TEST_FIXTURE/crontab"
  exit 0
fi
exit 1
EOF

  cat >"$FIXTURE/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  is-active:proxmox-ultimate-updater-notify-manual.path)
    [[ "${TEST_MANUAL_PATH_INACTIVE:-false}" == "true" ]] && exit 1
    exit 0
    ;;
  is-enabled:proxmox-ultimate-updater-notify-check.timer|is-enabled:proxmox-ultimate-updater-notify-manual.path|is-active:proxmox-ultimate-updater-notify-check.timer)
    exit 0
    ;;
  *) exit 1 ;;
esac
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
  *"sudo -n /usr/bin/apt-get update -y"*)
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
  export PUUN_CRONTAB="$FIXTURE/bin/crontab"
  export PUUN_SYSTEMCTL="$FIXTURE/bin/systemctl"
}

cleanup_fixture() {
  rm -rf "$FIXTURE"
  unset TEST_FIXTURE TEST_REFRESH_FAIL TEST_CURL_FAIL TEST_MANUAL_PATH_INACTIVE PUUN_CONFIG_FILE PUUN_STATE_DIR PUUN_UPDATER_DIR PUUN_UPDATER_CONFIG PUUN_UPDATER_LOG PUUN_CRONTAB PUUN_SYSTEMCTL
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

# Compatibility health: a reintroduced upstream check cron is unsafe and must alert.
new_fixture
printf '0 7 * * * /etc/ultimate-updater/update.sh -check >/dev/null 2>&1\n' >"$FIXTURE/crontab"
set +e
bash "$APP" health >/dev/null 2>&1
health_cron_rc=$?
set -e
assert "reintroduced upstream check cron fails compatibility health" test "$health_cron_rc" -ne 0
assert "compatibility health failure sends a dedicated ntfy warning" grep -Fq "Compatibility check failed" "$FIXTURE/curl-stdin"
cleanup_fixture

# Compatibility health must fail closed if root-crontab inspection is unavailable.
new_fixture
export PUUN_CRONTAB="$FIXTURE/bin/missing-crontab"
set +e
bash "$APP" health >/dev/null 2>&1
health_crontab_missing_rc=$?
set -e
assert "missing crontab inspector fails compatibility health" test "$health_crontab_missing_rc" -ne 0
assert "missing crontab inspector is reported through ntfy" grep -Fq "required command not found" "$FIXTURE/curl-args"
cleanup_fixture

# Failed ntfy delivery must not poison compatibility-health dedupe state.
new_fixture
printf '0 7 * * * /etc/ultimate-updater/update.sh -check >/dev/null 2>&1\n' >"$FIXTURE/crontab"
export TEST_CURL_FAIL=true
set +e
bash "$APP" health >/dev/null 2>&1
health_notify_fail_rc=$?
set -e
assert "ntfy delivery failure keeps compatibility health non-zero" test "$health_notify_fail_rc" -ne 0
assert "failed compatibility ntfy delivery does not persist dedupe state" test ! -e "$FIXTURE/state/health-status"
unset TEST_CURL_FAIL
set +e
bash "$APP" health >/dev/null 2>&1
health_retry_rc=$?
bash "$APP" health >/dev/null 2>&1
health_repeat_rc=$?
set -e
assert "compatibility failure retries after ntfy recovers" test "$health_retry_rc" -ne 0
assert "repeated compatibility failure remains non-zero" test "$health_repeat_rc" -ne 0
assert "delivered identical compatibility failure is then deduplicated" test "$(count_curl)" -eq 2
cleanup_fixture

# Automatic checks must run compatibility health first and fail closed on incompatibility.
new_fixture
printf '0 7 * * * /etc/ultimate-updater/update.sh -check >/dev/null 2>&1\n' >"$FIXTURE/crontab"
set +e
bash "$APP" check >/dev/null 2>&1
check_health_rc=$?
set -e
assert "automatic check fails closed when compatibility health fails" test "$check_health_rc" -ne 0
assert "failed compatibility preflight prevents update-state collection" test ! -e "$FIXTURE/state/check-status"
assert "automatic check reports compatibility failure through ntfy" grep -Fq "Compatibility check failed" "$FIXTURE/curl-stdin"
cleanup_fixture

# Compatibility health: upstream manual-log path must remain aligned with the observer.
new_fixture
sed -i "s|^LOG_FILE=.*|LOG_FILE=\"$FIXTURE/moved-upstream.log\"|" "$FIXTURE/updater/update.conf"
set +e
bash "$APP" health >/dev/null 2>&1
health_log_rc=$?
set -e
assert "changed upstream manual-log path fails compatibility health" test "$health_log_rc" -ne 0
assert "changed upstream manual-log path is reported through ntfy" grep -Fq "LOG_FILE" "$FIXTURE/curl-args"
cleanup_fixture

# Compatibility health: companion scheduling/watch units must remain active.
new_fixture
export TEST_MANUAL_PATH_INACTIVE=true
set +e
bash "$APP" health >/dev/null 2>&1
health_path_rc=$?
set -e
assert "inactive manual path watcher fails compatibility health" test "$health_path_rc" -ne 0
assert "inactive manual path watcher is reported through ntfy" grep -Fq "manual.path" "$FIXTURE/curl-args"
cleanup_fixture

# Compatibility health: a healthy upstream change is reported once after validation.
new_fixture
bash "$APP" health
assert "initial healthy compatibility baseline is silent" test "$(count_curl)" -eq 0
cat >"$FIXTURE/updater/update.sh" <<'EOF'
#!/usr/bin/env bash
VERSION="5.1"
EOF
bash "$APP" health
assert "validated upstream change sends one ntfy notification" test "$(count_curl)" -eq 1
assert "validated upstream change reports the version transition" grep -Fq "5.0 -> 5.1" "$FIXTURE/curl-args"
bash "$APP" health
assert "unchanged validated upstream state is deduplicated" test "$(count_curl)" -eq 1
cleanup_fixture

# Compatibility health: a previously reported incompatibility sends one recovery notification.
new_fixture
bash "$APP" health
cat >"$FIXTURE/updater/tag-filter.sh" <<'EOF'
# Broken helper interface.
EOF
set +e
bash "$APP" health >/dev/null 2>&1
health_failure_rc=$?
set -e
assert "compatibility failure remains non-zero before recovery" test "$health_failure_rc" -ne 0
cat >"$FIXTURE/updater/tag-filter.sh" <<'EOF'
apply_only_exclude_tags() { return 0; }
EOF
bash "$APP" health
assert "compatibility recovery sends a second ntfy notification" test "$(count_curl)" -eq 2
assert "compatibility recovery uses a dedicated recovery title" grep -Fq "Compatibility check recovered" "$FIXTURE/curl-stdin"
bash "$APP" health
assert "healthy compatibility recovery state is deduplicated" test "$(count_curl)" -eq 2
cleanup_fixture

# Compatibility health: upstream selection helper must remain callable.
new_fixture
cat >"$FIXTURE/updater/tag-filter.sh" <<'EOF'
# Simulate an incompatible upstream helper interface.
EOF
set +e
bash "$APP" health >/dev/null 2>&1
health_helper_rc=$?
set -e
assert "missing upstream tag helper fails compatibility health" test "$health_helper_rc" -ne 0
assert "tag helper incompatibility is reported through ntfy" grep -Fq "tag-filter.sh" "$FIXTURE/curl-args"
cleanup_fixture

# Completed manual runs must also revalidate compatibility after the manual notification.
new_fixture
bash "$APP" health
cat >"$FIXTURE/ultimate-updater.log" <<'EOF'
Updating Host : 192.0.2.1 | (pve)
--- PVE UPDATE ---
Finished, all updates done.
EOF
printf '0 7 * * * /etc/ultimate-updater/update.sh -check >/dev/null 2>&1\n' >"$FIXTURE/crontab"
set +e
bash "$APP" observe-manual >/dev/null 2>&1
manual_health_rc=$?
set -e
assert "manual completion still sends its normal notification before health alert" grep -Fq "Manual update succeeded" "$FIXTURE/curl-stdin"
assert "manual completion revalidates compatibility and reports failure" grep -Fq "Compatibility check failed" "$FIXTURE/curl-stdin"
assert "manual observer is non-zero when post-run compatibility fails" test "$manual_health_rc" -ne 0
cleanup_fixture

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

# Upstream tag-filter helpers are not guaranteed to be nounset-safe.
new_fixture
cat >"$FIXTURE/updater/tag-filter.sh" <<'EOF'
apply_only_exclude_tags() {
  declare -A seen=()
  local id=100
  [[ -z "${seen[$id]}" ]]
}
EOF
set +e
bash "$APP" check >/dev/null 2>&1
tag_filter_rc=$?
set -e
assert "upstream tag filter is isolated from companion nounset" test "$tag_filter_rc" -eq 0
cleanup_fixture

# Safe non-root SSH APT metadata refresh and update-state deduplication.
new_fixture
bash "$APP" check
assert "non-root SSH metadata refresh matches existing Ultimate Updater sudo rule" grep -Fq "sudo -n /usr/bin/apt-get update -y" "$FIXTURE/ssh-log"
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
STATE_PATH="$INSTALL_FIXTURE/root/var/lib/proxmox-ultimate-updater-notify"
printf 'failure\n' >"$STATE_PATH/health-status"
printf 'hash\n' >"$STATE_PATH/health-hash"
printf 'fingerprint\n' >"$STATE_PATH/upstream-fingerprint"
printf '5.0\n' >"$STATE_PATH/upstream-version"
PUUN_ROOT_PREFIX="$INSTALL_FIXTURE/root" PUUN_CRONTAB="$INSTALL_FIXTURE/bin/crontab" bash "$INSTALLER" uninstall
assert "uninstall restores original update-check cron" grep -Fq "/usr/local/sbin/update -check" "$CRON_STORE"
assert "uninstall removes compatibility health state" test ! -e "$STATE_PATH/health-status" -a ! -e "$STATE_PATH/health-hash" -a ! -e "$STATE_PATH/upstream-fingerprint" -a ! -e "$STATE_PATH/upstream-version"
assert "uninstall preserves operator config and token directory" grep -Fq 'LOCAL_OPERATOR_VALUE="preserve-me"' "$CONFIG_PATH"
rm -rf "$INSTALL_FIXTURE"
unset TEST_CRON_STORE

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
