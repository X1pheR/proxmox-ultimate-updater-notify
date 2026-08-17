# Proxmox Ultimate Updater Notify

`proxmox-ultimate-updater-notify` is a community-maintained notification companion for [BassT23/Proxmox Ultimate Updater](https://github.com/BassT23/Proxmox). It adds scheduled, deduplicated ntfy update checks and notifications for completed operator-triggered Ultimate Updater runs without adding unattended package upgrades.

This project is not affiliated with, endorsed by, or maintained by the Ultimate Updater project.

## Design boundary

The notifier deliberately separates **checking** from **installing**:

- Automatic checks run at 07:00 and 19:00 through a systemd timer.
- Automatic checks refresh APT package metadata and simulate upgrades only. They never install packages.
- Automatic checks never start, stop, resume, suspend, or reboot Proxmox guests.
- Actual Ultimate Updater package installation remains operator-triggered through the upstream `update` command.
- Manual run completion is observed from the upstream log through a systemd path unit; the upstream source is not patched.
- The upstream `check-updates.sh` is intentionally not called. Some non-APT upstream check paths execute package upgrades or change guest power state, which conflicts with this project's no-unattended-upgrades boundary.

## Notifications

The notifier sends ntfy messages when:

- updates first become available;
- the available update set changes;
- a previously reported update state clears;
- an automatic check fails or a failure changes;
- an automatic check recovers;
- an actual manual Ultimate Updater run succeeds;
- an actual manual run fails;
- Ultimate Updater prints `Finished, with errors.` even though its process exit status is zero.

Unchanged automatic states are deduplicated. Multiple filesystem events from the same completed manual run are suppressed for a short window, while later identical manual runs still notify independently.

## Compatibility

The initial compatibility baseline is intentionally narrow:

- Proxmox VE host running Ultimate Updater 5.0 with its current `/etc/ultimate-updater` layout;
- Debian-family APT targets (`debian`, `ubuntu`, `devuan` for LXC; APT-detected Linux VMs);
- running guests only for automatic checks;
- SSH-managed VMs or QEMU Guest Agent managed VMs.

For non-root SSH VM targets, the SSH user must be able to run the metadata refresh non-interactively:

```text
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update
```

The notifier fails closed for unsupported package-manager families, unavailable target access, stopped/paused guests selected for checking, or a non-root metadata refresh that would require an interactive sudo password.

## Requirements

- Proxmox VE host with Ultimate Updater installed under `/etc/ultimate-updater`;
- Bash;
- `curl`, `sha256sum`, `python3`, `pct`, and `qm`;
- an ntfy topic and access token;
- for SSH VMs, working key-based SSH and the non-interactive APT metadata-refresh permission described above.

## Install

Clone the repository on the Proxmox host and run:

```bash
sudo bash install.sh
```

The installer:

1. installs the notifier under `/usr/local/libexec/`;
2. installs the systemd service, timer, and path units;
3. creates `/etc/proxmox-ultimate-updater-notify/config` only if it does not already exist;
4. preserves operator configuration on reinstall;
5. removes matching Ultimate Updater check entries from root's crontab while preserving their exact original lines for uninstall;
6. enables the 07:00/19:00 timer and manual-log path watcher.

The installer does not create or guess an ntfy token.

## Configure ntfy

Edit:

```text
/etc/proxmox-ultimate-updater-notify/config
```

Example:

```bash
NTFY_URL="https://ntfy.example.com/ultimate-updater"
NTFY_TOKEN_FILE="/etc/proxmox-ultimate-updater-notify/ntfy-token"
NTFY_TITLE_PREFIX="Ultimate Updater"
```

Create the token file as a root-readable secret, for example:

```bash
sudo install -d -m 0750 /etc/proxmox-ultimate-updater-notify
sudo install -m 0600 /dev/null /etc/proxmox-ultimate-updater-notify/ntfy-token
sudoedit /etc/proxmox-ultimate-updater-notify/ntfy-token
```

The notifier publishes directly to ntfy over HTTP(S) and authenticates with native ntfy access-token authentication (`Authorization: Bearer <token>`). Apprise is not required at runtime; its ntfy token mode uses the same upstream authentication model. The bearer token is supplied to curl through standard input as a header file, so it is not placed in curl's process arguments.

Use an `https://` ntfy topic URL whenever the publisher crosses an untrusted network boundary. The token file should contain only the ntfy access token and remain readable only by the privileged service account.

## Verify

Run a check without installing packages:

```bash
sudo /usr/local/libexec/proxmox-ultimate-updater-notify check
```

Inspect the timer and path watcher:

```bash
systemctl status proxmox-ultimate-updater-notify-check.timer
systemctl status proxmox-ultimate-updater-notify-manual.path
systemctl list-timers proxmox-ultimate-updater-notify-check.timer
```

Continue to run Ultimate Updater manually as usual when you decide to install updates.

## Uninstall

```bash
sudo bash install.sh uninstall
```

Uninstall disables and removes the notifier units and executable, restores the exact saved Ultimate Updater root-crontab check lines when they are not already present, and deliberately preserves `/etc/proxmox-ultimate-updater-notify` so operator configuration and the ntfy token are not destroyed.

## Development

Run the behavior suite with:

```bash
bash tests/run.sh
```

CI also runs Bash syntax checks, ShellCheck, the behavior suite, and systemd unit verification.

## Security

- No production or Homelab credentials belong in this repository.
- Keep the ntfy token in the configured token file, not in Git or environment examples.
- Automatic checking supports only code paths that do not install package upgrades.
- Unsupported or unsafe target conditions fail rather than falling back to an upstream mutating check path.
- The upstream Ultimate Updater remains responsible for its own package-installation behavior and authorization.

Security-sensitive issues can be reported through GitHub's standard repository issue mechanism without including credentials, tokens, private hostnames, or other sensitive environment details.

## License and upstream relationship

This notifier is independently maintained and licensed under the MIT License. It does not redistribute or modify the Ultimate Updater source. Ultimate Updater is a separate upstream project with its own GNU GPL licensing and governance; consult the upstream repository for those terms.
