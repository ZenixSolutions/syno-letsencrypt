# Architecture

```
sudo syno-letsencrypt renew        (systemd timer, daily)
   |
   |-- lego --dns cloudflare
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
   `-- record the timestamp
```

## Why a root script

The privilege restrictions that shaped the two earlier designs apply to
*packages and containers*, not to root. Measured on DSM 7.3, a package cannot
read the certificate store or execute `synowebapi`, and one declaring root is
refused at install ([findings](findings-dsm-privileges.md)). A container can
write the files through a bind mount but cannot reload nginx without a
container escape.

A script running as root has none of those problems, and gains something the
container design had to pay for: it can call `synowebapi` directly, so it needs
**no DSM credentials at all**. The container had to authenticate over HTTP with
a DSM administrator password, because it wasn't root. This is root — it just
asks.

## Why `synowebapi` and not writing the files

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
exist there**. The layout is undocumented and changed between releases, so DSM
owns it.

The other option — acme.sh's HTTP deploy hook — needs a DSM administrator
password, breaks under 2FA, and its unattended workaround disables 2FA
enforcement DSM-wide while it runs. Running as root, none of that is necessary.

## Why our own zone lookup, and pinned resolvers

lego finds a domain's zone apex by issuing SOA queries through the system
resolver. On a network running Pi-hole, AdGuard, split-horizon DNS, or a router
that hijacks port 53, that walk fails — and the error reads like a credentials
problem, which sends people debugging the wrong thing for hours. The challenge
lookup is pinned to public resolvers, and the installer does its own zone
discovery against the Cloudflare API, which doesn't care what the local resolver
does.

Zone discovery lists all zones rather than filtering server-side.
`GET /zones?name=<domain>` returns HTTP 403 with error code literally `0` when
the token can't list zones — indistinguishable from a mistyped domain. Listing
and matching locally separates the two, so the installer can say which one it is.

## Why validation is functional

A DNS-scoped Cloudflare token cannot introspect its own permissions: reading its
own policy set needs `API Tokens Read`, a User-scoped permission it does not
have. So "does this token work?" can only be answered by trying. The installer
lists zones (proving `Zone:Read`), then creates and immediately deletes a TXT
record at `_syno-letsencrypt-check.<zone>` (proving `Zone:DNS:Edit`). That name
is deliberately distinct from `_acme-challenge` so it can never collide with a
real challenge in flight.

This all happens **before** anything is written to disk. A token that can't do
the job fails during setup, with the specific missing permission named, rather
than at 3am sixty days later.

## Why a systemd timer, not cron

DSM rewrites `/etc/crontab` and is strict about its formatting, so cron entries
there are fragile. DSM 7 is systemd-based; a timer survives reboots cleanly,
`Persistent=true` catches up a run missed while the NAS was powered off, and
`RandomizedDelaySec=6h` avoids every NAS on earth hitting Let's Encrypt in the
same minute.

## Layout

```
install.sh                 interactive installer; also the curl one-liner target
uninstall.sh               removal, with --purge
src/bin/syno-letsencrypt   check, issue, renew, status
src/lib/log.sh             logging, secret redaction
src/lib/cloudflare.sh      token validation, zone discovery
src/lib/dsm.sh             certificate import via synowebapi
```

Installed to:

| Path | Mode | Contents |
|---|---|---|
| `/usr/local/bin/syno-letsencrypt` | 0755 | the CLI |
| `/usr/local/bin/lego` | 0755 | ACME client |
| `/usr/local/share/syno-letsencrypt/lib/` | 0644 | libraries |
| `/usr/local/etc/syno-letsencrypt/` | 0700 | config and lego data |
| `/usr/local/etc/syno-letsencrypt/config` | 0600 | includes the Cloudflare token |
| `/etc/systemd/system/syno-letsencrypt.{service,timer}` | 0644 | schedule |

The ACME account key lives in `/usr/local/etc/syno-letsencrypt/lego/accounts/`.
Losing it forces re-registration with Let's Encrypt, so `uninstall.sh` keeps it
unless `--purge` is given.
