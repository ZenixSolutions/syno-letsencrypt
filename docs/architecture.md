# Architecture

```
container (unprivileged, no host access)
   |
   |-- startup: validate Cloudflare token + DSM login, or refuse to start
   |
   |-- lego  --dns cloudflare  ------> Cloudflare API   (create _acme-challenge TXT)
   |                           ------> Let's Encrypt    (DNS-01)
   |
   |-- certificate changed?
   |        yes -> SYNO.Core.Certificate import ------> DSM's Web API
   |                                                       |
   |                                                       v
   |                                            DSM, as root, on its own side:
   |                                              writes _archive/<id>/
   |                                              copies to every subscriber
   |                                              updates INFO / DEFAULT
   |                                              reloads the web server
   |
   `-- sleep 12h, repeat
```

## Why a container and not a package

Measured on DSM 7.3: a package declaring `run-as: root` is refused at install,
install scripts run as the unprivileged package user, the certificate store is
not even readable, and `synowebapi`/`synow3tool` cannot be executed. Full
results in [findings-dsm-privileges.md](findings-dsm-privileges.md); the
reasoning in [ADR 0004](adr/0004-container-not-package.md).

Obtaining a certificate needs no privilege. Only the handoff to DSM does — and
the cleanest way to perform a privileged operation is to ask the process that
already has the privilege.

## Why the Web API and not the filesystem

A container with a bind mount **can** write the certificate store — we confirmed
it, root inside the container, `WRITE: YES`. But nginx loads certificates into
memory at startup, so new files change nothing until it reloads, and the reload
tools live on the host. Reaching them requires `privileged: true` plus
`pid: host` plus `nsenter` into PID 1 — a container escape that grants the
container total control of the NAS. That is more dangerous than the root
scheduled task it was supposed to replace, while appearing safer.

Calling DSM's API instead means the container needs no mounts at all. DSM does
the privileged work on its own side of an authenticated request, exactly as it
does when a certificate is uploaded through Control Panel — including the
per-service copies and the reload, which is the part every filesystem-based tool
has to reimplement and keep in step with DSM releases.

The cost is a DSM administrator account. DSM has no service accounts and no
permission narrower than administrator for certificate management, so this is
unavoidable rather than chosen. [dsm-account.md](dsm-account.md) covers limiting
what it can reach.

## Why our own zone lookup, and pinned resolvers

lego finds a domain's zone apex by issuing SOA queries through the system
resolver. On a network running Pi-hole, AdGuard, split-horizon DNS, or a router
that hijacks port 53, that walk fails — and the error reads like a credentials
problem, which sends people debugging the wrong thing for hours. We pin public
resolvers for the challenge lookup and do our own zone discovery against the
Cloudflare API, which does not care what the local resolver does.

Zone discovery also lists all zones rather than filtering server-side.
`GET /zones?name=<domain>` returns HTTP 403 with error code literally `0` when
the token cannot list zones — indistinguishable from a mistyped domain. Listing
and matching locally lets us tell the two apart.

## Why validation is functional

A DNS-scoped Cloudflare token cannot introspect its own permissions: reading its
own policy set needs `API Tokens Read`, which is User-scoped and absent. So
"does this token work?" can only be answered by trying. At startup we list zones
(proving `Zone:Read`), then create and immediately delete a TXT record at
`_syno-letsencrypt-check.<zone>` (proving `Zone:DNS:Edit`). The name is
deliberately distinct from `_acme-challenge` so it can never collide with a real
challenge in flight.

## Layout

```
src/bin/syno-letsencrypt   check, issue, renew, status
src/lib/log.sh             logging, secret redaction
src/lib/cloudflare.sh      token validation, zone discovery
src/lib/dsm-api.sh         DSM login and certificate import
docker/entrypoint.sh       startup validation, renewal loop
Dockerfile                 alpine + lego, runs as uid 1000
docker-compose.yml         what the user actually edits
spk/                       unused; see below
```

`spk/` and `build/build-spk.sh` are retained but unused. If a thin package can
declare the container through the `docker-project` resource worker, the Package
Center experience becomes possible again with the privileged work still in the
container. That is untested.

## State

Everything persistent lives in the `/data` volume:

| Path | Contents |
|---|---|
| `/data/lego/accounts/` | ACME account key — losing it forces re-registration |
| `/data/lego/certificates/` | issued certificates |
| `/data/state/last-install` | timestamp of the last successful DSM import |

Keep the volume. Discarding it burns Let's Encrypt issuance rate limit for no
reason.
