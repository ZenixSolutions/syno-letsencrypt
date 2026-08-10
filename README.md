# syno-letsencrypt

Let's Encrypt certificates — including wildcards — for Synology DSM 7, issued
over the Cloudflare DNS-01 challenge and installed directly into DSM's
certificate store. Delivered as a Package Center `.spk`, not a shell script you
have to babysit over SSH.

No inbound ports need to be open. Nothing is exposed to the internet.

> **Status: in development.** Nothing here has been installed on a real NAS yet.
> See [`docs/open-questions.md`](docs/open-questions.md) for what is still
> undecided and [`docs/architecture.md`](docs/architecture.md) for how it works.

## Why this exists

The usual options are a shell script installed over SSH that you re-run by hand,
or acme.sh with a deploy hook that wants your DSM administrator password and
breaks when you turn on 2FA. Neither is something you would hand to someone else
to run.

This is packaged software: install it from Package Center, answer three
questions, and DSM has a valid certificate that renews itself.

## What it does

- **Cloudflare only.** Not a plugin framework with sixty half-maintained DNS
  providers. One provider, done properly.
- **Mints its own credentials.** You paste one setup token during installation.
  The package uses it once to create a second token that can edit DNS for your
  domain and nothing else, verifies that token actually works, then forgets the
  setup token. It is never written to disk.
- **Installs into DSM properly.** Uses DSM's own certificate API as root, so
  DSM updates every subscribing service and restarts its web server the same way
  it would if you had uploaded the certificate by hand. Never asks for your DSM
  password.
- **Renews unattended.** A systemd timer, daily, with a randomised delay and
  catch-up if the NAS was powered off.

## Install

1. Download the `.spk` for your NAS's CPU from
   [Releases](https://github.com/ZenixSolutions/syno-letsencrypt/releases).
2. **Package Center → Manual Install** → select the file.
3. DSM will warn that the package is from an unknown publisher. This is expected
   for every non-Synology package on DSM 7 — publisher trust was removed in DSM
   7 and there is no way to suppress it. Verify the `.sha256` alongside the
   release if you want assurance.
4. Answer the install wizard.

### Which architecture?

| Your NAS CPU | Download |
|---|---|
| Intel / AMD (most `+`, `xs`, `RS` models) | `x86_64` |
| 64-bit ARM (Realtek RTD1296/RTD1619, Marvell Armada 37xx) | `armv8` |
| 32-bit ARM (Alpine AL-314 and similar) | `armv7` |

`uname -m` over SSH will tell you: `x86_64`, `aarch64`, or `armv7l`.

## The setup token

During installation you are asked for a Cloudflare **setup token**. Create it at
**dash.cloudflare.com → My Profile → API Tokens → Create Token → Custom token**
with exactly one permission:

| Scope | Resource | Permission |
|---|---|---|
| User | API Tokens | Edit |

That token is used once, in memory, to create the real credential. Delete it
from Cloudflare as soon as the install finishes.

The token the package creates for itself is scoped to:

| Permission | Scope | Why |
|---|---|---|
| `DNS Write` | your zone only | Create and delete the `_acme-challenge` TXT record |
| `Zone Read` | account | Look the zone up by name. lego needs this and it discloses only zone names |

## Usage

The package runs itself, but everything is available over SSH:

```sh
sudo /usr/local/bin/syno-letsencrypt status   # config, expiry, next renewal
sudo /usr/local/bin/syno-letsencrypt renew    # renew now if within 30 days
sudo /usr/local/bin/syno-letsencrypt issue    # force a fresh issuance
```

Logs: `/var/log/packages/syno-letsencrypt.log`.

## Building

```sh
build/build-spk.sh --all              # all three architectures into dist/
build/build-spk.sh --arch x86_64
```

`lego` and `jq` are vendored into the package rather than downloaded on the NAS,
so installs work on air-gapped networks and the shipped artifact is the code
that runs. DSM does not ship `jq`.

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
