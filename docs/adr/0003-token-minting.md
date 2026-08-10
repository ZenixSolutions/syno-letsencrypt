# ADR 0003 — Mint a scoped token from a bootstrap token

**Status:** Accepted · 2026-08-10
**Supersedes consideration of:** OAuth, dashboard deep links, manual token entry

## Context

The goal was "let the installer sign into Cloudflare and set up the API key
itself". Four mechanisms were evaluated.

**OAuth.** Cloudflare does now support self-managed OAuth clients with
authorization-code + PKCE, and public clients are explicitly allowed for CLI
apps. But it requires a registered OAuth client, a redirect URL the browser can
reach, and domain verification to make the client public. On a headless NAS,
mid-install, inside a wizard that cannot open a browser, this does not work.

**Dashboard deep link.** An undocumented URL format reportedly pre-fills the
Cloudflare token-creation page with the right permissions. Could not be verified,
and relying on an undocumented dashboard URL for the primary install path is
fragile. Also still requires copy-paste, so it is strictly worse than the option
below while being less reliable.

**Manual token entry.** Works, but requires walking users through Cloudflare's
permission UI in a README. In practice people over-grant, and a long-lived
over-privileged credential then sits on the NAS.

**Bootstrap minting.** The user supplies a token whose only permission is
`API Tokens → Edit`. The installer uses it once, in memory, to create a token
scoped to `DNS Write` on one zone, then discards it.

## Decision

Bootstrap minting.

## Consequences

- The stored credential is the tightest one that works, without the user needing
  to understand Cloudflare's permission model.
- The setup token is never written to disk and can be deleted immediately after
  install. The README says so explicitly.
- The minted token is self-tested before it is trusted, which catches the silent
  failure mode where a too-narrow token returns HTTP 200 with an empty result and
  only breaks weeks later at renewal.
- The user still pastes one token. This is not zero-touch, and cannot be.
- Uninstall cannot revoke the minted token on its own — a DNS-scoped token has no
  permission to delete itself — so uninstall either asks for a bootstrap token
  again or tells the user which token ID to delete.
- Permission group IDs are resolved by name at runtime rather than hardcoded,
  since user-owned and account-owned tokens are served by different endpoints and
  shared UUIDs are not guaranteed.
