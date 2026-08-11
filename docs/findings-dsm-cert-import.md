# What SYNO.Core.Certificate accepts

Measured on **DSM 7.3-86009** by varying one parameter at a time against real
hardware. Synology publishes no documentation for this endpoint, so everything
here is observation rather than specification, and may differ on other releases.

## Error 5511 does not mean what it says

`5511` is nominally "illegal key file". DSM also returns it for at least one
condition unrelated to the key, and returns it identically regardless of what
the key contains.

The following were each tested by holding everything else constant, and none of
them affects the outcome:

| Suspected | Verdict |
| --- | --- |
| SEC1 vs PKCS#8 key encoding | No effect. Both accepted, both refused. |
| EC vs RSA key type | No effect. `ec256` and `rsa2048` behave identically. |
| Temp file path, name, extension | No effect. `mktemp`'s `/tmp/tmp.AbC123` works. |
| Temp file permissions (`0600`) | No effect. |
| Replacing vs creating | Both work. `id=` is accepted. |
| DSM-managed certificates being protected | No such protection exists. |

These are recorded because each is a plausible hypothesis that costs real time
to re-test, and each is already excluded.

**Treat 5511 as "something upstream of the key was rejected" and check
argument types first.**

## The rule that was actually found

`as_default` must be a **quoted JSON string**. Sent as a bare `true` it becomes
a JSON boolean and the call is refused.

    api=SYNO.Core.Certificate method=import version=1
        key_tmp=<path> cert_tmp=<path> inter_cert_tmp=<path>
        desc=<string> id=<cert id>
        as_default=true              <-- refused, 5511
        as_default="true"            <-- accepted, is_default flips

Omitting the argument entirely also succeeds, which is what isolated it: the
identical call without that one parameter replaced the certificate in place and
preserved its service assignments.

There is no separate "set default" endpoint. The parameter was correct, the
type was wrong, and the error code described neither.

## The JSON type trap

`synowebapi --exec-fastwebapi` parses **every** `key=value` argument as JSON,
falling back to raw text when the value is not valid JSON. Two consequences,
both of which produce silent corruption or a misleading error rather than a
clear complaint:

- A certificate id such as `8ec29f37` is valid JSON — as **scientific
  notation**. String values must be explicitly quoted, which is what `jstr` in
  `src/lib/dsm.sh` exists for.
- `as_default=true` arrives as a **boolean** where DSM requires the string
  `"true"`.

That is the same mistake in two different parameters. **Assume every value sent
to this API requires deliberate quoting**, and be particularly careful with any
parameter whose natural form is a boolean or a bare number.

## Progress output goes to stderr

`synowebapi` writes lines such as `[Line 295] Exec WebAPI: ...` to standard
error. Capturing a call with `2>&1` merges them into the JSON body, and the
result cannot be parsed.

The failure mode is worse than a parse error. A call that **succeeded** is read
as having failed, and code that retries or falls back to another API will
perform the operation a second time. This was observed creating duplicate
Task Scheduler entries.

Every call must discard stderr and cut to the first `{`. `syno_api` in
`src/lib/dsm.sh` does this; anything calling `synowebapi` directly must do the
same.

## Service assignment refuses QuickConnect, silently

`SYNO.Core.Certificate.Service` `set` will not move `system/quickconnect` to an
imported certificate. It does not report this: the call returns `success: true`
with no error code, and the service remains where it was. Measured as nine
services requested and eight assigned.

The refusal is correct. QuickConnect is served by the Synology-issued
certificate for `<name>.direct.quickconnect.to`, and no public CA will issue
that name to anyone else, so reassignment would break it.

Two consequences for this tool:

- `system/quickconnect` is excluded from the service picker, via
  `DSM_UNASSIGNABLE` in `src/lib/dsm.sh`.
- `dsm_assign_services` names the services that did not move rather than only
  counting them. A silent refusal visible only as "9 requested, 8 assigned"
  gives the user nothing to act on.

## `success: true` is not proof

More generally, this API family reports success for operations it does not
perform. Every write should be verified by reading the resulting state back:

- `dsm_assign_services` re-reads the certificate's services after assigning.
- Anything setting `is_default` should re-read the flag rather than trust the
  reply.

## Error codes

| Code | Nominal meaning | Trustworthy? |
| --- | --- | --- |
| 105 | caller is not an administrator | yes |
| 5503 | service assignment payload rejected | yes |
| 5510 | certificate file malformed | untested |
| 5511 | private key malformed | **no** — see above |
| 5512 | intermediate certificate rejected | untested |
| 5513 | incomplete chain | untested |
| 5514 | key does not match certificate | untested |

## Method

Every claim above was produced by a probe that varies one parameter against a
control case with a known outcome, and that declines to interpret its results
if the control does not behave as expected — a comparison built on a control
that silently passes proves nothing.

`tools/probe-cert-import.sh` remains in the repository for re-testing the
import path on a different DSM release.
