# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Interactive installer, runnable as a one-liner over SSH.
- Cloudflare token validation that proves permissions functionally before
  anything is written.
- Certificate installation through DSM's own API via `synowebapi`.
- Daily renewal via a systemd timer, which re-imports only when the
  certificate actually changed.

### Changed
- Rearchitected twice. Originally a Package Center `.spk`, then a container,
  now a root install script. The reasoning and the hardware measurements that
  forced each change are in `docs/findings-dsm-privileges.md` and ADRs 0004
  and 0005.

### Notes
- Not yet run end to end on real hardware.
