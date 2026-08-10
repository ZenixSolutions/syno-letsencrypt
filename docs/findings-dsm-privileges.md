# What a DSM 7.3 package is actually allowed to do

Measured on a real NAS, **DSM 7.3-86009, broadwell/x86_64**, 2026-08-10, using
purpose-built diagnostic packages. This document exists because the published
documentation and the community folklore both turned out to be wrong, and the
architecture changed twice as a result.

## Results

| Question | Answer |
|---|---|
| Does a package declaring `run-as: root` install? | **No.** Refused by Package Center for unsigned packages. |
| What user do install scripts run as? | The package user (`uid 169659`), **not root**. |
| Can `postinst` read `/usr/syno/etc/certificate/_archive`? | **No** — not even readable. |
| Can `postinst` write it? | No. |
| Can the package user execute `synowebapi`? | **No** — Permission denied. Same for `synow3tool`. |
| Are `conf/systemd/pkg-*` units installed? | **Yes**, to `/usr/local/lib/systemd/system`, owned root:root. |
| Can the package start such a unit with `User=root`? | **No.** `synosystemctl start` returned `Fail to start []`; the unit never ran. |
| What user does a CGI under `/webman/3rdparty/` run as? | The package user. Not root. |
| Is `login.cgi` usable for server-side session validation? | **No** — present but not executable by the package user. |
| Does `initdata.cgi` exist? | **No.** Absent on 7.3. |
| Can a Docker container read and write the certificate store? | **Yes** — root in-container, `WRITE: YES` through a bind mount. |

## DSM 7.3 serves dual certificates

Round 3 turned up something that matters independently of privileges. On DSM
7.3, `system/default` no longer contains `cert.pem`:

```
-r-------- root root  ECC-cert.pem   ECC-fullchain.pem   ECC-privkey.pem
-r-------- root root  RSA-cert.pem   RSA-fullchain.pem   RSA-privkey.pem
-rw------- root root  info
```

DSM now installs an ECC and an RSA certificate side by side and serves whichever
the client negotiates. Every filesystem-based tool in this space writes
`cert.pem`/`privkey.pem`/`fullchain.pem` — names that **no longer exist here**.

This is exactly the class of breakage that argues for the API: the layout is
undocumented, it changed between releases, and DSM knows how to write it
correctly. On this NAS the subscribers were `system`, `smbftpd/ftpd` and
`kmip/kmip`, with no reverse-proxy entries.

## What this rules out

Every design that depends on the package performing a privileged operation.
The certificate store is not merely write-protected — it is unreadable, and the
tools that manipulate it are unrunnable. There is no partial access to work with.

It also rules out the two workarounds that circulate in the community:
declaring root and rewriting `conf/privilege` from `postinst` (the package no
longer installs), and starting a `User=root` systemd unit the package shipped
(the unit installs but cannot be started).

## What it leaves

Only actors that already have privilege:

1. **DSM itself**, via its authenticated Web API. This is what we use. An
   administrator credential is required, but nothing on the NAS runs as root on
   our behalf and no host paths are touched.
2. **A root task the user creates**, in Task Scheduler. Reliable, no stored
   credentials, but a manual setup step.
3. **The Docker daemon**, which runs as root. A bind-mounted container can write
   the certificate files — confirmed — but cannot make nginx reload them without
   `privileged` + `pid: host` + `nsenter`, which is a container escape and hands
   the container full control of the NAS. Rejected on those grounds.

## A note on the exposure this uncovered

The round-1 probe reported `SERVER_NAME: <public FQDN>`, `HTTPS: on`, and a
public `REMOTE_ADDR` — the DSM UI on the test NAS is reachable from the
internet. Anything served under `/webman/3rdparty/` inherits that, and DSM does
**not** authenticate that path on a package's behalf. Combined with `login.cgi`
being unusable and `initdata.cgi` being absent, a package CGI on 7.3 has no
straightforward way to verify its caller — which is a good reason to keep
secrets out of any HTTP-reachable surface entirely.
