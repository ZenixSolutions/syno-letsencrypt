# ADR 0005 — A root install script, run over SSH

**Status:** Accepted · 2026-08-10
**Supersedes:** ADR 0001 (SPK), ADR 0004 (container)

## Context

Two architectures were tried and both were rejected for the same underlying
reason, approached from different directions.

The **package** could not perform the privileged step at all — DSM 7.3 refuses a
package that declares root, and without it the certificate store is unreadable
and DSM's certificate tooling unrunnable
([findings](../findings-dsm-privileges.md)).

The **container** worked, but only by asking DSM to do the privileged part on
its behalf, which required a DSM administrator account and its password in a
compose file. That is a real cost, and the setup — create a service account,
edit YAML, understand bind mounts — was heavier than the problem deserves.

The constraint that drove both designs applies to *packages and containers*, not
to root. A script run over SSH as root has none of these problems: it can call
`synowebapi` directly, so it needs no credentials at all.

## Decision

A single interactive installer, fetched and run over SSH:

```sh
curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh | sudo bash
```

It downloads its own dependencies, asks for the Cloudflare token and domains,
validates the token before writing anything, installs to `/usr/local`, and
schedules renewal with a systemd timer.

## Consequences

- **No DSM credentials anywhere.** Running as root, `synowebapi
  --exec-fastwebapi` invokes DSM's certificate API in-process. Nothing is
  stored but the Cloudflare token, at `0600`.
- **DSM still owns the certificate layout** — the archive write, the copies to
  each subscribing service, and the web server reload. That matters more than it
  used to: DSM 7.3 serves dual ECC and RSA certificates, so the `cert.pem`
  filenames every filesystem-based tool writes no longer exist.
- **One command to install.** No Package Center, no Container Manager, no YAML.
- **Piped-from-curl constraints.** stdin is the script, so every prompt reads
  from `/dev/tty` explicitly. The installer also has to fetch its own libraries
  rather than assume a checkout.
- **The repository must be public** for the one-liner to resolve, or users clone
  first and run `./install.sh`.
- **It is `curl | sudo bash`**, which asks for real trust. Mitigations: the
  script is short and readable, it is fetched over HTTPS from a pinned ref, it
  says exactly what it will do before doing it, and `./install.sh` from a clone
  is always available for anyone who would rather read it first.
- **No DSM UI.** Status lives behind `syno-letsencrypt status` over SSH.
- **DSM major upgrades may remove `/etc/systemd/system` units.** Re-running the
  installer restores them; it is idempotent by design.
