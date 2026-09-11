# Safety and compatibility

The notifier exists to provide useful automatic update visibility without inheriting mutating behavior from Ultimate Updater's automatic-check paths.

## Automatic-check boundary

The companion deliberately separates **checking** from **installing**.

Automatic checks:

- invoke `/etc/ultimate-updater/check-updates.sh` only with `UU_JOB_SOURCE=initial-inventory`, `UU_DEFER_NOTIFICATION=true`, and bounded runtime;
- let Ultimate Updater own target selection, package-manager checks, security/normal classification, total counts, and reboot detection;
- consume Ultimate Updater's structured `status.json` and `STATUS_MODEL_RENDER_NOTIFICATION` output;
- never invoke the normal upstream `update -check` path;
- never install package updates;
- never start, stop, resume, suspend, or reboot Proxmox guests.

Actual package installation remains operator-triggered through Ultimate Updater. The `initial-inventory` mode is the accepted upstream read-only lifecycle boundary: stopped or paused selected guests are left unchanged and represented as `Not checked`. The companion treats Ultimate Updater's native `STATE=issues` result as a failed scheduled check rather than silently advancing the success heartbeat.

## Compatibility baseline

The supported safety-critical baseline is intentionally narrow at the upstream-interface level:

- Proxmox VE host running **Ultimate Updater 5.1** with its current `/etc/ultimate-updater` layout;
- `initial-inventory` behavior and the structured status-model interface present in that release;
- target and package-manager support inherited from the accepted Ultimate Updater 5.1 check/status model rather than duplicated by the companion.

Stopped or paused selected guests are not started or resumed. Ultimate Updater represents them as `Not checked`, which the companion surfaces as a failed check. Unreachable, unsupported, errored, or otherwise not-checked selected targets likewise remain visible through Ultimate Updater's native `STATE=issues` rendering.

## Upstream compatibility health

Before every automatic update check, the notifier validates the upstream integration boundary. A completed manual Ultimate Updater run validates the same boundary again after its normal completion notification.

The health check verifies that:

- Ultimate Updater reports exactly version `5.1`;
- `update.sh`, `check-updates.sh`, `status-model.sh`, `target-runtime.sh`, and `tag-filter.sh` expose the accepted interfaces required by the delegated check path;
- `STATUS_MODEL_RENDER_NOTIFICATION` remains callable;
- Ultimate Updater's configured `LOG_FILE` still matches the manual observer path;
- no separate upstream automatic `update -check` or `check-updates.sh` cron entry exists in root's user crontab, `/etc/crontab`, or `/etc/cron.d`;
- the companion check timer and manual path watcher remain enabled and active.

The first successful v0.4 compatibility check records a safety fingerprint across the five safety-critical upstream interface files. Any later source drift fails closed and blocks automatic checks until a new notifier release explicitly accepts the changed upstream boundary. A failed compatibility probe sends a deduplicated ntfy warning; restoration of the accepted boundary sends one recovery notification.

## Cron ownership and restoration

During installation, matching upstream automatic-check entries are removed from:

- root's user crontab;
- `/etc/crontab`;
- files under `/etc/cron.d`.

The exact original matching lines are stored in root-only installer state. Reinstall removes reintroduced matching entries without overwriting the original backup.

Uninstall restores the saved lines to their original cron source when they are not already present. Unrelated cron lines are left alone.

This makes the companion systemd timer the only intended automatic update-check path while the companion is installed.

## Runtime bounds

The delegated Ultimate Updater `initial-inventory` run is bounded to 540 seconds by the companion and the complete systemd automatic-check service remains capped at 10 minutes.

Outbound ntfy and Gatus HTTP calls use:

- 10-second connect timeout;
- 30-second total timeout.

These limits are safety bounds, not expected normal runtimes.

## Upstream relationship

The companion does not patch or redistribute Ultimate Updater source. It consumes Ultimate Updater 5.1's accepted read-only inventory/status interfaces plus the version/log/tag configuration needed for compatibility and operator-run observation.

Ultimate Updater remains responsible for the behavior and authorization of manual update installation.
