# Changelog

This file records user-visible changes to Proxmox Ultimate Updater Notify.

## Unreleased

## 0.3.2 - 2026-08-23

- Fixed manual-run notifications failing when Ultimate Updater produced logs larger than ntfy's default 4 KiB message limit.
- Manual-run notifications now send compact target/error summaries and all ntfy message bodies are bounded to 3500 bytes.
- Fixed large manual logs intermittently triggering `Broken pipe` under Bash `pipefail` during run-marker detection.
- Added public OpenSSF Scorecard reporting and protected-branch repository controls.
- Release archives now publish signed GitHub/Sigstore provenance alongside `SHA256SUMS`.
- Added explicit contribution and private vulnerability-reporting routes.

## 0.3.1 - 2026-08-18

- Improved ntfy update-notification formatting for mobile-friendly Markdown summaries, security markers and reboot-required callouts.

## 0.3.0 - 2026-08-18

- Added optional Gatus external-endpoint heartbeat support for scheduled-check dead-man monitoring.
- Extended behavior and safety validation around heartbeat delivery and failure handling.

For earlier release details, see the corresponding immutable GitHub Releases.
