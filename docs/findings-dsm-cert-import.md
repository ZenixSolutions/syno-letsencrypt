# What SYNO.Core.Certificate import actually accepts

Measured on **DSM 7.3-86009**, by changing one parameter at a time against a
real NAS. Everything here is an observation, not a reading of documentation —
Synology publishes none for this endpoint.

## The headline

**Error 5511 does not mean the private key is malformed.**

DSM returns it for at least one condition that has nothing to do with the key,
and it returns it identically whatever the key contains. That single misleading
code cost an evening and produced three wrong diagnoses, in this order:

1. *"lego writes SEC1 keys and DSM wants PKCS#8."* Converting the key changed
   nothing.
2. *"DSM's import won't accept elliptic-curve keys at all."* A fresh RSA-2048
   key produced the identical error.
3. *"DSM protects certificates its own ACME client manages."* Replacing a
   certificate we had created ourselves minutes earlier failed the same way.

Each was plausible, each explained the evidence in hand, and each was reasoning
from a single difference noticed in isolation. The actual cause was a fourth
difference nobody had listed.

## The actual rule

`as_default` must be a **quoted JSON string**. Sent as a bare `true` it becomes
a JSON boolean and the call is refused.

    api=SYNO.Core.Certificate method=import version=1
        key_tmp=<path> cert_tmp=<path> inter_cert_tmp=<path>
        desc=<string> id=<cert id>
        as_default=true              <-- 5511, boolean
        as_default="true"            <-- accepted, is_default flips

Dropping the argument entirely also succeeds, which is what first isolated it:
the identical call minus that one parameter replaced the certificate in place
and preserved its service assignments.

So there is no separate "set default" endpoint to find, and no workaround
needed. The parameter was right, the type was wrong, and the error code named
neither.

## What was ruled out, and stays ruled out

Each of these was tested by holding everything else constant. They are recorded
because a future change might otherwise re-introduce one as a "fix".

| Suspected | Verdict |
| --- | --- |
| SEC1 vs PKCS#8 key encoding | Irrelevant. Both refused, both accepted. |
| EC vs RSA key type | Irrelevant. `ec256` and `rsa2048` behave identically. |
| Temp file path, name, extension | Irrelevant. `mktemp`'s `/tmp/tmp.AbC123` works. |
| Temp file permissions (0600) | Irrelevant. root reads them fine. |
| Replacing vs creating | Both work. `id=` is accepted. |
| DSM-managed certificates being protected | No such protection observed. |

`--key-type rsa2048` remains the default, but for interoperability rather than
necessity: it was adopted while chasing hypothesis 2 and there is no measured
reason to prefer it. An EC key imports successfully.

## The JSON type trap

`synowebapi --exec-fastwebapi` parses **every** `key=value` argument as JSON,
falling back to raw text when the value is not valid JSON. Two consequences,
both of which produce silent corruption or nonsense errors rather than a clear
complaint:

- A certificate id like `8ec29f37` is valid JSON — as **scientific notation**.
  String values must be explicitly quoted, which is what `jstr` in `dsm.sh` is
  for.
- `as_default=true` arrives as a JSON **boolean**, and DSM wants the string
  `"true"`. Confirmed by `tools/probe-cert-default.sh`: the quoted form was the
  first thing it tried and it worked, verified by reading `is_default` back
  rather than trusting `success: true`.

That is the same mistake in two different parameters. **Assume every value
sent to this API needs deliberate quoting** until proven otherwise, and be
suspicious of any parameter whose natural form is a boolean or a bare number.

## Service assignment refuses QuickConnect, silently

`SYNO.Core.Certificate.Service` `set` will not move `system/quickconnect` to an
imported certificate. It does not say so. The call returns `success: true`, no
error code, and the service stays where it was.

Measured: nine services requested, eight assigned, nothing reported.

This is DSM being right — QuickConnect is served by the Synology-issued
certificate for `<name>.direct.quickconnect.to`, and no public CA will issue
anyone else a certificate for that name. Pointing it at ours would break it.

Two consequences for this tool:

- `system/quickconnect` is excluded from the service picker, in
  `DSM_UNASSIGNABLE`. A choice that cannot work is not worth offering.
- `dsm_assign_services` names the services that did not move rather than only
  counting them. A silent refusal visible only as "9 requested, 8 assigned" is
  something the user has no way to act on.

## Reading errors from this API

`success: true` is not proof that anything changed. `SYNO.Core.Certificate.Service`
has been observed reporting success while making no change at all, which is why
`dsm_assign_services` re-reads the certificate afterwards rather than trusting
the reply. Treat every write to this API family as unverified until read back.

Known codes, with the caveat that 5511 demonstrably lies:

| Code | Nominal meaning | Trust it? |
| --- | --- | --- |
| 105 | caller is not an administrator | yes |
| 5503 | service assignment payload rejected | yes |
| 5510 | certificate file malformed | untested |
| 5511 | private key malformed | **no** — also means an argument had the wrong JSON type |
| 5512 | intermediate certificate rejected | untested |
| 5513 | incomplete chain | untested |
| 5514 | key does not match certificate | untested |

## Method

Every claim above comes from a probe that changes one variable against a
control that is known to fail. `tools/probe-cert-replace.sh` is the one that
found this; it refuses to interpret its own results if the reproduction case
does not itself fail, because a matrix built on a passing control proves
nothing. That property is the reason it succeeded where three rounds of
plausible reasoning did not.
