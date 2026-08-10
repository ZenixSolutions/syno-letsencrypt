# ADR 0004 — Deliver as a container; install via DSM's Web API

**Status:** Accepted · 2026-08-10
**Supersedes:** ADR 0001 (ship as a DSM package)
**Amends:** ADR 0003 (bootstrap token minting)

## Context

ADR 0001 assumed a package could perform the privileged step of installing a
certificate into DSM. Measurement on DSM 7.3 showed it cannot — see
[findings-dsm-privileges.md](../findings-dsm-privileges.md). A package declaring
root is refused outright; without it, the certificate store is unreadable and
DSM's certificate tooling unrunnable.

Getting the certificate needs no privilege at all. Only the final handoff does.

Three actors on a DSM 7.3 NAS still have privilege: DSM itself, a user-created
root task, and the Docker daemon.

## Decision

Ship a container. It obtains the certificate with lego over Cloudflare DNS-01,
then installs it by calling DSM's `SYNO.Core.Certificate` import API — the same
endpoint Control Panel uses when a certificate is uploaded by hand.

The container mounts nothing from the host, holds no added capabilities, does
not use the host PID namespace, and does not run as root on the NAS.

ADR 0003's bootstrap-token minting is dropped with it: the user supplies a
scoped Cloudflare token directly, and it is validated functionally before use.

## Consequences

- No host filesystem access and no host process access. The container's entire
  reach is three outbound HTTPS destinations.
- DSM performs the archive write, per-service copies and web server reload
  itself, so we never reimplement DSM internals that shift between releases.
- **It needs a DSM administrator account.** DSM has no service accounts and no
  permission narrower than administrator for certificate management. This is the
  real cost of the decision. Mitigations are in
  [dsm-account.md](../dsm-account.md); the honest summary is that the credential
  is powerful and lives in a compose file.
- 2FA must be off for that account, or a device token supplied once.
- Package Center installation and the DSM app icon are lost. Setup is editing a
  compose file rather than answering a wizard.
- The SPK tree remains in the repository, unused, pending a decision on whether
  a thin package could declare the container via the `docker-project` resource
  worker and restore the Package Center experience.

## Alternatives rejected

- **Privileged container with `pid: host` + `nsenter`.** Works, and would allow
  writing files directly plus reloading nginx. But it is a container escape: the
  container gains complete control of the NAS. That is strictly more dangerous
  than the root Task Scheduler task it was meant to avoid, while looking safer.
- **Bind mount without the escape.** The container can write the certificate
  files — verified — but nginx keeps serving the cached certificate until
  reloaded, so the renewal would not take effect until the next reboot.
- **Root Task Scheduler task.** Reliable and credential-free, and still the best
  fallback if the API path disappoints. Rejected as the primary because it
  requires manual setup that cannot be automated away.
