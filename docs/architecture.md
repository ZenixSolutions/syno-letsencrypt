# Architecture

```
zenix-cert renew                   (DSM Task Scheduler, daily, as root)
   |
   |-- lego --dns cloudflare --key-type rsa2048
   |        |
   |        |--> Cloudflare API      create _acme-challenge TXT, then remove it
   |        `--> Let's Encrypt       DNS-01 validation, issue certificate
   |
   |-- certificate actually changed?
   |        no  -> stop. DSM is not touched, nothing restarts.
   |        yes -> synowebapi --exec-fastwebapi
   |                    api=SYNO.Core.Certificate method=import
   |                        |
   |                        v
   |               DSM, in-process as root:
   |                 writes _archive/<id>/
   |                 copies to every subscribing service
   |                 updates INFO / DEFAULT
   |                 reloads the web server
   |
   |-- reconcile service assignment against services.json
   |        reads current ownership from DSM, moves only what has moved
   |
   `-- record the timestamp
```

## Why a root script

The privilege restrictions that shaped two earlier designs apply to *packages
and containers*, not to root. Measured on DSM 7.3, a package cannot read the
certificate store or execute `synowebapi`, and one declaring root is refused at
install ([findings](findings-dsm-privileges.md)). A container can write the
files through a bind mount but cannot reload nginx without a container escape.

A script running as root has neither problem, and gains something the container
design had to pay for: it calls `synowebapi` directly, so it needs **no DSM
credentials at all**. The container had to authenticate over HTTP with a DSM
administrator password precisely because it was not root.

Recorded in [ADR 0002](adr/0002-root-install-script.md).

## Why `synowebapi` rather than writing the files

`synowebapi --exec-fastwebapi` invokes DSM's Web API in-process. It is the same
code path Control Panel uses when a certificate is uploaded by hand, so DSM
performs the archive write, the per-service copies, the `INFO`/`DEFAULT`
bookkeeping and the web server reload itself.

Writing the PEM files directly is the traditional approach and it has quietly
broken. On DSM 7.3, `system/default` contains:

```
ECC-cert.pem  ECC-fullchain.pem  ECC-privkey.pem
RSA-cert.pem  RSA-fullchain.pem  RSA-privkey.pem
```

DSM installs an elliptic-curve and an RSA certificate side by side and serves
whichever the client negotiates. The `cert.pem` / `privkey.pem` /
`fullchain.pem` filenames that every filesystem-based tool writes **no longer
exist there**. The layout is undocumented and has changed between releases, so
DSM owns it.

The remaining alternative — acme.sh's HTTP deploy hook — requires a DSM
administrator password, breaks under 2FA, and its unattended workaround
disables 2FA enforcement DSM-wide while it runs.

The import API has several undocumented behaviours that are easy to
misdiagnose, including an error code that does not mean what it says. These are
measured and recorded in
[findings-dsm-cert-import.md](findings-dsm-cert-import.md); that document is
worth reading before changing anything in `src/lib/dsm.sh`.

## Why RSA keys

`KEY_TYPE` defaults to `rsa2048` rather than lego's `ec256`. Both import into
DSM successfully — this was verified after an EC key was wrongly suspected of
causing an import failure — and RSA is chosen for maximum client compatibility
rather than out of necessity. The setting is configurable, and validated at
config load so an unusable value is rejected before an ACME order is placed
rather than after.

## Why the challenge record is not checked locally

lego can confirm a challenge record itself before asking Let's Encrypt to
validate. `PROPAGATION_MODE` defaults to `wait`, which skips that check: lego
creates the record, sleeps, and hands over. The certificate is still fully
validated by the CA; only lego's own local pre-check is skipped.

The reason is a measured failure. On the development NAS, lego created the
record and queried it two seconds later, before Cloudflare was serving it. The
resulting `NXDOMAIN` was cached for the zone's SOA `minimum` of 1800 seconds,
so every subsequent poll returned the same stale negative — while the record
was live and visible to the rest of the internet, including Let's Encrypt.

Not querying at all avoids creating that cached negative. Let's Encrypt asks
for the name for the first time, from resolvers with no reason to hold anything
stale about it.

`check` mode remains available. It is cheaper on genuine failure, since a
record that never appears costs a local timeout rather than one of Let's
Encrypt's five failed validations per hostname per hour.

## Why our own zone lookup, and pinned resolvers

lego finds a domain's zone apex by issuing SOA queries through the system
resolver. On a network running Pi-hole, AdGuard, split-horizon DNS, or a router
that hijacks port 53, that walk fails — and the error reads like a credentials
problem, which sends people debugging the wrong thing. The challenge lookup is
pinned to public resolvers, and the installer performs its own zone discovery
against the Cloudflare API, which does not depend on the local resolver.

Zone discovery lists all zones rather than filtering server-side.
`GET /zones?name=<domain>` returns HTTP 403 with error code literally `0` when
the token cannot list zones — indistinguishable from a mistyped domain. Listing
and matching locally separates the two, so the installer can report which it is.

## Why validation is functional

A DNS-scoped Cloudflare token cannot introspect its own permissions: reading
its own policy set requires `API Tokens Read`, a User-scoped permission it does
not have. So "does this token work?" can only be answered by trying. The
installer lists zones, proving `Zone:Read`, then creates and immediately
deletes a TXT record at `_zenix-cert-check.<zone>`, proving `Zone:DNS:Edit`.
That name is deliberately distinct from `_acme-challenge` so it can never
collide with a real challenge in flight.

This happens **before** anything is written to disk. A token that cannot do the
job fails during setup, with the missing permission named, rather than at 3am
sixty days later.

## Service assignment

Replacing a certificate in place preserves whatever it already served. That is
not the same as serving what the user asked for, so assignment is reconciled on
every run against the selection stored in `services.json`.

Only the *selection* comes from that file. Each entry also records the
certificate that owned the service at install time, and that value goes stale
as soon as anything is reassigned — including by a previous run of this tool.
Handing DSM a stale owner is not a harmless no-op: it has been observed to
clear a service's assignment rather than move it. Current ownership is
therefore re-read from DSM on every run.

`system/quickconnect` is excluded from assignment entirely. It is served by the
Synology-issued certificate for `<name>.direct.quickconnect.to`, a name no
public CA will issue to anyone else. DSM refuses to reassign it and reports
success while doing nothing, so offering it as a choice would produce an
unexplained discrepancy.

## Layout

```
install.sh                 interactive installer; also the curl one-liner target
uninstall.sh               removal, with --purge
src/bin/zenix-cert         check, issue, renew, status
src/lib/log.sh             logging, secret redaction
src/lib/cloudflare.sh      token validation, zone discovery
src/lib/dsm.sh             certificate import and service assignment
src/lib/schedule.sh        the DSM Task Scheduler entry
src/lib/dns.sh             DNS-over-HTTPS helpers, for check and diagnostics
src/lib/ui.sh              terminal progress rendering
tools/                     standalone diagnostics; see tools/README.md
```

The command is `zenix-cert` rather than `syno-letsencrypt` because DSM ships a
binary by the latter name which takes precedence on `PATH`, and whose `revoke`
subcommand means something different and destructive.

Installed to:

| Path | Mode | Contents |
|---|---|---|
| `/usr/local/bin/zenix-cert` | 0755 | the command |
| `/usr/local/bin/lego` | 0755 | ACME client |
| `/usr/local/share/syno-letsencrypt/lib/` | 0644 | libraries |
| `/usr/local/etc/syno-letsencrypt/` | 0700 | config and lego data |
| `/usr/local/etc/syno-letsencrypt/config` | 0600 | includes the Cloudflare token |
| `/usr/local/etc/syno-letsencrypt/services.json` | 0600 | which services to assign |

The installed paths retain the `syno-letsencrypt` name. They are not on `PATH`,
they collide with nothing, and renaming them would relocate an existing ACME
account and its issued certificates for no benefit.

The ACME account key lives in `/usr/local/etc/syno-letsencrypt/lego/accounts/`.
Losing it forces re-registration with Let's Encrypt, so `uninstall.sh` keeps it
unless `--purge` is given.
