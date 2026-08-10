# Open questions

Decisions that are not settled, and things that must be verified against a real
NAS before this can be called working. Ordered roughly by how much they would
cost to get wrong.

---

## 1. `run-as: root` on your actual DSM build — **blocking**

The whole design assumes package control scripts can run as root, because
installing a certificate into DSM's store requires it.

What is established:

- DSM 7 removed `run-as: system`. It did **not** remove `run-as: root` — the
  current 7.2.2 privilege documentation still defines root semantics for both
  files and scripts.
- `conf/privilege` supports per-script overrides via `ctrl-script[]`, which is
  what we use: the package itself runs unprivileged, and only `postinst`,
  `postupgrade`, `postuninst`, `start` and `stop` get root.

What is **not** established: whether this still behaves the same way on DSM
7.2/7.3. The public evidence that root works is from DSM 7.0 in 2021.

**Action:** install a throwaway build on the target NAS and check that `postinst`
can write to `/usr/syno/etc/certificate/_archive`. If it cannot, the fallback is
a setuid helper installed by `postinst`, which is materially worse and worth
knowing about early.

---

## 2. Install-time error UX

DSM's install wizard is static JSON. It collects input and hands it to
`postinst`; there is no way to validate the Cloudflare token *while the user is
still looking at the wizard*, and no way to show them a rich error afterwards.

So the flow today is: bad token → install fails → user is told to read
`/var/log/packages/syno-letsencrypt.log`. That is a poor experience for the most
likely failure.

Options:

1. **Accept it.** `preinst` catches the obvious cases (no token, no network, not
   DSM 7) and aborts with a readable message, which covers most of it.
2. **Never fail the install.** Always install successfully, and put the entire
   Cloudflare setup behind a `status`/`setup` CLI step the user runs over SSH.
   Robust, but an SSH step defeats the point of packaging it.
3. **Build the DSM web UI** (see §5) and do Cloudflare setup there, with live
   validation and a real zone picker. Best experience by a wide margin, and much
   the most work.

Currently implemented: option 1, with first issuance made non-fatal so a typo in
the domain does not leave a "corrupted" package.

**Needs your call.**

---

## 3. Zone Read scope — narrow or account-wide?

Sources genuinely conflict on whether a token with `Zone Read` scoped to a single
zone can list that zone by name.

- lego's own documentation says you must "scope the access to all your domains
  for this to work", and cert-manager specifies "All Zones".
- certbot's current documentation says a token scoped to only the zones you need
  is sufficient, and its code makes the same `GET /zones?name=` call.

The dangerous failure is not an error: a too-narrow token returns HTTP 200 with
an empty result array, which lego surfaces weeks later as "zone could not be
found" at renewal time.

Current approach: `DNS Write` — the permission that can actually cause damage —
is pinned to the single zone, and `Zone Read` is account-wide. `cf_selftest_token`
then empirically proves the token works before it is trusted.

**Alternative if you want maximum tightness:** try zone-scoped Zone Read first,
and widen only if the self-test fails. Costs one extra API round trip and some
complexity for a small reduction in an already low-value disclosure. Say the word
and I will implement it.

---

## 4. Custom package source — worth it?

You asked specifically about hosting our own Package Center source. Findings:

**It works, and it is not much code.** A package source is a single URL that
Package Center hits with `arch`, `build`, and `language`, and that returns JSON
describing available packages. The `link` field can point anywhere — GitHub
Releases is fine — so the source hosts metadata only, not the `.spk` files.
This is exactly how [007revad's source](https://github.com/007revad/Synology_package_source)
works.

**But it cannot be a static file on GitHub Pages.** Package Center appears to
`POST`, and GitHub Pages returns `405 Method Not Allowed` on POST. Verified
directly. It needs something that can answer POST: a Cloudflare Worker (free
tier, ~15 lines, and you already have a Cloudflare account), Pages Functions, or
any small function host.

**It does not remove the security warning.** DSM 7 deleted publisher trust
levels entirely. Users see "provided by third-party developers and not verified
by Synology" whether they install manually or from a custom source. There is no
setting to change and no signing that helps — package signing was removed in
DSM 7 too.

**So what it actually buys you:** in-place upgrade notifications in Package
Center, and a nicer install path for anyone you hand this to.

**Recommendation:** ship v1 as GitHub Releases + Manual Install. Add the Worker
once the package is real. If Zenix ends up publishing more DSM packages, one
source can serve all of them and the effort amortises — that is the argument for
doing it sooner.

**Needs your call on timing.**

---

## 5. A DSM web UI — v1 or later?

A package can register a desktop icon and a UI in DSM (`dsmuidir` in INFO plus a
`config` file and seven icon sizes). A launcher that opens a static status page
is a couple of hours' work.

A *functional* UI — view certificate status, change the token, trigger a renewal
— needs a CGI backend behind DSM's nginx, and DSM 7 removed `Init_3rdParty` and
blocks packages from writing nginx config. That is a multi-day project on its
own.

**Recommendation:** skip for v1. Revisit once the core is proven, because it is
also the answer to §2.

---

## 6. Upstream has no licence — **resolved, but you should know**

`JessThrysoee/synology-letsencrypt` ships **no LICENSE file** and GitHub reports
no licence for it. Without one, default copyright applies: no permission to copy,
modify, or redistribute. A true fork would have been legally awkward to
redistribute.

This is moot given the clean-room decision, and the architecture diverged so far
(SPK, Cloudflare-only, `synowebapi`, minted tokens) that almost nothing carries
over anyway. The one genuinely useful idea taken from it — walking
`_archive/INFO` to find which services subscribe to a certificate — is also
present in MIT-licensed projects and is a description of DSM's behaviour rather
than creative expression.

The README credits them. If you would rather be maximally clean, opening an issue
asking them to add a licence costs nothing.

---

## 7. Smaller things

- **`armv5` support.** Dropped. Those NAS models cannot run DSM 7 anyway.
- **Certificate for services other than DSM.** Right now the certificate is
  imported and optionally set as DSM's default. Assigning it to specific
  services (Drive, reverse proxy entries, etc.) is left to the DSM UI. Should the
  wizard offer this?
- **Notifications.** DSM can send desktop and email notifications via the
  `sysnotify` resource worker. A cert tool that stays silent when renewal breaks
  is a cert tool that eventually breaks silently. Worth wiring up — needs a
  small `ui/texts` bundle.
- **Multiple certificates.** Current design is one certificate per NAS, which
  covers the overwhelming majority of cases and keeps the wizard to three
  screens. Multiple certs would need the web UI.
- **Token rotation.** `PUT /user/tokens/{id}/value` rolls the secret. No
  expiry is set on the minted token deliberately — an expiring credential turns a
  working appliance into a silently broken one on a date nobody remembers. Should
  there be a `rotate-token` command?
