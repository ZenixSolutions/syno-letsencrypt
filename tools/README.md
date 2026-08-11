# Diagnostics

Standalone scripts for investigating a NAS where something is not behaving as
expected. They are not part of the install and are not needed in normal use.

Each is run directly from the repository:

```sh
curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/<script> | sudo bash
```

All of them require an existing configuration at
`/usr/local/etc/syno-letsencrypt/config`, and none issues a certificate or
counts against Let's Encrypt rate limits.

| Script | Use when |
| --- | --- |
| `diagnose-dns.sh` | A challenge times out, or lego cannot find the zone. Reports what this NAS resolves versus what the rest of the internet sees, which distinguishes a genuine DNS problem from a stale cached negative. |
| `probe-cert-import.sh` | DSM rejects a certificate. Exercises the import API directly with the certificate already on disk, varying how the files are presented, and prints DSM's complete reply including the stderr the tool normally discards. |

`probe-cert-import.sh` installs the certificate for real if a variant succeeds.
That is intentional — a successful import is the desired outcome, not merely a
diagnostic result — but it means the script changes state and should not be run
casually.

Findings produced by these scripts on DSM 7.3-86009 are recorded in
[../docs/findings-dsm-cert-import.md](../docs/findings-dsm-cert-import.md).
