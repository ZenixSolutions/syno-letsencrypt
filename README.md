# syno-letsencrypt

```
=====================                                                                               
===================   **    *************  ************#    ***        ***    ***#   #***       #**#
====      =======   ****   #*************  *************    *****     ****#   ****   #*****    *****
====    =======   ******    #***********   *****#######*    ******    ****#   ****     ***** #****# 
====  =======   *******          #****     *****            ********  ****#   ****      *********   
==   ======   *******           *****      *************    ****#**** ****#   ****        ******    
   ======   *******   **       ****        *************    ****  ********#   ****       ********   
 ======   *******   ****     *****         *****            ****    ******#   ****     ***********  
=====   *******    *****    *************  *************    ****     *****#   ****    *****   ***** 
===   *******      *****   **************  *************    ****      ****    ****   ****#      ****
=   ********************                                                                            
  **********************                                                                            
```

**Let's Encrypt certificates for Synology DSM — wildcards included — over the
Cloudflare DNS-01 challenge, installed straight into DSM and renewed
automatically.**

No inbound ports need to be opened, and no DSM credentials are stored.

> **Status: in development.** The DSM interfaces this depends on have been
> verified on hardware running DSM 7.3, but a production certificate has not yet
> been issued end to end. The installer defaults to the Let's Encrypt staging
> environment; begin there.

---

## Install

### Quick install

SSH into the NAS and run:

```sh
curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh | sudo bash
```

The installer checks that the system is supported, downloads its dependencies,
collects the settings it needs, validates them against Cloudflare before writing
anything, and schedules automatic renewal. Each step is described below.

### Manual install

To review the source before executing it, or to install from a local copy:

```sh
git clone https://github.com/ZenixSolutions/syno-letsencrypt.git
cd syno-letsencrypt
sudo ./install.sh
```

Both methods run the same script and produce the same result.

Re-running the installer at any time is safe. Previous answers are offered as
defaults, and an existing certificate is left in place.

---

## What the installer asks

**1. Cloudflare API token.** See [below](#the-cloudflare-token); one permission
is easily missed. The token is validated against Cloudflare before anything is
written to disk.

**2. Domains and contact email.** Comma separated. A wildcard does not cover the
apex domain, so both are normally required:

```
example.com,*.example.com
```

**3. Staging or production.** Staging issues an untrusted test certificate and
is not rate limited. Production permits only **five duplicate certificates per
week**, so a misconfiguration discovered afterwards can mean waiting several
days. Staging is the default.

**4. Replace an existing DSM certificate, or create a new one.** The installer
lists the certificates already present and how many services each one serves.
This choice has consequences — see [below](#replace-or-create-new).

**5. Which services should use it.** DSM Desktop, FTPS, VPN Server, Synology
Drive, KMIP, and any other installed service. When replacing a certificate, the
services it already serves are pre-selected.

The installer then writes its configuration, creates the scheduled task, and
offers to issue the certificate immediately.

### Dependencies

Two programs are downloaded during installation:

- **[lego](https://go-acme.github.io/lego/)** — an open-source ACME client, the
  protocol Let's Encrypt uses to issue certificates. It handles the exchange
  with Let's Encrypt and creates the Cloudflare DNS records that prove domain
  ownership. It serves the same purpose as Certbot, but ships as a single
  static binary with built-in Cloudflare support, which suits a NAS.
- **jq** — a JSON processor, used to read DSM's API responses. Installed only
  if DSM does not already provide it.

Both are official release binaries, installed to `/usr/local/bin`.

---

## The Cloudflare token

At [dash.cloudflare.com → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens)
→ **Create Token**, start from the **Edit zone DNS** template, then:

| Scope | Resource | Level | |
|---|---|---|---|
| Zone | DNS | Edit | included by the template |
| Zone | **Zone** | **Read** | **must be added manually** |

Under **Zone Resources**, include the domain the certificate is for.

The second row sets both the scope *and* the resource to `Zone`. That looks like
a duplication in Cloudflare's interface, but it is correct: it is the permission
that allows the token to list zones, which is how a domain name is resolved to
the zone ID required before any DNS record can be created.

It is **not** `Zone → DNS → Read`. That grants reading DNS records only, which
the `Edit` level in the first row already includes, and it does not permit zone
lookup — so a token built that way fails during setup.

The installer verifies the token by exercising it rather than by querying its
permissions, because a scoped Cloudflare token cannot introspect itself. It
lists the account's zones, then creates and immediately deletes a TXT record at
`_syno-letsencrypt-check.<zone>`. If either operation fails, the missing
permission is reported during setup rather than at the first renewal.

The token is stored at `/usr/local/etc/syno-letsencrypt/config`, mode `0600`,
readable only by root.

---

## Replace or create new?

**Replacing an existing certificate is the default and is recommended.**

When DSM replaces a certificate in place, every service already assigned to it
continues to use it. No further action is required.

Creating a new certificate behaves differently, and the difference is easy to
overlook. Marking a new certificate as the default moves only the **System
default** service. Every other service — FTPS, VPN Server, Synology Drive, KMIP,
Replication Service — remains assigned to the previous certificate. Control
Panel will show the new certificate as the default while those services continue
to serve the old one.

When "new" is selected, the installer therefore asks which services should be
moved and reassigns them explicitly. Each service definition is passed back to
DSM exactly as DSM reported it, since the internal identifiers vary by service
and by DSM release.

Renewals always replace in place, regardless of the choice made at install.

---

## Usage

Renewal is automatic. Everything is also available on demand:

```sh
sudo syno-letsencrypt status    # expiry, services, next scheduled run
sudo syno-letsencrypt check     # re-validate the token and DSM access
sudo syno-letsencrypt renew     # what the scheduled task runs
sudo syno-letsencrypt issue     # force a fresh issuance
```

Configuration is stored as plain shell at
`/usr/local/etc/syno-letsencrypt/config`. It can be edited directly, followed by
`syno-letsencrypt check` to revalidate.

---

## Renewal

The installer creates a **DSM Task Scheduler** entry named
*"Let's Encrypt renewal (syno-letsencrypt)"*, running as root, daily, at a
randomised hour between 01:00 and 05:00.

It appears in **Control Panel → Task Scheduler** alongside any other scheduled
task, where its last run time and exit status are visible and it can be
disabled or run on demand.

A renewal only re-imports into DSM when the certificate actually changed, so
DSM's web server is not restarted daily for nothing.

---

## How it works

1. `lego` proves domain ownership by creating an `_acme-challenge` TXT record in
   Cloudflare and removing it once validation completes. No inbound port is
   opened at any point.
2. The certificate is passed to DSM through `synowebapi`, the same interface
   Control Panel uses when a certificate is uploaded manually. DSM writes its
   own certificate store, copies the certificate to every subscribing service,
   and reloads its web server.
3. The scheduled task checks daily and renews within 30 days of expiry.

Because it runs as root, **no DSM username or password is required.** The only
credential stored on the NAS is the Cloudflare API token.

DSM 7.3 serves dual ECC and RSA certificates — `system/default` contains
`ECC-cert.pem` and `RSA-cert.pem`, and the `cert.pem` filename every
filesystem-based tool writes no longer exists. Letting DSM own that layout,
rather than writing the files ourselves, is what keeps this working across DSM
releases.

---

## What gets installed

| Path | Contents |
|---|---|
| `/usr/local/bin/syno-letsencrypt` | the command |
| `/usr/local/bin/lego` | ACME client |
| `/usr/local/bin/jq` | only if DSM does not already ship it |
| `/usr/local/share/syno-letsencrypt/lib/` | libraries |
| `/usr/local/etc/syno-letsencrypt/config` | settings and the Cloudflare token (`0600`) |
| `/usr/local/etc/syno-letsencrypt/services.json` | which services to assign |
| `/usr/local/etc/syno-letsencrypt/lego/` | ACME account key and certificates (`0700`) |
| Control Panel → Task Scheduler | the daily renewal task |

---

## Troubleshooting

**"The token could not list zones"** — the token is missing `Zone → Zone →
Read`, which Cloudflare's "Edit zone DNS" template does not include.

**"No zone in this Cloudflare account matches ..."** — the installer lists every
zone the token can see. This is usually a typo in the domain, or Zone Resources
on the token not including it.

**"Cloudflare is rate-limiting this token"** — repeated authentication failures
trigger a temporary lockout. The token itself is usually valid; wait a few
minutes before retrying.

**`lego` reports "could not find zone"** — lego resolves the zone apex through
the system resolver, which fails on networks running Pi-hole, AdGuard,
split-horizon DNS, or a router that hijacks port 53. The installer pins public
resolvers for the challenge lookup to avoid this. Adjust `DNS_RESOLVERS` in the
configuration file if a different resolver is required.

**A service is still using the old certificate** — see
[Replace or create new?](#replace-or-create-new). Reassign it in Control Panel →
Security → Certificate → Settings, or re-run the installer and choose replace.

**After a major DSM upgrade** — re-run the installer. It is idempotent, and DSM
upgrades have been known to remove files from `/usr/local`.

---

## Uninstall

```sh
sudo ./uninstall.sh            # keep the certificate, config and ACME account
sudo ./uninstall.sh --purge    # remove them too
```

The certificate already installed in DSM is left in place in both cases, so
removing this tool does not revert the NAS to a self-signed certificate.

The Cloudflare API token should be deleted separately at
[dash.cloudflare.com](https://dash.cloudflare.com/profile/api-tokens).

---

## Requirements

- Synology DSM 7.0 or later (developed against 7.3)
- A domain hosted on Cloudflare
- SSH access with an account that can `sudo`

---

## Licence

MIT — see [LICENSE](LICENSE).
