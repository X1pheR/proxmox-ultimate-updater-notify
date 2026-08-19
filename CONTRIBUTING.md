# Contributing

This repository maintains a notification and safety companion around BassT23/Proxmox Ultimate Updater. Keep changes focused on that companion boundary rather than copying or modifying upstream source.

## Before proposing a change

- Preserve the automatic-check safety boundary: metadata refresh and simulated APT inspection only; no unattended package installation and no guest power-state mutation.
- Preserve the explicit compatibility health gate for the supported Ultimate Updater integration boundary.
- Keep ntfy, Gatus, SSH and environment-specific credentials out of source, tests, examples and issue content.
- Do not add fallback behavior that invokes an unsupported upstream check path when compatibility validation fails.
- Treat changes to cron takeover/restoration, manual-run observation, SSH execution or systemd scheduling as safety-sensitive.

## Validation

Run the repository behavior suite:

```bash
bash tests/run.sh
```

Before a pull request is accepted, CI also requires:

- Bash syntax checks for the installer, notifier and tests;
- ShellCheck for maintained shell sources;
- the full behavior suite;
- `systemd-analyze verify` for the shipped service, timer and path units.

Release and workflow changes must keep external GitHub Actions pinned to full commit SHAs.

## Pull requests

Keep each pull request focused on one behavior, compatibility, release or documentation concern. Describe the safety boundary affected by the change and include tests for new or changed behavior where practical.

Security-sensitive reports must follow `SECURITY.md` rather than a public issue or pull request.
