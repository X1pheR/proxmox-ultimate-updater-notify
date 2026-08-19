# Security Policy

## Supported versions

The latest published release is the supported public baseline unless its release notes state otherwise. Security fixes are developed on `main` and published through the normal immutable release lifecycle.

The notifier has an explicit compatibility boundary with BassT23/Proxmox Ultimate Updater. A newer upstream version is not automatically considered supported merely because it exists; compatibility must pass the repository health checks and documented acceptance boundary.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/X1pheR/proxmox-ultimate-updater-notify/security/advisories/new) for suspected vulnerabilities. Do not include ntfy/Gatus tokens, private hostnames, SSH details, guest data, logs containing environment secrets, or exploit material in public issues.

If private vulnerability reporting is unexpectedly unavailable, open a public issue containing only enough non-sensitive information to request a private follow-up channel.

## Security boundary

Security reports are especially relevant when they involve:

- an automatic check installing packages or changing guest power state;
- bypassing the compatibility health gate or upstream cron takeover safeguards;
- leaking ntfy/Gatus tokens through arguments, logs, notifications, tests, or state files;
- unsafe SSH command construction or loss of the bounded-command timeout;
- unsafe restoration or removal of operator cron/configuration during install, reinstall, or uninstall;
- dependency or workflow vulnerabilities that materially affect the distributed source archive or release process.

The automatic checker deliberately performs metadata refresh and simulated APT upgrade inspection only. Actual package updates remain operator-triggered through Ultimate Updater.

## Repository and release security

The repository uses full-SHA-pinned GitHub Actions, ShellCheck, Bash syntax checks, behavior tests, systemd verification, Dependabot for workflow dependencies and OpenSSF Scorecard. Public-release acceptance additionally reviews applicable GitHub-native secret scanning/push protection, release immutability, exact tag/source identity, checksums and build provenance.

These controls supplement rather than replace review of the compatibility and safety behavior documented in `docs/safety-and-compatibility.md`.
