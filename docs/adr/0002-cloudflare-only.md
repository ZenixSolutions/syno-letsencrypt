# ADR 0002 — Cloudflare only

**Status:** Accepted · 2026-08-10

## Context

Upstream delegates DNS to lego, which supports well over a hundred providers.
That breadth is free at the code level but not at the product level: the
configuration surface has to stay generic, credentials are an opaque env file the
user fills in from provider documentation, and nothing can be validated because
nothing is known about the provider.

## Decision

Support Cloudflare and nothing else.

## Consequences

- Credentials stop being an opaque env file. The installer can validate the
  token, discover the zone, mint a scoped credential, and prove it works before
  the install finishes. None of that is possible generically.
- Errors can be specific and actionable rather than "check your DNS provider
  settings".
- The wizard is three screens instead of a provider picker plus a free-text
  credentials blob.
- Users of other providers are not served. This is a deliberate trade: upstream
  already exists for them.
- Adding a second provider later means re-generalising the credential flow. The
  provider-specific logic is confined to `src/lib/cloudflare.sh` to make that
  possible, but it is not designed for.
