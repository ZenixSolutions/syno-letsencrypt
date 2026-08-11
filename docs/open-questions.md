# Open questions

Ordered by what would cost most to get wrong.

## 1. Unattended renewal has never run — **the last unproven path**

Everything has been exercised by hand. A production certificate has been
issued, imported, made the system default and assigned to eight services, and
`renew` has been confirmed to do nothing when the certificate is still current.

What has not happened is the scheduled task firing on its own. Until it does,
the renewal path is verified only under a terminal, with a TTY, with output on
screen. Differences worth expecting: no TTY, so the progress rendering takes
its non-interactive branch and lego writes straight through; a different
environment and `PATH`; and failures visible only in Task Scheduler's run
history.

Confirmation is `zenix-cert status` showing a last-run record where it
currently reports `[No last run record]`.

## 2. No way to install a certificate already on disk

The only command that pushes a certificate into DSM is `issue`, which first
obtains a new one from Let's Encrypt. There is no way to re-run the DSM half
alone.

This matters because Let's Encrypt permits five duplicate certificates per week
per hostname. During development, four separate situations called for
re-installing an unchanged certificate — a failed import, a corrected
parameter, a restored NAS — and each cost a certificate from that allowance.

A `zenix-cert install` subcommand would use the existing `install_into_dsm`
path with no ACME traffic at all. It is the clearest gap in the command set.

## 3. Failure is silent

A certificate tool that says nothing when renewal breaks eventually breaks
quietly. The Task Scheduler entry is created with `notify_if_error` set and an
address when one is given, so DSM will mail on a non-zero exit — but that has
not been tested, and it only fires if the script actually exits non-zero.

Worth verifying deliberately: force a failure, confirm the mail arrives.
`/usr/syno/bin/synonotify` is also available for DSM desktop notifications.

## 4. `curl | sudo bash`

The installer asks the user to run unreviewed code as root. Mitigations in
place: the script is short and readable, fetched over HTTPS, states what it
will do before doing it, and `./install.sh` from a clone is always offered.

Two improvements worth making before wider use:

- publish a SHA-256 of `install.sh` per release, so a careful user can verify
  before piping;
- pin the one-liner to a tag rather than `main`, so a repository compromise
  cannot silently change what people run.

## 5. Smaller things

- **The QuickConnect exclusion is untested.** It was added after the last
  installer run, so nothing has yet confirmed it disappears from the picker.
- **Multiple certificates.** One per NAS today, which covers nearly everyone.
  More would require a configuration directory rather than a single file.
- **Tests.** `test/` is empty. The valuable ones are `cloudflare.sh` against a
  stubbed `curl` — ambiguous zone matches, the empty-result trap, the `10502`
  lockout — and a `dsm.sh` harness with `synowebapi` stubbed.
- **DSM upgrades.** Major upgrades have been known to remove files from
  `/usr/local`. The installer is idempotent, so re-running restores everything,
  but the user has to notice. `status` reports whether the scheduled task
  exists, which covers the most damaging case.
- **armv5.** Not supported; those models cannot run DSM 7.
