# Safety and compatibility

The notifier exists to provide useful automatic update visibility without inheriting mutating behavior from Ultimate Updater's automatic-check paths.

## Automatic-check boundary

The companion deliberately separates **checking** from **installing**.

Automatic checks:

- refresh APT package metadata;
- simulate upgrades with `apt-get -s upgrade`;
- report available package updates and reboot-required state;
- never install package updates;
- never start, stop, resume, suspend, or reboot Proxmox guests;
- never invoke upstream `update -check` or `/etc/ultimate-updater/check-updates.sh` automatically.

Actual package installation remains operator-triggered through Ultimate Updater.

The upstream automatic checker is intentionally excluded because some non-APT paths can execute package upgrades or temporarily change guest power state. The companion fails closed rather than falling back to those paths.

## Compatibility baseline

The initial supported baseline is intentionally narrow:

- Proxmox VE host running Ultimate Updater 5.0 with its current `/etc/ultimate-updater` layout;
- Debian-family APT LXC targets: `debian`, `ubuntu`, and `devuan`;
- APT-detected Linux VMs;
- running guests only for automatic checks;
- SSH-managed VMs or QEMU Guest Agent managed VMs.

Stopped or paused guests selected for automatic checking are reported as unsafe conditions. They are not started or resumed to complete a check.

Unsupported package-manager families and unavailable target access fail the check.

## Upstream compatibility health

Before every automatic update check, the notifier validates the upstream integration boundary. A completed manual Ultimate Updater run validates the same boundary again after its normal completion notification.

The health check verifies that:

- `/etc/ultimate-updater/update.sh` is readable and still exposes a version marker;
- `tag-filter.sh` exists and still exposes a callable `apply_only_exclude_tags` interface;
- Ultimate Updater's configured `LOG_FILE` still matches the manual observer path;
- no upstream automatic `update -check` or `check-updates.sh` entry exists in root's user crontab, `/etc/crontab`, or `/etc/cron.d`;
- the companion check timer and manual path watcher remain enabled and active.

A failed compatibility probe blocks the automatic package check and sends a deduplicated ntfy warning. Recovery sends one recovery notification. If the upstream interface files change but the new state remains compatible, one informational notification confirms that the changed interface was validated.

The health path does **not** silently rewrite newly detected upstream drift.

## Cron ownership and restoration

During installation, matching upstream automatic-check entries are removed from:

- root's user crontab;
- `/etc/crontab`;
- files under `/etc/cron.d`.

The exact original matching lines are stored in root-only installer state. Reinstall removes reintroduced matching entries without overwriting the original backup.

Uninstall restores the saved lines to their original cron source when they are not already present. Unrelated cron lines are left alone.

This makes the companion systemd timer the only intended automatic update-check path while the companion is installed.

## Runtime bounds

Potentially blocking APT, LXC, SSH, and QEMU guest operations are bounded to 120 seconds per command.

Outbound ntfy and Gatus HTTP calls use:

- 10-second connect timeout;
- 30-second total timeout.

The complete systemd automatic-check service has a 10-minute `TimeoutStartSec` cap.

These limits are safety bounds, not expected normal runtimes.

## Upstream relationship

The companion does not patch or redistribute Ultimate Updater source. It consumes only the small upstream interfaces required for target selection, configuration, version/log compatibility checks, and operator-run observation.

Ultimate Updater remains responsible for the behavior and authorization of manual update installation.
