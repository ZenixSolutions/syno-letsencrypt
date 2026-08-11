# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Interactive installer, runnable as a one-liner over SSH, which downloads its
  own dependencies and validates every answer before writing anything.
- Cloudflare token validation that proves permissions functionally — a scoped
  token cannot introspect itself, so the installer lists zones and creates and
  deletes a test record instead.
- Certificate installation through DSM's own API via `synowebapi`, so DSM
  performs the archive write, per-service copies and web server reload itself.
- Daily renewal as a DSM Task Scheduler entry, visible in Control Panel, which
  re-imports only when the certificate actually changed.
- Service assignment reconciled on every run against `services.json`, with
  current ownership re-read from DSM rather than taken from the stored file.
- `KEY_TYPE` configuration, defaulting to `rsa2048`, validated at load time so
  an unusable value is rejected before an ACME order is placed.
- `PROPAGATION_MODE`, defaulting to `wait`, which avoids a local pre-check that
  fails on any resolver holding a stale negative answer for the challenge name.
- `docs/findings-dsm-cert-import.md`, recording the undocumented behaviour of
  DSM's certificate API — including an error code that does not mean what it
  says.

### Changed

- **The command is now `zenix-cert`.** DSM ships a binary called
  `syno-letsencrypt` which takes precedence on `PATH`, making a tool installed
  under that name unreachable; its `revoke` subcommand also means something
  different and destructive. Installed data paths keep the old name, as they
  are not on `PATH` and moving them would relocate an existing ACME account.
- Renewal moved from a systemd timer to DSM Task Scheduler, so that the answer
  to "what runs on this NAS?" includes it.
- Rearchitected twice before reaching the current design: originally a Package
  Center `.spk`, then a container, now a root install script. The hardware
  measurements that forced each change are in
  `docs/findings-dsm-privileges.md` and [ADR 0002](docs/adr/0002-root-install-script.md).

### Fixed

- `as_default` sent as a JSON boolean was rejected by DSM with error 5511,
  "illegal key file", for a key it had not examined. It must be a quoted
  string.
- A successful Task Scheduler creation was read as a failure because
  `synowebapi`'s progress output on stderr was captured into the JSON body,
  causing the fallback path to create a second, duplicate task.
- `read` with `IFS=$'\t'` collapses runs of tabs, so any record with an empty
  field shifted every subsequent field. This misrendered the certificate picker
  for certificates with no description — which is what DSM's own Let's Encrypt
  client produces.
- Several jq expressions compared a field against the wrong value because `.`
  had been rebound inside a pipe; one of them silently reported "nothing
  missing" in all cases.
- `set -e` terminated the installer when a `[ test ] && command` construct
  evaluated false, which is not an error.

### Known limitations

- Unattended renewal has not yet been observed. Every path has been exercised
  by hand; the scheduled task has not yet fired on its own.
- `system/quickconnect` cannot be assigned to an imported certificate. DSM
  refuses silently; it is excluded from the picker.
- One certificate per NAS.
