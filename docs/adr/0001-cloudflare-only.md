# ADR 0001 — Cloudflare only

**Status:** Accepted · 2026-08-10

## Context

lego supports well over a hundred DNS providers, and delegating to it costs
nothing at the code level. It costs a great deal at the product level: the
configuration surface has to stay generic, credentials become an opaque
environment file the user fills in from provider documentation, and none of it
can be validated, because nothing is known about the provider until it fails.

## Decision

Support Cloudflare and nothing else.

## Consequences

- Credentials stop being an opaque environment file. The installer can validate
  the token, discover the zone, and prove the token works before the install
  completes. None of that is possible generically.
- Errors become specific and actionable rather than "check your DNS provider
  settings" — the installer can distinguish a missing `Zone:Read` permission
  from a mistyped domain from a rate-limit lockout, and say which it is.
- Setup is three questions rather than a provider picker followed by a
  free-text credentials blob.
- Users of other providers are not served. This is a deliberate trade; general
  purpose ACME clients already exist for them.
- Adding a second provider later means re-generalising the credential flow.
  Provider-specific logic is confined to `src/lib/cloudflare.sh` to keep that
  possible, but the design does not anticipate it.
