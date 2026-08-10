# syno-letsencrypt

```
   ███████╗███████╗███╗   ██╗██╗██╗  ██╗
   ╚══███╔╝██╔════╝████╗  ██║██║╚██╗██╔╝
     ███╔╝ █████╗  ██╔██╗ ██║██║ ╚███╔╝
    ███╔╝  ██╔══╝  ██║╚██╗██║██║ ██╔██╗
   ███████╗███████╗██║ ╚████║██║██╔╝ ██╗
   ╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝
   S O L U T I O N S
```

Let's Encrypt certificates — including wildcards — for Synology DSM 7, over the
Cloudflare DNS-01 challenge, installed straight into DSM and renewed
automatically.

No open ports. No DSM password stored anywhere. One command.

> **Status: in development, not yet run end to end on hardware.**

## Install

SSH into your NAS and run:

```sh
curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh | sudo bash
```

It checks your NAS, downloads `lego`, asks for your Cloudflare token and
domains, **proves the token works before writing anything**, lets you choose
whether to replace an existing DSM certificate or create a new one and which
services should use it, then schedules a daily renewal check.

Prefer to read it first? That's the better instinct:

```sh
git clone https://github.com/ZenixSolutions/syno-letsencrypt.git
cd syno-letsencrypt
less install.sh
sudo ./install.sh
```

## The Cloudflare token

At [dash.cloudflare.com → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens)
→ **Create Token**, start from the **Edit zone DNS** template, then:

| Scope | Resource | Permission | |
|---|---|---|---|
| Zone | DNS | Edit | included by the template |
| Zone | Zone | **Read** | **you must add this row yourself** |

Under **Zone Resources**, include your domain.

That second row is the one nearly everyone misses. Cloudflare's own template
doesn't include `Zone → Read`, and without it the certificate can't be issued —
your domain has to be resolved to a zone ID before the challenge record can be
created. The installer checks for exactly this and says so plainly, rather than
failing later with something cryptic.

## Usage

Renewal is automatic. Everything is also available on demand:

```sh
sudo syno-letsencrypt status    # expiry and next scheduled run
sudo syno-letsencrypt check     # re-validate the token, change nothing
sudo syno-letsencrypt renew     # what the scheduled task runs
sudo syno-letsencrypt issue     # force a fresh issuance
```

Configuration lives in `/usr/local/etc/syno-letsencrypt/config` (root-only) and
is plain shell — edit it directly and re-run `check`.

Renewal runs and their exit status appear in Control Panel → Task Scheduler.

## How it works

1. `lego` proves you own the domain by creating an `_acme-challenge` TXT record
   in Cloudflare, then removing it. Nothing inbound is ever opened.
2. The certificate is handed to DSM through `synowebapi` — the same code path
   Control Panel uses when you upload one by hand — so DSM writes its own
   certificate store, copies the certificate to every subscribing service, and
   reloads its web server itself.
3. A **DSM Task Scheduler** entry checks daily and renews inside 30 days,
   re-importing only when the certificate actually changed. It shows up in
   Control Panel → Task Scheduler like any other task, so you can see its last
   run, disable it, or run it on demand without knowing this tool exists.

Running as root means **no DSM username or password is needed**. The only
credential stored is the Cloudflare token, at mode `0600`.

DSM 7.3 serves dual ECC and RSA certificates, so `cert.pem` no longer exists in
`system/default`. Letting DSM own that layout, rather than writing the files
ourselves, is what keeps this working across DSM releases — details in
[`docs/findings-dsm-privileges.md`](docs/findings-dsm-privileges.md).

## Uninstall

```sh
sudo ./uninstall.sh            # keep the certificate and configuration
sudo ./uninstall.sh --purge    # remove them too
```

The certificate already installed in DSM is left alone either way — removing
this shouldn't drop your NAS back to a self-signed certificate.

## Requirements

- Synology DSM 7.0 or later
- A domain hosted on Cloudflare
- SSH access with an account that can `sudo`

## Design notes

This started as a Package Center `.spk`, became a container, and ended up here.
Both earlier designs were killed by measurements taken on real hardware rather
than by guesswork: a DSM 7 package cannot get the privilege it needs, and the
container workaround required a DSM administrator account. A root script has
neither problem.

- [`docs/findings-dsm-privileges.md`](docs/findings-dsm-privileges.md) — what a
  DSM 7.3 package is actually allowed to do, measured
- [`docs/architecture.md`](docs/architecture.md) — how the current design works
- [`docs/adr/`](docs/adr/) — the decisions, including the two that were reversed

## Prior art

The DSM certificate layout and the `synowebapi` import path were worked out by
others first, in particular [catchdave/ssl-certs](https://github.com/catchdave/ssl-certs),
[zaxbux/syno-acme](https://github.com/zaxbux/syno-acme), and
[JessThrysoee/synology-letsencrypt](https://github.com/JessThrysoee/synology-letsencrypt),
which was the starting point for this project. This is an independent
implementation, not a fork of their code.

## Licence

MIT — see [LICENSE](LICENSE).
