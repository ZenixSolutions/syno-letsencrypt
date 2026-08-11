# ADR 0002 — A root install script, run over SSH

**Status:** Accepted · 2026-08-10

## Context

Two earlier designs were built and rejected. Both failed for the same
underlying reason, reached from different directions.

A **DSM package** cannot perform the privileged step at all. Measured on
DSM 7.3-86009: a package declaring `run-as: root` is refused at install, and
without it the package user cannot read the certificate store or execute
`synowebapi`. Full results in [findings-dsm-privileges.md](../findings-dsm-privileges.md).

A **container** works, but only by asking DSM to perform the privileged part on
its behalf, which requires a DSM administrator account and its password in a
compose file. That is a genuine security cost, and the setup — create a service
account, edit YAML, understand bind mounts — is heavier than the problem
warrants.

The constraint that defeated both applies to packages and containers, not to
root. A script run as root over SSH has none of these problems: it calls
`synowebapi` directly, and therefore needs no DSM credentials at all.

## Decision

A single interactive installer, fetched and run over SSH:

```sh
curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh | sudo bash
```

It downloads its own dependencies, collects the Cloudflare token and domains,
validates the token against Cloudflare before writing anything, installs to
`/usr/local`, and schedules renewal as a DSM Task Scheduler entry.

## Consequences

- **No DSM credentials anywhere.** Running as root, `synowebapi
  --exec-fastwebapi` invokes DSM's certificate API in-process. The Cloudflare
  API token is the only secret stored on the NAS, at mode `0600`.
- **DSM continues to own the certificate layout** — the archive write, the
  copies to each subscribing service, and the web server reload. This matters
  more than it once did: DSM 7.3 serves dual ECC and RSA certificates, so the
  `cert.pem` filenames that filesystem-based tools write no longer exist.
- **One command to install.** No Package Center, no Container Manager, no YAML.
- **Constraints from being piped out of curl.** Standard input is the script
  itself, so every prompt must read from `/dev/tty` explicitly, and the
  installer fetches its own libraries rather than assuming a checkout.
- **The repository must be public** for the one-liner to resolve. Users who
  prefer to review first clone the repository and run `./install.sh`.
- **It is `curl | sudo bash`**, which asks for real trust. Mitigations: the
  script is short and readable, it is fetched over HTTPS, it states what it
  will do before doing it, and running from a clone is always available.
- **No DSM user interface.** Status is available through `zenix-cert status`
  over SSH, and the renewal task itself is visible in Control Panel.

## Renewal: Task Scheduler, not cron or a systemd timer

Cron is unusable: DSM rewrites `/etc/crontab` and is strict about its
formatting, so entries added there stop existing after an update.

A systemd timer was the first implementation and was replaced. It works, but it
is invisible — nothing in DSM's interface shows it, so the answer to "what runs
on this NAS?" would not include the thing renewing its certificate. It is also
vulnerable to DSM major upgrades, which have been observed removing units from
`/etc/systemd/system`.

Task Scheduler is where a Synology administrator looks. The entry shows its
last run time and exit status, and can be disabled or run on demand by someone
who has never heard of this tool.

The trade-offs are real. Task Scheduler has no equivalent of systemd's
`RandomizedDelaySec`, so the hour is randomised between 01:00 and 05:00 at
install time instead; and no equivalent of `Persistent=true`, so a run missed
while the NAS was powered off is skipped rather than caught up. With a 30-day
renewal window and a daily check, neither is material.

`synoschedtask` provides `--get`, `--del`, `--run` and `--sync`, but no
`--add`, so the task is created through `synowebapi` — the same mechanism as
the certificate import. Verified on DSM 7.3:
`SYNO.Core.TaskScheduler.Root method=create version=4` succeeds from a local
root shell without a password-confirmation token.
