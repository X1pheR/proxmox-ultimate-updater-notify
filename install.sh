#!/usr/bin/env bash
set -Eeuo pipefail

APP="proxmox-ultimate-updater-notify"
PREFIX="${PUUN_ROOT_PREFIX:-}"
LIBEXEC_DIR="${PREFIX}/usr/local/libexec"
CONFIG_DIR="${PREFIX}/etc/${APP}"
SYSTEMD_DIR="${PREFIX}/etc/systemd/system"
STATE_DIR="${PREFIX}/var/lib/${APP}"
CRON_BACKUP="${STATE_DIR}/original-update-check-cron"
SYSTEMCTL="${PUUN_SYSTEMCTL:-systemctl}"
CRONTAB="${PUUN_CRONTAB:-crontab}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

is_test_root() {
  [[ -n "$PREFIX" ]]
}

require_root() {
  if ! is_test_root && [[ ${EUID} -ne 0 ]]; then
    printf 'Run this installer as root.\n' >&2
    exit 1
  fi
}

is_updater_check_cron() {
  local line=$1
  [[ "$line" =~ (^|[[:space:]])(/usr/local/sbin/)?update[[:space:]]+-check([[:space:]]|$) ]] ||
    [[ "$line" =~ (^|[[:space:]])/etc/ultimate-updater/update\.sh[[:space:]]+-check([[:space:]]|$) ]] ||
    [[ "$line" =~ (^|[[:space:]])/etc/ultimate-updater/check-updates\.sh([[:space:]]|$) ]]
}

read_root_crontab() {
  "$CRONTAB" -l 2>/dev/null || true
}

write_root_crontab() {
  local file=$1
  if [[ -s "$file" ]]; then
    "$CRONTAB" "$file"
  else
    "$CRONTAB" -r 2>/dev/null || true
  fi
}

migrate_updater_cron() {
  local current
  local kept
  local line
  local found=false

  install -d -m 0700 "$STATE_DIR"
  current=$(mktemp)
  kept=$(mktemp)
  read_root_crontab >"$current"

  if [[ ! -e "$CRON_BACKUP" ]]; then
    : >"$CRON_BACKUP"
    chmod 0600 "$CRON_BACKUP"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if is_updater_check_cron "$line"; then
        printf '%s\n' "$line" >>"$CRON_BACKUP"
        found=true
      else
        printf '%s\n' "$line" >>"$kept"
      fi
    done <"$current"
    if [[ "$found" == true ]]; then
      write_root_crontab "$kept"
    fi
    rm -f "$current" "$kept"
    return
  fi

  # Reinstall: remove a reintroduced upstream checker but never overwrite the
  # original pre-install backup.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_updater_check_cron "$line"; then
      found=true
    else
      printf '%s\n' "$line" >>"$kept"
    fi
  done <"$current"
  if [[ "$found" == true ]]; then
    write_root_crontab "$kept"
  fi
  rm -f "$current" "$kept"
}

restore_updater_cron() {
  local current
  local merged
  local line

  [[ -e "$CRON_BACKUP" ]] || return 0
  current=$(mktemp)
  merged=$(mktemp)
  read_root_crontab >"$current"
  cat "$current" >"$merged"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if ! grep -Fqx -- "$line" "$merged"; then
      printf '%s\n' "$line" >>"$merged"
    fi
  done <"$CRON_BACKUP"

  write_root_crontab "$merged"
  rm -f "$current" "$merged"
}

install_product() {
  require_root
  install -d -m 0755 "$LIBEXEC_DIR" "$SYSTEMD_DIR"
  install -d -m 0750 "$CONFIG_DIR"
  install -d -m 0700 "$STATE_DIR"
  install -m 0755 "$SCRIPT_DIR/src/$APP" "$LIBEXEC_DIR/$APP"
  install -m 0644 "$SCRIPT_DIR/systemd/$APP-check.service" "$SYSTEMD_DIR/$APP-check.service"
  install -m 0644 "$SCRIPT_DIR/systemd/$APP-check.timer" "$SYSTEMD_DIR/$APP-check.timer"
  install -m 0644 "$SCRIPT_DIR/systemd/$APP-manual.service" "$SYSTEMD_DIR/$APP-manual.service"
  install -m 0644 "$SCRIPT_DIR/systemd/$APP-manual.path" "$SYSTEMD_DIR/$APP-manual.path"

  if [[ ! -e "$CONFIG_DIR/config" ]]; then
    install -m 0640 "$SCRIPT_DIR/config.example" "$CONFIG_DIR/config"
  fi

  migrate_updater_cron

  if ! is_test_root; then
    "$SYSTEMCTL" daemon-reload
    "$SYSTEMCTL" enable --now "$APP-check.timer" "$APP-manual.path"
  fi
}

uninstall_product() {
  require_root

  if ! is_test_root; then
    "$SYSTEMCTL" disable --now "$APP-check.timer" "$APP-manual.path" 2>/dev/null || true
    "$SYSTEMCTL" stop "$APP-check.service" "$APP-manual.service" 2>/dev/null || true
  fi

  restore_updater_cron
  rm -f \
    "$SYSTEMD_DIR/$APP-check.service" \
    "$SYSTEMD_DIR/$APP-check.timer" \
    "$SYSTEMD_DIR/$APP-manual.service" \
    "$SYSTEMD_DIR/$APP-manual.path" \
    "$LIBEXEC_DIR/$APP"

  # Preserve operator configuration and ntfy token by design.
  rm -f \
    "$CRON_BACKUP" \
    "$STATE_DIR/check-status" \
    "$STATE_DIR/check-hash" \
    "$STATE_DIR/manual-signature" \
    "$STATE_DIR/manual-time"
  rmdir "$STATE_DIR" 2>/dev/null || true

  if ! is_test_root; then
    "$SYSTEMCTL" daemon-reload
  fi
}

case "${1:-install}" in
  install)
    install_product
    ;;
  uninstall)
    uninstall_product
    ;;
  *)
    printf 'Usage: %s [install|uninstall]\n' "$0" >&2
    exit 2
    ;;
esac
