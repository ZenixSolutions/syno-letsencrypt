# ADR 0001 — Ship as a DSM package, not an install script

**Status:** Accepted · 2026-08-10

## Context

The prior art in this space is uniformly "curl a script and run it as root over
SSH". That works for the author and nobody else. It leaves no upgrade path, no
uninstall, no visibility in DSM, and no way to hand the tool to someone who is
not comfortable in a terminal.

DSM 7 packages are plain tar archives. Signing was removed in DSM 7, and the
Synology build toolchain exists to cross-compile C and to sign — neither applies
to shell plus static binaries.

## Decision

Ship a `.spk` installable from Package Center, built with `tar` from a script in
this repository.

## Consequences

- Install configuration moves into DSM's wizard, which is static JSON. Rich
  validation at input time is not possible (see `docs/open-questions.md` §2).
- Renewal becomes a systemd timer the package owns, rather than a Task Scheduler
  entry the user creates by hand.
- Upgrade and uninstall become real, testable operations.
- Users see an unavoidable "unknown publisher" warning. DSM 7 removed publisher
  trust; nothing can suppress this.
- We take on a build and release process that a single script did not need.
