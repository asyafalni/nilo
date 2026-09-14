# A presigned URL names the host the browser reaches

Two things had to be done around `presignPost` before a real Garage took
the form, and the policy itself was not one of them: expiry, key,
credential, `content-length-range` and the `Content-Type` condition all held,
a wrong type was refused and an oversized file got a 400.

## The `bucket` field

Garage refuses the form with *Key 'bucket' is required in policy, but no
value was provided* unless `bucket=<name>` is a form field. The policy
already carries `{"bucket": …}` as its first condition; AWS reads the bucket
off the URL and ignores the field; MinIO takes it either way. The value is
the bucket's name, a constant in the binary, so the field costs nothing to
send and is sent everywhere — first, as it is in the policy. A form written
against the old order has one more field in front of `key`.

## `public_endpoint`

`Posted.url` and `Presigned.url` were built on the endpoint the process
dials, and a process dials the store on a Docker network or a Tailscale
address a browser cannot reach. The port rewrote the URL's prefix from its
own config, which works for the POST form — a policy names no host — and is
silently wrong for a presigned GET, because the host is inside the
signature. Every S3 client behind a proxy grows this eventually, and the
one that grows it by rewriting grows a 403 that reads like a signing bug.

`s3.Options.public_endpoint` is the endpoint a browser reaches, when it is
not the one this process dials. A Bucket builds a second host and base from
it at `open`, the way it builds the first, and `presign` **signs that host**
while `presignPost` posts to it. Every call that dials — `get`, `put`,
`head`, `delete` — still dials and signs the first. With none given the
public pair *is* the dialled pair, the same bytes, so an ordinary store's
URLs are exactly what they were.

## What was not done

**A `host` argument on `presign`.** It reads as a per-call choice, and it is
not one: the host a browser reaches is a fact about the deployment, decided
once with the endpoint. Per call is where a mistake is made once per call
site.

**Rewriting after signing, in nilo.** The port's shape, and it is the one
this ADR exists to refuse: a URL whose host was changed after the signature
was computed is a URL the store will reject, and nothing at the call site
says so.

## Against ADR 0018's four axes

Nothing per request: a presigned URL reads two slices the Bucket already
holds. A Bucket under a store with a public endpoint holds one more host and
base — a hundred bytes, once, at `open`.

## Consequences

- `Posted.fields` opens with `bucket`.
- `s3.Options.public_endpoint`, `Store.public_scheme`, `Store.public_authority`,
  `Bucket.public_host`, `Bucket.public_base`.
- A `public_endpoint` that is not `scheme://host[:port]` is `error.BadEndpoint`
  at `open`, as the endpoint is.
