# Architecture

## Shape

```
Package Center
   |
   |  install wizard collects: setup token, domains, email, options
   v
preinst    ── checks only. DSM 7? cert store present? Cloudflare reachable?
   |
postinst   ── runs as root
   |          1. persist wizard answers to var/config (0600)
   |          2. syno-letsencrypt setup
   |               - validate setup token can mint tokens
   |               - API label-walk to find the zone owning the domain
   |               - mint a scoped token, persist it, self-test it
   |          3. enable the renewal timer
   |          4. syno-letsencrypt issue   (non-fatal on failure)
   v
systemd timer, daily ── syno-letsencrypt renew
                          - lego renew --days 30
                          - if the certificate changed, import into DSM
```

## Why these choices

### Cloudflare API label walk, not lego's DNS walk

lego finds a domain's zone apex by walking up the labels issuing SOA queries
against the system resolver. On any network running Pi-hole, AdGuard Home,
split-horizon DNS, or a router that hijacks port 53, that walk fails — and the
error it produces reads like a credentials problem, which sends people down the
wrong debugging path for hours.

We do our own walk against the Cloudflare API at install time instead. It does
not care what the local resolver does, it fails at install rather than at the
first renewal, and it produces the zone ID we need for the token policy anyway.
lego is additionally pinned to public resolvers for the challenge lookup.

### `synowebapi`, not the HTTP API

acme.sh's DSM deploy hook drives DSM's Web API over HTTP, which means it needs a
DSM administrator username and password, guesses at ports, and breaks on 2FA. Its
workaround for unattended use creates a temporary admin account *and disables 2FA
enforcement DSM-wide* for the duration — if it dies in between, 2FA stays off.

`/usr/syno/bin/synowebapi --exec-fastwebapi` runs the same API in-process as
root. No credentials, no HTTP, no ports, no 2FA interaction. A package already
has root during `postinst`; there is no reason to accept the other risks. Direct
`_archive` manipulation plus `synow3tool --gen-all` is kept as a fallback for
builds where the `synowebapi` signature differs, since that interface is
undocumented.

### Two tokens, not one

Asking a user to create a DNS-scoped token by hand means walking them through
Cloudflare's permission UI in a README, and most people over-grant. Asking for
one broad token and storing it means a long-lived credential on the NAS with far
more authority than it needs.

Instead: one setup token, used once in memory, that can do nothing except create
other tokens. It produces a credential scoped to DNS edit on a single zone, which
is what gets stored. The setup token never touches disk and can be deleted
immediately.

### Vendored `lego` and `jq`

DSM does not ship `jq`, and downloading dependencies during `postinst` would mean
installs fail behind a proxy or on an isolated VLAN, and that the `.spk` someone
audits is not the code that runs. Both binaries are static, so bundling costs
about 30 MB per architecture and buys reproducibility.

### One SPK per architecture

`noarch` is a compatibility declaration, not runtime dispatch — DSM will not pick
a binary for you. Bundling all three architectures in one `noarch` package works
but triples the download. Per-arch packages are what the ecosystem expects and
what SynoCommunity does.

## Layout

```
src/bin/syno-letsencrypt   CLI: setup, issue, renew, status, revoke-token
src/lib/log.sh             logging, redaction
src/lib/cloudflare.sh      token validation, zone discovery, minting, self-test
src/lib/dsm.sh             certificate import (synowebapi + fallback)

spk/INFO.in                package metadata template
spk/conf/privilege         run-as package, root only for specific scripts
spk/conf/resource          /usr/local/bin symlink
spk/conf/systemd/          renewal service + timer
spk/scripts/               DSM lifecycle scripts
spk/WIZARD_UIFILES/        install and uninstall wizards

build/build-spk.sh         vendors dependencies, assembles the .spk
```

## On-disk state

| Path | Mode | Contents |
|---|---|---|
| `var/config` | 0600 | domains, email, options, cached zone ID |
| `home/cloudflare.env` | 0600 | the minted Cloudflare token |
| `home/cloudflare.token-id` | 0600 | token ID, so uninstall can revoke it |
| `var/lego/` | 0700 | ACME account key and issued certificates |

`home/` is the FHS directory DSM creates at 0700 for exactly this purpose. Both
survive package upgrades and are removed on uninstall only if the user asks.
