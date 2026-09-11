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
VERSION="5.1"
EOF
  cat >"$FIXTURE/updater/status-model.sh" <<'EOF'
#!/usr/bin/env bash
# Fixture interface markers expected by companion compatibility validation.
STATUS_MODEL_FILE="${STATUS_MODEL_FILE:-status.json}"
# normal_updates security_updates reboot_required
STATUS_MODEL_RENDER_NOTIFICATION() {
  python3 - "${1:-$STATUS_MODEL_FILE}" <<'PYJSON'
import json
import sys
p=json.load(open(sys.argv[1], encoding="utf-8"))
targets=[t for t in p.get("targets",[]) if isinstance(t,dict)]
issues=[t for t in targets if t.get("check_status") in ("offline","error","unsupported","not_checked")]
updates=[t for t in targets if isinstance((t.get("updates") or {}).get("available"),int) and ((t.get("updates") or {}).get("available")>0 or t.get("reboot_required") is True)]
if issues:
    state="issues"
elif updates:
    state="updates"
elif targets:
    state="current"
else:
    state="empty"
print(f"STATE={state}")
print("Ultimate Updater status")
print("=======================")
print()
if updates:
    print("Available updates:")
    total=0
    for t in updates:
        available=(t.get("updates") or {}).get("available",0)
        total += available
        name=t.get("name") or t.get("node") or t.get("id")
        print(f"{t.get('type')} {t.get('id')} · {name}")
        print(f"S: {t.get('security_updates')} / N: {t.get('normal_updates')}")
    print()
    print(f"Total available updates: {total}")
    reboots=[t for t in targets if t.get("reboot_required") is True]
    if reboots:
        print()
        print("Reboot required:")
        for t in reboots:
            print(t.get("name") or t.get("node") or t.get("id"))
elif state == "current":
    print("Available updates: none")
if issues:
    print("Not checked:")
    for t in issues:
        print(t.get("name") or t.get("id"))
PYJSON
}
EOF
  cat >"$FIXTURE/updater/target-runtime.sh" <<'EOF'
#!/usr/bin/env bash
READ_APT_UPDATE_COUNTS() { :; }
EOF
  cat >"$FIXTURE/updater/check-updates.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INITIAL_INVENTORY=false
[[ "${UU_JOB_SOURCE:-}" == initial-inventory ]] && INITIAL_INVENTORY=true
# UU_DEFER_NOTIFICATION is honored by the real upstream checker.
HOST_KERNEL_REBOOT_REQUIRED () { :; }
[[ "${UU_DEFER_NOTIFICATION:-false}" == true ]] || exit 91
[[ "$INITIAL_INVENTORY" == true ]] || exit 92
printf 'job=%s defer=%s status=%s\n' "${UU_JOB_SOURCE:-}" "${UU_DEFER_NOTIFICATION:-}" "${STATUS_MODEL_FILE:-}" >>"$TEST_FIXTURE/upstream-check-log"
if [[ "${TEST_UPSTREAM_CHECK_FAIL:-false}" == true ]]; then
  printf 'simulated Ultimate Updater inventory failure\n' >&2
  exit 42
fi
cp "$TEST_FIXTURE/upstream-status.json" "$STATUS_MODEL_FILE"
EOF
  chmod +x "$FIXTURE/updater/check-updates.sh"
  : >"$FIXTURE/crontab"
  mkdir -p "$FIXTURE/cron.d"
  : >"$FIXTURE/system-crontab"
  cat >"$FIXTURE/updater/VMs/101" <<'EOF'
IP="192.0.2.101"
USER="ronald"
SSH_VM_PORT="22"
EOF
  printf 'Inst package-a [1.0] (1.1 stable [amd64])\n' >"$FIXTURE/apt-output"
  cat >"$FIXTURE/upstream-status.json" <<'EOF'
{
  "schema_version": 1,
  "generated_at": "2026-09-11T12:00:00Z",
  "targets": [
    {
      "id": "101",
      "type": "vm",
      "transport": "ssh",
      "reachable": true,
      "os": "Debian GNU/Linux",
      "updater": "apt",
      "updates": {"available": 1},
      "normal_updates": 1,
      "security_updates": 0,
      "reboot_required": false,
      "check_status": "updates_available",
      "error": null,
      "node": "pve",
      "name": "docker",
      "security_split_supported": true
    }
  ]
}
EOF
  : >"$FIXTURE/upstream-check-log"
  : >"$FIXTURE/curl-args"
  : >"$FIXTURE/curl-stdin"
  : >"$FIXTURE/curl-count"
  : >"$FIXTURE/curl-body"
  : >"$FIXTURE/ssh-log"
  : >"$FIXTURE/timeout-log"

  cat >"$FIXTURE/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_FIXTURE/curl-args"
cat >>"$TEST_FIXTURE/curl-stdin"
printf '1\n' >>"$TEST_FIXTURE/curl-count"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--data-binary" ]] && ((i + 1 < ${#args[@]})); then
    printf '%s' "${args[$((i + 1))]}" >"$TEST_FIXTURE/curl-body"
    if [[ "${TEST_NTFY_ENFORCE_MESSAGE_LIMIT:-false}" == "true" ]] && (( $(wc -c <"$TEST_FIXTURE/curl-body") > 4096 )); then
      exit 22
    fi
    break
  fi
done
if [[ "${TEST_CURL_FAIL:-false}" == "true" ]]; then
  exit 22
fi
if [[ "${TEST_HEARTBEAT_FAIL:-false}" == "true" && "$*" == *"gatus.example.invalid"* ]]; then
  exit 22
fi
if [[ "${TEST_NTFY_FAIL:-false}" == "true" && "$*" == *"ntfy.example.invalid"* ]]; then
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

  cat >"$FIXTURE/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_FIXTURE/timeout-log"
shift 3
exec "$@"
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
  *"test -f /var/run/reboot-required.pkgs"*)
    [[ "${TEST_REBOOT_REQUIRED:-false}" == "true" ]] && exit 0
    exit 1
    ;;
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
  export PUUN_SYSTEM_CRONTAB="$FIXTURE/system-crontab"
  export PUUN_CRON_D_DIR="$FIXTURE/cron.d"
  export PUUN_SYSTEMCTL="$FIXTURE/bin/systemctl"
}

cleanup_fixture() {
  rm -rf "$FIXTURE"
  unset TEST_FIXTURE TEST_REFRESH_FAIL TEST_UPSTREAM_CHECK_FAIL TEST_CURL_FAIL TEST_HEARTBEAT_FAIL TEST_NTFY_FAIL TEST_NTFY_ENFORCE_MESSAGE_LIMIT TEST_REBOOT_REQUIRED TEST_MANUAL_PATH_INACTIVE PUUN_SCHEDULED_RUN PUUN_CONFIG_FILE PUUN_STATE_DIR PUUN_UPDATER_DIR PUUN_UPDATER_CONFIG PUUN_UPDATER_LOG PUUN_CRONTAB PUUN_SYSTEMCTL PUUN_SYSTEM_CRONTAB PUUN_CRON_D_DIR
}

count_curl() {
  wc -l <"$FIXTURE/curl-count" | tr -d ' '
}

set_upstream_apt_status() {
  local normal=$1 security=$2 reboot=$3
  python3 - "$FIXTURE/upstream-status.json" "$normal" "$security" "$reboot" <<'PYJSON'
import json
import sys

path, normal, security, reboot = sys.argv[1:]
normal = int(normal)
security = int(security)
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
target = payload["targets"][0]
target["normal_updates"] = normal
target["security_updates"] = security
target["updates"]["available"] = normal + security
target["reboot_required"] = reboot == "true"
target["check_status"] = "updates_available" if normal + security or reboot == "true" else "ok"
with open(path, "w", encoding="utf-8") as output:
    json.dump(payload, output, indent=2)
    output.write("\n")
PYJSON
}

# Syntax and static safety.
assert "main script parses" bash -n "$APP"
assert "installer parses" bash -n "$INSTALLER"
assert "test script parses" bash -n "$0"
assert "automatic check service has a hard runtime cap" grep -Fqx "TimeoutStartSec=10min" "$REPO_DIR/systemd/proxmox-ultimate-updater-notify-check.service"
assert "automatic check service marks scheduled runs" grep -Fqx "Environment=PUUN_SCHEDULED_RUN=true" "$REPO_DIR/systemd/proxmox-ultimate-updater-notify-check.service"
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

# Compatibility health must also inspect system-wide cron sources.
new_fixture
mkdir -p "$FIXTURE/cron.d"
printf '00 06 * * * root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1\n' >"$FIXTURE/system-crontab"
export PUUN_SYSTEM_CRONTAB="$FIXTURE/system-crontab"
export PUUN_CRON_D_DIR="$FIXTURE/cron.d"
set +e
bash "$APP" health >/dev/null 2>&1
health_system_cron_rc=$?
set -e
assert "system crontab upstream checker fails compatibility health" test "$health_system_cron_rc" -ne 0
assert "system crontab failure sends compatibility warning" grep -Fq "Compatibility check failed" "$FIXTURE/curl-stdin"
cleanup_fixture

new_fixture
mkdir -p "$FIXTURE/cron.d"
: >"$FIXTURE/system-crontab"
printf '00 06 * * * root /etc/ultimate-updater/check-updates.sh >/dev/null 2>&1\n' >"$FIXTURE/cron.d/ultimate-updater"
export PUUN_SYSTEM_CRONTAB="$FIXTURE/system-crontab"
export PUUN_CRON_D_DIR="$FIXTURE/cron.d"
set +e
bash "$APP" health >/dev/null 2>&1
health_crond_rc=$?
set -e
assert "cron.d upstream checker fails compatibility health" test "$health_crond_rc" -ne 0
assert "cron.d failure sends compatibility warning" grep -Fq "Compatibility check failed" "$FIXTURE/curl-stdin"
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

# Compatibility health: the accepted 5.1 safety boundary is baselined once and then immutable.
new_fixture
bash "$APP" health
assert "initial healthy 5.1 compatibility baseline is silent" test "$(count_curl)" -eq 0
assert "initial healthy 5.1 compatibility baseline stores safety fingerprint" test -s "$FIXTURE/state/upstream-safety-fingerprint"
accepted_fingerprint=$(cat "$FIXTURE/state/upstream-safety-fingerprint" 2>/dev/null || printf missing)
printf '\n# simulated upstream source drift\n' >>"$FIXTURE/updater/check-updates.sh"
set +e
bash "$APP" health >/dev/null 2>&1
health_drift_rc=$?
set -e
assert "safety-critical upstream source drift fails compatibility health" test "$health_drift_rc" -ne 0
assert "safety-critical upstream source drift sends compatibility warning" grep -Fq "Compatibility check failed" "$FIXTURE/curl-stdin"
assert "failed upstream drift does not replace accepted safety fingerprint" grep -Fqx "$accepted_fingerprint" "$FIXTURE/state/upstream-safety-fingerprint"
cleanup_fixture

# Compatibility health: unsupported Ultimate Updater versions fail closed.
new_fixture
cat >"$FIXTURE/updater/update.sh" <<'EOF'
#!/usr/bin/env bash
VERSION="5.2"
EOF
set +e
bash "$APP" health >/dev/null 2>&1
health_version_rc=$?
set -e
assert "unsupported Ultimate Updater version fails compatibility health" test "$health_version_rc" -ne 0
assert "unsupported Ultimate Updater version is reported through ntfy" grep -Fq "5.2" "$FIXTURE/curl-args"
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

# Large manual logs must not trigger pipefail/broken-pipe behavior and ntfy bodies must stay below its 4 KiB default.
new_fixture
{
  for i in $(seq 1 900); do printf 'ordinary updater detail %04d: package metadata refreshed\n' "$i"; done
  printf 'Updating Host : 192.0.2.1 | (pve)\n'
  printf '%028200d\n' 0
  for i in $(seq 1 10); do printf 'post-target detail %02d\n' "$i"; done
  printf 'Updating VM 101 : docker\n'
  printf 'Finished, all updates done.\n'
} >"$FIXTURE/ultimate-updater.log"
export TEST_NTFY_ENFORCE_MESSAGE_LIMIT=true
set +e
bash "$APP" observe-manual >/dev/null 2>&1
large_manual_rc=$?
set -e
assert "large manual log completes without broken-pipe or ntfy-size failure" test "$large_manual_rc" -eq 0
assert "large manual run emits exactly one notification" test "$(count_curl)" -eq 1
assert "manual notification body remains below ntfy default limit" test "$(wc -c <"$FIXTURE/curl-body")" -le 4096
assert "manual notification keeps host target summary" grep -Fq 'Updating Host : 192.0.2.1 | (pve)' "$FIXTURE/curl-body"
assert "manual notification keeps VM target summary" grep -Fq 'Updating VM 101 : docker' "$FIXTURE/curl-body"
assert "manual target heading uses a real newline" not_grep_fixed 'Targets:\n' "$FIXTURE/curl-body"
assert "manual notification excludes oversized arbitrary detail" not_grep_fixed '0000000000000000000000000000' "$FIXTURE/curl-body"
cleanup_fixture

# Failed manual ntfy delivery must not persist dedupe state and must retry after recovery.
new_fixture
cat >"$FIXTURE/ultimate-updater.log" <<'EOF'
Updating Host : 192.0.2.1 | (pve)
Finished, all updates done.
EOF
export TEST_NTFY_FAIL=true
set +e
bash "$APP" observe-manual >/dev/null 2>&1
manual_notify_fail_rc=$?
set -e
assert "failed manual ntfy delivery keeps observer non-zero" test "$manual_notify_fail_rc" -ne 0
assert "failed manual ntfy delivery does not persist signature" test ! -e "$FIXTURE/state/manual-signature"
unset TEST_NTFY_FAIL
bash "$APP" observe-manual >/dev/null 2>&1
assert "manual notification retries after delivery recovers" test "$(count_curl)" -eq 2
assert "successful manual notification persists signature" test -s "$FIXTURE/state/manual-signature"
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

# Scheduled successful checks publish a Gatus external-endpoint heartbeat.
new_fixture
printf 'gatus-heartbeat-secret\n' >"$FIXTURE/gatus-token"
cat >>"$FIXTURE/config" <<EOF
GATUS_HEARTBEAT_URL="https://gatus.example.invalid/api/v1/endpoints/proxmox_ultimate-updater/external"
GATUS_HEARTBEAT_TOKEN_FILE="$FIXTURE/gatus-token"
EOF
export PUUN_SCHEDULED_RUN=true
bash "$APP" check
assert "scheduled successful check publishes Gatus heartbeat" grep -Fq "gatus.example.invalid/api/v1/endpoints/proxmox_ultimate-updater/external?success=true" "$FIXTURE/curl-args"
assert "Gatus heartbeat token is absent from curl argv" not_grep_fixed "gatus-heartbeat-secret" "$FIXTURE/curl-args"
assert "Gatus heartbeat token is delivered through curl stdin" grep -Fq "Authorization: Bearer gatus-heartbeat-secret" "$FIXTURE/curl-stdin"
assert "outbound notification and heartbeat HTTP calls are time-bounded" test "$(grep -Fc -- '--connect-timeout 10 --max-time 30' "$FIXTURE/curl-args")" -eq "$(count_curl)"
cleanup_fixture

# A scheduled heartbeat is emitted only after normal check-state notification succeeds.
new_fixture
printf 'gatus-heartbeat-secret\n' >"$FIXTURE/gatus-token"
cat >>"$FIXTURE/config" <<EOF
GATUS_HEARTBEAT_URL="https://gatus.example.invalid/api/v1/endpoints/proxmox_ultimate-updater/external"
GATUS_HEARTBEAT_TOKEN_FILE="$FIXTURE/gatus-token"
EOF
export PUUN_SCHEDULED_RUN=true
export TEST_NTFY_FAIL=true
set +e
bash "$APP" check >/dev/null 2>&1
ntfy_before_heartbeat_rc=$?
set -e
assert "ntfy delivery failure keeps scheduled check non-zero" test "$ntfy_before_heartbeat_rc" -ne 0
assert "failed normal notification does not advance Gatus heartbeat" not_grep_fixed "gatus.example.invalid" "$FIXTURE/curl-args"
cleanup_fixture

# Failed scheduled heartbeat is a check failure and is reported through ntfy.
new_fixture
printf 'gatus-heartbeat-secret\n' >"$FIXTURE/gatus-token"
cat >>"$FIXTURE/config" <<EOF
GATUS_HEARTBEAT_URL="https://gatus.example.invalid/api/v1/endpoints/proxmox_ultimate-updater/external"
GATUS_HEARTBEAT_TOKEN_FILE="$FIXTURE/gatus-token"
EOF
export PUUN_SCHEDULED_RUN=true
export TEST_HEARTBEAT_FAIL=true
set +e
bash "$APP" check >/dev/null 2>&1
heartbeat_fail_rc=$?
set -e
assert "failed scheduled heartbeat keeps check non-zero" test "$heartbeat_fail_rc" -ne 0
assert "failed scheduled heartbeat persists check failure state" grep -Fqx "failure" "$FIXTURE/state/check-status"
assert "failed scheduled heartbeat is reported through ntfy" grep -Fq "Gatus heartbeat delivery failed" "$FIXTURE/curl-args"
cleanup_fixture

# The delegated upstream inventory run remains bounded by GNU timeout.
new_fixture
bash "$APP" check
assert "Ultimate Updater inventory execution is bounded" grep -Fq "540s env UU_JOB_SOURCE=initial-inventory" "$FIXTURE/timeout-log"
cleanup_fixture

# Update-state deduplication is driven by Ultimate Updater's structured status.
new_fixture
bash "$APP" check
assert "companion no longer performs direct guest SSH package collection" test ! -s "$FIXTURE/ssh-log"
assert "first available-update state notifies" test "$(count_curl)" -eq 1
assert "native Ultimate Updater notification remains plain text" not_grep_fixed "Markdown: yes" "$FIXTURE/curl-stdin"
assert "available-update notification forwards Ultimate Updater status heading" grep -Fq 'Ultimate Updater status' "$FIXTURE/curl-args"
assert "available-update notification forwards target identity" grep -Fq 'vm 101 · docker' "$FIXTURE/curl-args"
assert "available-update notification forwards Ultimate Updater split" grep -Fq 'S: 0 / N: 1' "$FIXTURE/curl-args"
assert "available-update notification forwards Ultimate Updater total" grep -Fq 'Total available updates: 1' "$FIXTURE/curl-args"
bash "$APP" check
assert "unchanged update state is deduplicated" test "$(count_curl)" -eq 1
set_upstream_apt_status 2 0 false
bash "$APP" check
assert "changed update state notifies" test "$(count_curl)" -eq 2
set_upstream_apt_status 0 0 false
bash "$APP" check
assert "cleared update state notifies" test "$(count_curl)" -eq 3
cleanup_fixture

# Canonical Ultimate Updater status owns split counts and reboot state.
new_fixture
set_upstream_apt_status 2 5 true
bash "$APP" check
assert "automatic check delegates to Ultimate Updater initial-inventory mode" grep -Fq 'job=initial-inventory defer=true' "$FIXTURE/upstream-check-log"
assert "Ultimate Updater normal/security split is preserved" grep -Fq 'S: 5 / N: 2' "$FIXTURE/curl-args"
assert "Ultimate Updater total is preserved" grep -Fq 'Total available updates: 7' "$FIXTURE/curl-args"
assert "Ultimate Updater reboot state is visibly called out" grep -Fq 'Reboot required:' "$FIXTURE/curl-args"
cleanup_fixture

new_fixture
set_upstream_apt_status 2 5 true
bash "$APP" check
assert "ntfy forwards Ultimate Updater native status heading" grep -Fq 'Ultimate Updater status' "$FIXTURE/curl-args"
assert "ntfy forwards Ultimate Updater native split line" grep -Fq 'S: 5 / N: 2' "$FIXTURE/curl-args"
assert "ntfy forwards Ultimate Updater native total" grep -Fq 'Total available updates: 7' "$FIXTURE/curl-args"
cleanup_fixture

# Security updates are rendered from Ultimate Updater's disjoint split.
new_fixture
set_upstream_apt_status 0 1 false
bash "$APP" check
assert "security update split is rendered by Ultimate Updater" grep -Fq 'S: 1 / N: 0' "$FIXTURE/curl-args"
assert "security update total is rendered by Ultimate Updater" grep -Fq 'Total available updates: 1' "$FIXTURE/curl-args"
cleanup_fixture

# Reboot-required state remains explicit even without a Debian marker in the companion.
new_fixture
set_upstream_apt_status 1 0 true
bash "$APP" check
assert "reboot-required target keeps its update split" grep -Fq 'S: 0 / N: 1' "$FIXTURE/curl-args"
assert "reboot-required section is forwarded from Ultimate Updater" grep -Fq 'Reboot required:' "$FIXTURE/curl-args"
assert "reboot-required target identity is forwarded" grep -Fq 'docker' "$FIXTURE/curl-args"
cleanup_fixture

# Ultimate Updater targets that were selected but not checked remain visible as check issues.
new_fixture
python3 - "$FIXTURE/upstream-status.json" <<'PYJSON'
import json,sys
path=sys.argv[1]
p=json.load(open(path))
t=p["targets"][0]
t["check_status"]="not_checked"
t["reachable"]=False
t["updates"]["available"]=None
t["normal_updates"]=None
t["security_updates"]=None
t["reboot_required"]=None
json.dump(p, open(path,"w"), indent=2)
PYJSON
set +e
bash "$APP" check >/dev/null 2>&1
not_checked_rc=$?
set -e
assert "selected target not checked keeps scheduled check non-zero" test "$not_checked_rc" -ne 0
assert "selected target not checked is reported through native Ultimate Updater body" grep -Fq 'Not checked:' "$FIXTURE/curl-args"
assert "selected target not checked persists failure state" grep -Fqx 'failure' "$FIXTURE/state/check-status"
cleanup_fixture

# Failed ntfy delivery must not poison failure dedupe state.
new_fixture
export TEST_UPSTREAM_CHECK_FAIL=true
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
assert "repeated Ultimate Updater inventory failure remains non-zero" test "$second_rc" -ne 0
assert "delivered identical check failure is then deduplicated" test "$(count_curl)" -eq 2
unset TEST_UPSTREAM_CHECK_FAIL
bash "$APP" check
assert "recovered check state notifies" test "$(count_curl)" -eq 4
# Recovery from failure with available updates sends recovery + available state.
cleanup_fixture

# Install -> reinstall -> uninstall, config preservation, cron replacement/restoration.
INSTALL_FIXTURE=$(mktemp -d)
mkdir -p "$INSTALL_FIXTURE/bin" "$INSTALL_FIXTURE/root/etc/cron.d"
CRON_STORE="$INSTALL_FIXTURE/crontab"
SYSTEM_CRON_STORE="$INSTALL_FIXTURE/root/etc/crontab"
CRON_D_STORE="$INSTALL_FIXTURE/root/etc/cron.d/ultimate-updater"
cat >"$SYSTEM_CRON_STORE" <<'EOF'
17 * * * * root cd / && run-parts --report /etc/cron.hourly
00 06 * * * root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1
EOF
cat >"$CRON_D_STORE" <<'EOF'
# keep this comment
30 4 * * * root /etc/ultimate-updater/check-updates.sh >/dev/null 2>&1
EOF
printf '15 3 * * * root /usr/local/bin/housekeeping\n' >"$INSTALL_FIXTURE/root/etc/cron.d/housekeeping"
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
assert "installer removes system crontab upstream checker" not_grep_fixed "update -check" "$SYSTEM_CRON_STORE"
assert "installer removes cron.d upstream checker" not_grep_fixed "check-updates.sh" "$CRON_D_STORE"
assert "installer preserves system crontab unrelated line" grep -Fq "run-parts --report /etc/cron.hourly" "$SYSTEM_CRON_STORE"
assert "installer preserves cron.d unrelated content" grep -Fq "# keep this comment" "$CRON_D_STORE"
assert "installer does not persist empty backup for unrelated cron.d source" test ! -e "$INSTALL_FIXTURE/root/var/lib/proxmox-ultimate-updater-notify/original-update-check-cron-d/housekeeping"
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
printf 'safety-fingerprint\n' >"$STATE_PATH/upstream-safety-fingerprint"
printf '5.1\n' >"$STATE_PATH/upstream-version"
PUUN_ROOT_PREFIX="$INSTALL_FIXTURE/root" PUUN_CRONTAB="$INSTALL_FIXTURE/bin/crontab" bash "$INSTALLER" uninstall
assert "uninstall restores original update-check cron" grep -Fq "/usr/local/sbin/update -check" "$CRON_STORE"
assert "uninstall restores system crontab upstream checker" grep -Fq "RUN_FROM_CRON=true /usr/local/sbin/update -check" "$SYSTEM_CRON_STORE"
assert "uninstall restores cron.d upstream checker" grep -Fq "/etc/ultimate-updater/check-updates.sh" "$CRON_D_STORE"
assert "uninstall removes compatibility health state" test ! -e "$STATE_PATH/health-status" -a ! -e "$STATE_PATH/health-hash" -a ! -e "$STATE_PATH/upstream-fingerprint" -a ! -e "$STATE_PATH/upstream-safety-fingerprint" -a ! -e "$STATE_PATH/upstream-version"
assert "uninstall preserves operator config and token directory" grep -Fq 'LOCAL_OPERATOR_VALUE="preserve-me"' "$CONFIG_PATH"
rm -rf "$INSTALL_FIXTURE"
unset TEST_CRON_STORE

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
