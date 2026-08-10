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

No inbound ports. No DSM password stored anywhere. One command.

> **Status: in development.** The DSM APIs it depends on have been verified on
> real hardware (DSM 7.3), but it has not yet issued a production certificate
> end to end. Start with staging — the installer defaults to it.

---

## Install

SSH into your NAS and run:

```sh
curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh | sudo bash
```

Prefer to read it before running it as root? That's the better instinct:

```sh
git clone https://github.com/ZenixSolutions/syno-letsencrypt.git
cd syno-letsencrypt
less install.sh
sudo ./install.sh
```

Re-running the installer is safe. Previous answers become the defaults, and an
existing certificate is left alone.

---

## What the installer asks

**1. Your Cloudflare API token.** See [below](#the-cloudflare-token) — there is
one non-obvious step. The token is checked against Cloudflare *before* anything
is written to disk.

**2. Domains and email.** Comma separated. A wildcard does not cover the apex,
so list both:

```
example.com,*.example.com
```

**3. Staging or production.** Staging issues an untrusted test certificate with
no rate limits. Production allows only **five duplicate certificates per week**,
so a mistake found after burning them means waiting. The default is staging.

**4. Replace an existing DSM certificate, or create a new one.** It lists what
your NAS currently has and how many services each certificate serves. This
choice matters more than it looks — see [below](#replace-or-create-new).

**5. Which services should use it.** DSM Desktop, FTPS, VPN Server, Synology
Drive, KMIP, and anything else installed. When replacing, whatever the old
certificate already served is pre-selected, so pressing Enter changes nothing.

Then it installs `lego`, writes its configuration, creates the scheduled task,
and offers to issue the certificate immediately.

---

## The Cloudflare token

At [dash.cloudflare.com → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens)
→ **Create Token**, start from the **Edit zone DNS** template, then:

| Scope | Resource | Permission | |
|---|---|---|---|
| Zone | DNS | Edit | included by the template |
| Zone | Zone | **Read** | **you must add this row yourself** |

Under **Zone Resources**, include your domain.

That second row is the one nearly everyone misses. Cloudflare's own template
doesn't include `Zone → Read`, and without it the certificate cannot be
issued — your domain has to be resolved to a zone ID before the challenge
record can be created.

The installer verifies this by *doing* it, not by asking Cloudflare what the
token can do — a scoped token cannot introspect its own permissions. It lists
your zones, then creates and immediately deletes a TXT record at
`_syno-letsencrypt-check.<zone>`. If either fails you are told exactly which
permission is missing, during setup rather than sixty days later.

The token is stored at `/usr/local/etc/syno-letsencrypt/config`, mode `0600`,
readable only by root.

---

## Replace or create new?

**Replace is the default, and it is usually right.**

When DSM replaces a certificate in place, every service already pointing at it
keeps working. Nothing else has to happen.

Creating a *new* certificate is different, and the difference is easy to miss:
**`as_default` only moves the System default.** Every other service — FTPS, VPN
Server, Synology Drive, KMIP, Replication Service — stays on the old
certificate. Control Panel will show your shiny new certificate looking
correct while half your services quietly serve the old one.

So when you choose "new", the installer asks which services should move and
reassigns them explicitly. Each service is handed back to DSM exactly as DSM
described it; the internal labels differ per service and per DSM release, and
inventing them is what produces the `5503` errors people hit with this API.

Renewals always replace in place, whichever you chose at install.

---

## Usage

Renewal is automatic. Everything is also available on demand:

```sh
sudo syno-letsencrypt status    # expiry, services, next scheduled run
sudo syno-letsencrypt check     # re-validate the token and DSM access
sudo syno-letsencrypt renew     # what the scheduled task runs
sudo syno-letsencrypt issue     # force a fresh issuance
```

Configuration is plain shell at `/usr/local/etc/syno-letsencrypt/config` — edit
it directly and re-run `check`.

---

## Renewal

The installer creates a **DSM Task Scheduler** entry named
*"Let's Encrypt renewal (syno-letsencrypt)"*, running as root, daily, at a
randomised hour between 01:00 and 05:00.

It appears in **Control Panel → Task Scheduler** like any other task. You can
see its last run and exit status, disable it, or run it on demand — without
knowing this tool exists. That was the point of using it rather than a systemd
timer, which works but is invisible to anyone looking at the NAS.

A renewal only re-imports into DSM when the certificate actually changed, so
DSM's web server is not restarted daily for nothing.

---

## How it works

1. `lego` proves you own the domain by creating an `_acme-challenge` TXT record
   in Cloudflare, then removing it. Nothing inbound is ever opened.
2. The certificate is handed to DSM through `synowebapi` — the same code path
   Control Panel uses when you upload one by hand — so DSM writes its own
   certificate store, copies the certificate to every subscribing service, and
   reloads its web server itself.
3. The scheduled task checks daily and renews within 30 days of expiry.

Because it runs as root, **no DSM username or password is needed anywhere.**
The only credential stored is the Cloudflare token.

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
Read`. Cloudflare's "Edit zone DNS" template does not include it.

**"No zone in this Cloudflare account matches ..."** — the installer prints
every zone the token *can* see. Usually a typo, or the token's Zone Resources
not including this domain.

**"Cloudflare is rate-limiting this token"** — several failed attempts in a row
trigger an undocumented lockout. The token is probably fine; wait a few minutes.

**`lego` reports "could not find zone"** — lego resolves the zone apex through
the system resolver, which fails on networks running Pi-hole, AdGuard,
split-horizon DNS, or a router that hijacks port 53. The installer pins public
resolvers for the challenge lookup to avoid this; change `DNS_RESOLVERS` in the
config if your network needs something else.

**A service is still serving the old certificate** — see
[Replace or create new?](#replace-or-create-new). Fix it in Control Panel →
Security → Certificate → Settings, or re-run the installer and choose replace.

**After a DSM major upgrade** — re-run the installer. It is idempotent, and
DSM upgrades have been known to remove things from `/usr/local`.

---

## Uninstall

```sh
sudo ./uninstall.sh            # keep the certificate, config and ACME account
sudo ./uninstall.sh --purge    # remove them too
```

The certificate already installed in DSM is left alone either way — removing
this tool should not drop your NAS back to a self-signed certificate.

Delete the Cloudflare token yourself at
[dash.cloudflare.com](https://dash.cloudflare.com/profile/api-tokens).

---

## Requirements

- Synology DSM 7.0 or later (developed against 7.3)
- A domain hosted on Cloudflare
- SSH access with an account that can `sudo`

---

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — how it works and why
- [`docs/findings-dsm-privileges.md`](docs/findings-dsm-privileges.md) — what a
  DSM 7.3 package is allowed to do, measured on hardware
- [`docs/adr/`](docs/adr/) — decision records
- [`docs/open-questions.md`](docs/open-questions.md) — what is still unsettled
- [`tools/`](tools/) — diagnostic probes

---

## Licence

MIT — see [LICENSE](LICENSE).
