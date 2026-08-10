# Tests

Not written yet. The ones worth having:

- `cloudflare.sh` against a stubbed `curl`, covering the cases that are easy to
  get wrong: a zone lookup returning `success: true` with an empty array, the
  ambiguous `code: 0` 403, the undocumented `10502` auth lockout, and longest-
  suffix zone matching for `nas.home.example.com`.
- `dsm.sh` with `synowebapi` stubbed, asserting each documented DSM error code
  produces the right message.
- An end-to-end run against Let's Encrypt **staging** on real hardware. This is
  the one that actually matters and cannot be faked.
