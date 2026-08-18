# Operations

## Notification behavior

The notifier sends ntfy messages when:

- updates first become available;
- the available update set changes;
- a previously reported update state clears;
- an automatic check fails or a failure changes;
- an automatic check recovers;
- an operator-triggered Ultimate Updater run succeeds;
- an operator-triggered run fails;
- Ultimate Updater reports `Finished, with errors.` even when its process exit status is zero;
- upstream compatibility health fails or the failure changes;
- compatibility health recovers;
- upstream interface files change and the new state passes compatibility validation.

Unchanged automatic and compatibility states are deduplicated. Multiple filesystem events from the same completed manual run are suppressed for a short window, while a later identical manual run can notify again.

Update-availability and changed-update notifications use ntfy Markdown with:

- a target/update/security/reboot summary;
- one heading per Proxmox host, LXC, or VM target;
- package name and candidate version bullets;
- a lock marker for security updates;
- an explicit **Reboot required** callout for affected targets.

Health, failure, recovery, and manual-run messages remain plain text so diagnostic output is not interpreted as Markdown.

## Verify the installation

Run compatibility health directly:

```bash
sudo /usr/local/libexec/proxmox-ultimate-updater-notify health
```

Run a non-installing update check:

```bash
sudo /usr/local/libexec/proxmox-ultimate-updater-notify check
```

The compatibility preflight runs first automatically.

Inspect the systemd schedule and manual-run watcher:

```bash
systemctl status proxmox-ultimate-updater-notify-check.timer
systemctl status proxmox-ultimate-updater-notify-manual.path
systemctl list-timers proxmox-ultimate-updater-notify-check.timer
```

The packaged timer runs at 07:00 and 19:00.

## Install behavior

Running:

```bash
sudo bash install.sh
```

performs these bounded changes:

1. installs the notifier under `/usr/local/libexec/`;
2. installs its systemd service, timer, and path units;
3. creates `/etc/proxmox-ultimate-updater-notify/config` only when it does not already exist;
4. preserves operator-owned configuration on reinstall;
5. takes over matching upstream automatic-check cron entries while preserving their original lines for uninstall;
6. enables the check timer and manual-log path watcher.

The installer does not create, guess, or download ntfy/Gatus credentials.

## Manual updates

Continue to invoke Ultimate Updater manually when you decide to install updates. The companion observes completion through the upstream log and does not wrap or replace the normal Ultimate Updater command.

After a completed manual run, compatibility health is checked again so an upstream self-update or interface change is noticed immediately.

## Uninstall

```bash
sudo bash install.sh uninstall
```

Uninstall:

- disables and removes the companion systemd units and executable;
- restores exact saved Ultimate Updater automatic-check lines to their original root-user or system-wide cron source when they are not already present;
- removes companion runtime state;
- deliberately preserves `/etc/proxmox-ultimate-updater-notify` so operator configuration and token files are not destroyed.

If you also want to remove preserved configuration or token files, review and delete that directory separately after uninstall.
