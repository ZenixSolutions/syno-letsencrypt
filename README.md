# syno-letsencrypt

Let's Encrypt certificates — including wildcards — for Synology DSM 7, issued
over the Cloudflare DNS-01 challenge and installed into DSM automatically.
Runs as a container. No inbound ports, nothing exposed to the internet, and
nothing on your NAS runs as root.

> **Status: in development, not yet run end to end.**
> The DSM privilege model was measured on real hardware first — see
> [`docs/findings-dsm-privileges.md`](docs/findings-dsm-privileges.md), which is
> why this is a container rather than the Package Center package originally
> planned ([ADR 0004](docs/adr/0004-container-not-package.md)).

## Why this exists

The usual options are a shell script installed over SSH that you re-run by hand,
or acme.sh with a deploy hook that wants your DSM administrator password and
breaks when you turn on 2FA. Neither is something you would hand to someone else
to run.

This is one compose file. Fill in three values, start it, and DSM has a valid
certificate that renews itself.

## What it does

- **Cloudflare only.** Not a plugin framework with sixty half-maintained DNS
  providers. One provider, done properly.
- **Checks before it commits.** At startup it proves the Cloudflare token can
  list your zone and edit DNS, and that the DSM account can manage certificates
  — then says exactly which one is wrong if not. A certificate tool that only
  reveals its misconfiguration sixty days later is worse than no tool.
- **Installs through DSM's own API.** The same call Control Panel makes when you
  upload a certificate by hand, so DSM updates every subscribing service and
  reloads its web server itself. We never reimplement DSM internals.
- **Touches nothing on the NAS.** No bind mounts, no host capabilities, no root.
- **Renews unattended**, and only re-imports when the certificate actually
  changed, so DSM's web server is not restarted for nothing.

## Install

1. Create the DSM account it will use — see [`docs/dsm-account.md`](docs/dsm-account.md).
2. Create the Cloudflare token (below).
3. **Container Manager → Project → Create**, and paste
   [`docker-compose.yml`](docker-compose.yml) with your values filled in.
4. Leave `STAGING: "true"` for the first run. Check the log, confirm it issued
   and installed a test certificate, then set it to `"false"` and restart.

Staging matters: Let's Encrypt allows only five duplicate certificates per week
in production, and a misconfiguration discovered after burning them means
waiting.

## The Cloudflare token

At [dash.cloudflare.com → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens)
→ **Create Token**, start from the **Edit zone DNS** template, then:

| Scope | Resource | Permission | |
|---|---|---|---|
| Zone | DNS | Edit | included by the template |
| Zone | Zone | Read | **you must add this row yourself** |

Under **Zone Resources**, include your domain.

That second row is the one everybody misses. Cloudflare's own template does not
include `Zone → Read`, and without it the certificate cannot be issued — lego
has to resolve your domain to a zone ID before it can create the challenge
record. The container checks for exactly this at startup and says so plainly
rather than failing later.

## Usage

It renews itself. Everything is also available on demand:

```sh
docker exec syno-letsencrypt syno-letsencrypt status   # expiry, next renewal
docker exec syno-letsencrypt syno-letsencrypt check    # validate config, change nothing
docker exec syno-letsencrypt syno-letsencrypt renew    # renew now if within 30 days
docker exec syno-letsencrypt syno-letsencrypt issue    # force a fresh issuance
```

Logs: Container Manager → Container → `syno-letsencrypt` → Log.

## What it can reach

| | |
|---|---|
| Host mounts | none |
| Host capabilities | none |
| Host PID namespace | not used |
| Runs as root on the NAS | no |
| Outbound | Cloudflare API, Let's Encrypt, DSM's own API |

The one meaningful cost is the DSM administrator account, because DSM offers no
narrower permission for managing certificates. [`docs/dsm-account.md`](docs/dsm-account.md)
covers how to limit it.

## Building

```sh
docker build -t syno-letsencrypt .
```

## Prior art

The DSM certificate-store layout and the `synowebapi` import path were worked out
by a number of people before us, in particular
[catchdave/ssl-certs](https://github.com/catchdave/ssl-certs),
[zaxbux/syno-acme](https://github.com/zaxbux/syno-acme), and
[JessThrysoee/synology-letsencrypt](https://github.com/JessThrysoee/synology-letsencrypt),
which was the starting point for this project. This is an independent
implementation with a different architecture, not a fork of their code.

## Licence

MIT — see [LICENSE](LICENSE).
