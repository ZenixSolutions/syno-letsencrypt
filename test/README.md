# Tests

Nothing here yet. Planned:

- `bats` unit tests for `cloudflare.sh` against a stubbed `curl`, covering the
  cases that are easy to get wrong: an ambiguous permission-group name, a zone
  lookup returning `success: true` with an empty array, and the label walk
  terminating at a public suffix.
- A `dsm.sh` harness with `synowebapi` stubbed, asserting the fallback path
  triggers on each documented DSM error code.
- An end-to-end run against Let's Encrypt staging on real hardware. This is the
  one that actually matters and cannot be faked.
