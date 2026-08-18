#!/usr/bin/env bash
set -Eeuo pipefail

APP="proxmox-ultimate-updater-notify"
PREFIX="${PUUN_ROOT_PREFIX:-}"
LIBEXEC_DIR="${PREFIX}/usr/local/libexec"
CONFIG_DIR="${PREFIX}/etc/${APP}"
SYSTEMD_DIR="${PREFIX}/etc/systemd/system"
STATE_DIR="${PREFIX}/var/lib/${APP}"
CRON_BACKUP="${STATE_DIR}/original-update-check-cron"
SYSTEM_CRON_BACKUP="${STATE_DIR}/original-update-check-system-crontab"
CRON_D_BACKUP_DIR="${STATE_DIR}/original-update-check-cron-d"
CRON_D_INITIALIZED="${STATE_DIR}/cron-d-initialized"
SYSTEM_CRONTAB="${PUUN_SYSTEM_CRONTAB:-${PREFIX}/etc/crontab}"
CRON_D_DIR="${PUUN_CRON_D_DIR:-${PREFIX}/etc/cron.d}"
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

filter_cron_file() {
  local source=$1
  local backup=$2
  local capture_original=$3
  local kept
  local line
  local found=false

  [[ -f "$source" ]] || return 0
  kept=$(mktemp)
  if [[ "$capture_original" == true ]]; then
    : >"$backup"
    chmod 0600 "$backup"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_updater_check_cron "$line"; then
      found=true
      if [[ "$capture_original" == true ]]; then
        printf '%s\n' "$line" >>"$backup"
      fi
    else
      printf '%s\n' "$line" >>"$kept"
    fi
  done <"$source"

  if [[ "$found" == true ]]; then
    cat "$kept" >"$source"
  fi
  rm -f "$kept"
}

migrate_system_cron() {
  local capture=true

  install -d -m 0700 "$STATE_DIR"
  if [[ -e "$SYSTEM_CRON_BACKUP" ]]; then
    capture=false
  fi
  filter_cron_file "$SYSTEM_CRONTAB" "$SYSTEM_CRON_BACKUP" "$capture"
  if [[ "$capture" == true && ! -e "$SYSTEM_CRON_BACKUP" ]]; then
    : >"$SYSTEM_CRON_BACKUP"
    chmod 0600 "$SYSTEM_CRON_BACKUP"
  fi
}

migrate_cron_d() {
  local cron_file
  local backup
  local capture=false

  install -d -m 0700 "$STATE_DIR" "$CRON_D_BACKUP_DIR"
  [[ ! -e "$CRON_D_INITIALIZED" ]] && capture=true
  if [[ -d "$CRON_D_DIR" ]]; then
    for cron_file in "$CRON_D_DIR"/*; do
      [[ -f "$cron_file" ]] || continue
      backup="$CRON_D_BACKUP_DIR/$(basename "$cron_file")"
      if [[ "$capture" == true ]]; then
        filter_cron_file "$cron_file" "$backup" true
        [[ -s "$backup" ]] || rm -f "$backup"
      else
        filter_cron_file "$cron_file" "$backup" false
      fi
    done
  fi
  : >"$CRON_D_INITIALIZED"
  chmod 0600 "$CRON_D_INITIALIZED"
}

restore_cron_file_lines() {
  local source=$1
  local backup=$2
  local line

  [[ -s "$backup" ]] || return 0
  if [[ ! -e "$source" ]]; then
    install -d -m 0755 "$(dirname "$source")"
    install -m 0644 /dev/null "$source"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if ! grep -Fqx -- "$line" "$source"; then
      printf '%s\n' "$line" >>"$source"
    fi
  done <"$backup"
}

restore_system_cron() {
  restore_cron_file_lines "$SYSTEM_CRONTAB" "$SYSTEM_CRON_BACKUP"
}

restore_cron_d() {
  local backup
  local source

  [[ -d "$CRON_D_BACKUP_DIR" ]] || return 0
  for backup in "$CRON_D_BACKUP_DIR"/*; do
    [[ -f "$backup" ]] || continue
    source="$CRON_D_DIR/$(basename "$backup")"
    restore_cron_file_lines "$source" "$backup"
  done
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
  migrate_system_cron
  migrate_cron_d

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
  restore_system_cron
  restore_cron_d
  rm -f \
    "$SYSTEMD_DIR/$APP-check.service" \
    "$SYSTEMD_DIR/$APP-check.timer" \
    "$SYSTEMD_DIR/$APP-manual.service" \
    "$SYSTEMD_DIR/$APP-manual.path" \
    "$LIBEXEC_DIR/$APP"

  # Preserve operator configuration and ntfy token by design.
  rm -f \
    "$CRON_BACKUP" \
    "$SYSTEM_CRON_BACKUP" \
    "$CRON_D_INITIALIZED" \
    "$STATE_DIR/check-status" \
    "$STATE_DIR/check-hash" \
    "$STATE_DIR/health-status" \
    "$STATE_DIR/health-hash" \
    "$STATE_DIR/upstream-fingerprint" \
    "$STATE_DIR/upstream-version" \
    "$STATE_DIR/manual-signature" \
    "$STATE_DIR/manual-time"
  if [[ -d "$CRON_D_BACKUP_DIR" ]]; then
    rm -f "$CRON_D_BACKUP_DIR"/*
    rmdir "$CRON_D_BACKUP_DIR" 2>/dev/null || true
  fi
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
