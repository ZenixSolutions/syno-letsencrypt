# The DSM account

This tool needs a DSM account to install the certificate, because on DSM 7.3
nothing else can. See [architecture.md](architecture.md) for why.

Use a dedicated account. Do not use your own.

## Creating it

**Control Panel → User & Group → User → Create**

| Field | Value |
|---|---|
| Name | `svc-letsencrypt` |
| Password | long and random — nothing types it, so make it 40+ characters |
| Groups | `users`, `administrators` |
| Permissions | deny access to every shared folder |
| Applications | deny everything except **DSM** |
| Quota | 0 |

Administrator rights are required — certificate import returns error 105 for a
non-administrator, and DSM offers no finer-grained permission for it. That is a
real limitation and worth being clear-eyed about: this account can administer
your NAS. Everything else here is about reducing what it can reach in practice.

## Two-factor authentication

Leave 2FA **off for this account only**. An unattended container cannot type a
one-time code.

If your DSM enforces 2FA for all administrators, run the container once with
`DSM_OTP_CODE` set to a current code. DSM returns a device id, which the log
prints. Put that in `DSM_DEVICE_ID` and subsequent logins skip the code.

## Reducing the blast radius

- **Restrict where it can sign in from.** Control Panel → Security → Account →
  the account can be limited to the local network. The container connects from
  the Docker bridge, which counts as local.
- **Turn on Auto Block** (Control Panel → Security → Account) so a leaked
  password cannot be brute-forced from outside.
- **Watch it.** Control Panel → Log Center shows this account's logins. It
  should sign in about twice a day and do nothing else. Anything more is worth
  investigating.
- **Rotate it** if the compose file is ever exposed — the password lives in
  plain text there.

## Why not something better

There isn't one. DSM has no service accounts, no scoped API tokens, and no
permission for "manage certificates" short of full administrator. Every tool in
this space either does this or requires root on the NAS.
