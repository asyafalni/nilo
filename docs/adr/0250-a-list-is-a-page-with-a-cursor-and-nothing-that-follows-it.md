# 0250 — a list is a page with a cursor, and nothing that follows it

**Status:** accepted
**Extends:** [ADR 0067](./0067-most-of-an-s3-client-is-not-s3.md), whose
"what it will not do" loses one of three.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0068](./0068-a-bucket-is-a-type-and-a-key-is-not.md).

## Context

`nilo_s3` shipped without `LIST` on purpose, and the reason was recorded:
a list result is XML and a type AWS wrote rather than one the caller did,
which is the opposite of what every other call in the module handles, and
the one call with unbounded output — a helper that walks a bucket is a
helper that invites treating a bucket as a database. The roadmap held the
gap at *waiting on a caller*.

The caller arrived as a shape rather than a name: a durable tier with a
retention policy. An object unlinked from the hot copy has to be deleted
from the durable one, and `delete` ships; but after a crash or a partial
upload, the only way to learn what actually landed is to ask the bucket,
and without `list` the durable replica grows forever and cannot be
reconciled. A 64,000-line observability platform weighing a move onto nilo
counted 24 call sites for it. `get`, `put`, `range` and `presign` are
enough to *write* to an object store; they are not enough to *own* one.

## Decision

**`bucket.list(c, .{ .prefix, .max_keys, .cursor })` answers one page —
`objects` and `next` — and nothing here follows `next` for the caller.**
The shape is what keeps the two objections true while closing the gap:

- **One page, bounded three ways.** At most `max_keys` objects and at most
  `keys_max` (1,000, S3's own ceiling); a number over it is
  `error.Rejected` rather than clamped, because the caller sized their
  loop and their arena by what they asked for and a server quietly
  answering fewer leaves a loop that never learns it was capped. The body
  is read into the Scope up to a ceiling derived from `max_keys` and the
  bucket's `key_max` — a fixed frame plus, per object, the tags, a date,
  an ETag, a size and a key at three bytes a character — so a server
  answering more than the question is `error.TooLarge` rather than an
  arena it fills. And the cursor is handed back as text: there is no
  `listAll`, no iterator that dials again, no callback per page. The loop
  is the caller's, and it is the six lines in the guide.
- **Five names, scanned for.** `code.zig` had already found that an S3
  error body is a scan for `<Code>` and `<Message>` rather than a parser,
  and a `ListObjectsV2` result is the same thing with five names: `<Key>`,
  `<Size>`, `<ETag>`, `<LastModified>` inside each `<Contents>`, and
  `<IsTruncated>` beside `<NextContinuationToken>` outside them. No tree
  is built, no namespace or attribute is read, and anything else the
  server says is stepped over. `s3/listing.zig` is the file that holds
  the XML, so that `bucket.zig` still holds none.
- **Two encodings, each handled where it arises.** The request asks for
  `encoding-type=url`, so a key comes back percent-encoded and is decoded
  by Core's `percent` — the same coding it was written with on the way
  out, and a well-defined one. Without it a key with an `&` in it would
  make every key an XML-entity problem. An ETag is not covered by that
  and arrives as `&quot;…&quot;`, so the five entities XML predefines are
  unescaped for it and for the cursor, and for nothing else. A reference
  that is not one of the five is left as the bytes it was, for the reason
  `percent.decode` leaves a broken escape: a value that fails to decode
  is still a value, and refusing it would refuse the page.
- **The query is canonical by construction.** SigV4 signs the query
  string sorted by name and encoded, and the same bytes have to go on the
  wire. `listing.query` writes the five parameters in alphabetical order
  from a fixed list — `continuation-token`, `encoding-type`, `list-type`,
  `max-keys`, `prefix` — rather than sorting at run time, for the reason
  `SignedHeaders` is a walk rather than a sort, and `Prepare` gained a
  `query` field that `sign.Request` had been waiting for since the
  presigned URL. The canned server checks the signature over the query
  as it arrived, which is what holds the two spellings to one.

`Listed.etag` comes back quoted, the way `head` and `get` hand it back, so
a value from a page goes into `getIf` as it is. `last_modified` stays the
server's text — every caller compares or prints it, and `sql.Timestamp`
reads it for the one who wants arithmetic.

## What it costs

Against ADR 0018's axes, for the route that calls it and no other:

- **Allocations per call:** two in the Scope — the body and the page —
  plus one per key and one per ETag for the decoding. The body is
  `Exchange.take`'s one allocation; the page is sized by a count made
  before it is allocated, so it is exact.
- **Stack per connection:** one URL buffer of `list_url_max` bytes, with
  the query written in place after the `?` so there is no second buffer
  for it. For the default `key_max` of 512 that is about 5 KB, of which
  3 KB is the cursor at three bytes a character — `cursor_max` of 1,024
  is a ceiling on what a server hands out — and a program with a
  `key_max` of 128 pays about 3.9 KB. A handler that lists pays this on
  its connection's stack for the life of the connection (ADR 0063),
  which is why it sits here and not in an always-allocated buffer on the
  Store, where every connection would pay it.
- **Binary size:** `listing.zig` and `list`, linked only by a program
  that names them.

## Alternatives

**Following the cursor inside the call**, as an iterator or a callback.
Refused, and it is the whole of what "bounded" means here: the one call
with unbounded output would be back, and it is the shape that turns a
bucket into a table. Six lines in the caller's program are the price of
keeping the module's answer to "how much can this return" a number.

**Reading the XML with a parser.** There is none in std, and a
dependency for five names would be the first dependency `nilo_s3` has
that `nilo_fetch` does not. A fixed, flat document is a scan.

**Leaving the key as XML text and unescaping it.** Works, and puts every
key with an `&`, `<` or `>` through an unescape that has to be right
about five entities and silent about the rest. `encoding-type=url` puts
the key through a decoder the module already owns and tests.

**`start-after` instead of `continuation-token`.** A key rather than an
opaque token, which reads nicer in a log and is what V1 offered. The
token is what V2 hands back on a truncated page, it is what every
implementation optimises for, and making the caller reach for the last
key of a page to build the next request is the loop written wrong once
per program. The cursor is opaque and goes back as it came.

**Clamping `max_keys` to 1,000.** What S3 does, and what the guide would
then have to warn about: a loop asking for 5,000 and sized for it gets a
thousand and no signal. A refusal is one line and one round trip saved.

## Consequences

- `s3/listing.zig`: `Listing`, `query`, `queryMax`, `Objects`,
  `nextCursor`, `unescapeInto`, and their tests.
- `Bucket.list`, `s3.Listing`, `s3.Listed`, `s3.Page`; `Prepare.query`
  threaded into `sign.authorize`; `list_url_max` beside `url_max`.
- Two canned tests — two pages on one connection with the signature
  checked over the query as received, and the four refusals before a
  socket — and one live test against whatever `S3_ENDPOINT` names.
- The module header, the guide and the README say `COPY` and multipart
  rather than three; `docs/roadmap.md` loses the entry.
- `Multipart` and `COPY` are unchanged and still waiting on a caller.
