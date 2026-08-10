# Open questions

Ordered by what would cost most to get wrong.

## 1. The repository must be public for the one-liner — **blocking**

`curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh`
returns 404 while the repository is private. Options:

1. **Make it public.** It contains no secrets and is MIT licensed. Simplest, and
   the tool is only useful to people who can fetch it.
2. **Keep it private** and document `git clone` with credentials instead. The
   one-liner then only works for people with access.
3. **Publish the installer alone** as a release asset or GitHub Pages file. Odd
   split, but possible.

Needs a decision before the install instructions are true.

## 2. Not yet run end to end

Nothing here has issued a certificate on real hardware. The first run should use
**staging** — the installer defaults to it — because production allows only five
duplicate certificates per week and a mistake found after burning them means
waiting.

Specifically unverified:

- `synowebapi --exec-fastwebapi ... method=import` argument form on DSM 7.3.
  The interface is undocumented and was taken from a working third-party hook.
  The probe confirmed the binary exists and runs as root; the import call itself
  has not been exercised.
- Whether the import replaces the existing certificate cleanly when matched by
  description, rather than adding a duplicate.
- Whether DSM's reload actually takes effect for all subscribers on 7.3, given
  the dual ECC/RSA layout.

## 3. `curl | sudo bash`

It asks for real trust: the user runs unreviewed code as root. Mitigations in
place — the script is short and readable, fetched over HTTPS from a pinned ref,
states what it will do before doing it, and `./install.sh` from a clone is
always offered.

Worth considering: publishing a SHA-256 of `install.sh` per release so a careful
user can verify before piping, and pinning the one-liner to a tag rather than
`main` so a repository compromise cannot silently change what people run.

## 4. `/etc/systemd/system` and DSM upgrades

DSM major upgrades have been known to remove units from `/etc/systemd/system`.
The installer is idempotent, so re-running restores everything — but the user
has to notice. Options: document it, or have `status` warn when the timer is
missing. The latter is cheap and worth doing.

## 5. Smaller things

- **Notifications.** A cert tool that stays quiet when renewal breaks eventually
  breaks quietly. DSM can send desktop and email notifications via
  `/usr/syno/bin/synonotify`. Worth wiring into the failure path.
- **Multiple certificates.** One per NAS today, which covers nearly everyone.
  More would need a config directory rather than a single file.
- **Assigning the certificate to specific services.** It is imported and
  optionally made DSM's default; assigning it to individual services is left to
  Control Panel.
- **Tests.** `test/` is still empty. The valuable ones are `cloudflare.sh`
  against a stubbed `curl` — ambiguous zone matches, the empty-result trap, the
  10502 lockout — and a `dsm.sh` harness with `synowebapi` stubbed.
- **armv5.** Not supported. Those models cannot run DSM 7.
