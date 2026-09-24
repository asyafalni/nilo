# Request input

**A request's arguments are read from wherever they arrived, converted by one grammar, and their failures handed back rather than dropped after the first.** How to use each piece is the guide ([`guide/requests.md`](../guide/requests.md), [`guide/forms.md`](../guide/forms.md)); every name and signature is the reference ([`reference/handlers.md#handler-arguments`](../reference/handlers.md#handler-arguments), [`reference/ctx.md#reading`](../reference/ctx.md#reading)). The code is `http/convert.zig` (`tryConvert`, `Reason`, `Slot`), `http/typed.zig` (`Query`, `FromHeader`, the argument loop), `http/bound.zig` (`Bound`, `Checked`, `must`, `nilo_check`), `http/form.zig` (`Form`, `Upload`, the list collectors), `http/patch.zig`, `http/within.zig`, `http/text.zig`, `http/authorization.zig`, `http/maxbody.zig`, `http/ctx.zig` (`header`, `headers`, `query`, `queries`, `host`, `scheme`, `body`), and `core/str.zig` (`Str.blank`, `Str.trimmed`).

## How the pieces fit

```
  path param      Query(T)          Form(T)           JSON body
  (positional)    ?a=1&b=2      urlencoded/multipart     {..}
       \              |               |                   |
        `------------ convert.tryConvert / nilo_parse ----'
                (Reason: .missing .not_a_number .not_true_or_false
                         .not_a_choice .wrong_kind .not_that_type)
                              |
              plain argument: the first bad field is the request's 400
                              |
                    Bound(W): every field, .value() or .fail()
                              |
              nilo_check(self, *Rules(T)): a rule about the whole struct
                              |
                           handler
```

A header and an authentication scheme sit beside this rather than inside it: `FromHeader(name, T)` and `Authorization(scheme)` are typed arguments read by the same `convert`, but each is refused on its own, before a `Bound` around it would help, and `Authorization`'s refusal is a 401 with a challenge rather than a 400. `c.headers()`, `c.queries()`, `c.host()` and `c.scheme()` are the way past all of this for a middleware that does not know the names in advance. The body's own arrival is bounded twice: `max_body`, per route or from `listen()`'s default, before a byte is read, and `readSizedBody`'s page-at-a-time commit while it is.

## The rule in force

1. **The query string arrives as a struct of your own, wrapped in `Query(T)`.** Field names are the query names, a default is what "absent" means, and conversion and its messages are shared with a path param. [ADR 011](../adr/011-the-query-string-is-a-struct-of-your-own.md)
2. **`Form(T)` is the body, read by the same rules as `Query(T)`, whichever encoding a browser used to send it.** A checkbox posts `on` rather than `true`/`false`, and only a form field reads it that way; a file field arrives as an `Upload`, three `Str`s (bytes, filename, content type) held whole and unmoved inside the request arena. [ADR 030](../adr/030-a-form-is-the-body-read-by-another-rule.md), [ADR 071](../adr/071-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md)
3. **A `PATCH` body needs three answers where an optional has two.** `Patch(T)` tells "not sent" (`.absent`), "sent as null" (`.cleared`) and "sent with a value" apart. [ADR 025](../adr/025-a-patch-needs-three-answers-and-an-optional-has-two.md)
4. **Text becomes a number by one grammar, not by Zig's**, digits with a leading `-` only where the type has one; a type that wants to read itself instead declares `nilo_parse(text) ?Self` and is read the same way anywhere a value converts from text: a path param, a `Query(T)` field, a `Form(T)` field. [ADR 084](../adr/084-a-number-in-a-request-is-not-a-zig-literal.md), [ADR 113](../adr/113-a-path-param-can-parse-itself.md)
5. **A type that writes a format can read it back.** `sql.Timestamp.nilo_parse` is the inverse of its own RFC 3339 writer, wider than what it prints (any offset, fractional seconds) and narrower in one place (no zoneless time, no leap second), because a parser that disagreed with its writer would move a cursor silently. [ADR 127](../adr/127-what-a-server-prints-it-can-read.md)
6. **A whole number inside a range is a type, `Within(min, max)`**, the narrowest integer that fits, refusing outside the range with the same null a bad number gets and writing `minimum`/`maximum` into the document. [ADR 167](../adr/167-a-whole-number-inside-a-range-is-a-type.md)
7. **Text with a shape is a type too, `Text(.{ .min, .max, .check, .said })` with `Email` and `Url` as presets**, and a rule about the whole struct, not one field, is a function on it: `nilo_check(self, *Rules(T))`, run once every field has bound. [ADR 193](../adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)
8. **A binding hands its failures to the handler instead of stopping at the first one.** `Bound(Query(T))`, `Bound(Form(T))` and `Bound(T)` for a JSON body give `value()` as `?T`, `given(name)` for what was typed, and `must(field, ok, "…")` to add the application's own sentence to the same 422. [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md)
9. **A header or an authentication scheme a handler needs is a typed argument, not a lookup inside the body.** `FromHeader(name, T)` reads one header the way `Query(T)` reads a field; `Authorization(.bearer)` or `Authorization(.{ .basic = … })` refuses with the right `WWW-Authenticate` before the handler runs; `app.guard(middleware, cookie)` puts a declared session cookie into the document on the trust a self-describing type is already given. [ADR 131](../adr/131-a-header-a-handler-can-be-given.md), [ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md)
10. **Everything past what a handler names by argument stays reachable, without touching an underscore field.** `c.headers()` walks every header in arrival order as `Str` name and value; `c.queries()` and `c.queryString()` do the same for the query string; `c.host()` and `c.scheme()` read `X-Forwarded-*` only when `listen(.{ .trusted_hops = … })` says to trust them. [ADR 085](../adr/085-every-header-without-handing-out-the-head.md), [ADR 090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md)
11. **A query or form field that is a slice is a list, filled from every value under its name.** The query reads both `?tag=a,b` and `?tag=a&tag=b` and writes the comma form in the document; a form reads only the repeated name, because that is the one spelling a browser sends. [ADR 132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)
12. **A body is committed only once the client has actually delivered a page of it**, not from the `Content-Length` a stranger typed: `readSizedBody` takes 4 KiB first and grows from there. [ADR 083](../adr/083-a-body-is-taken-as-it-arrives.md)
13. **A route can say how much body it takes.** `app.with(nilo.maxBody(n))` sets a ceiling narrower or wider than `listen()`'s default for one route, checked before a byte is read; `c.bodyStream()` answers a different question and keeps its own `max_bytes`. [ADR 156](../adr/156-a-route-can-say-how-much-body-it-takes.md)
14. **Required text is checked for more than emptiness.** `Str.blank()` says whether there is nothing but whitespace and `Str.trimmed()` borrows the middle, both against `std.ascii.whitespace` rather than a charset written out again at every call site. [ADR 142](../adr/142-required-text-arrives-as-two-spaces.md)

## Decisions

| ADR | What it decides |
|---|---|
| [011](../adr/011-the-query-string-is-a-struct-of-your-own.md) | The query string is a struct of your own, `Query(T)`, sharing conversions with a path param |
| [025](../adr/025-a-patch-needs-three-answers-and-an-optional-has-two.md) | `Patch(T)`: a PATCH body tells "not sent", "sent as null" and "sent with a value" apart |
| [030](../adr/030-a-form-is-the-body-read-by-another-rule.md) | `Form(T)` is the body read by another rule; `Upload` is three `Str`s held whole in the arena |
| [034](../adr/034-a-binding-hands-its-failures-to-the-handler.md) | `Bound(W)` hands every field's failure to the handler, and `must` adds the application's own sentence |
| [071](../adr/071-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md) | A checkbox posts `on`, and only a form field reads it that way |
| [083](../adr/083-a-body-is-taken-as-it-arrives.md) | `readSizedBody` commits the announced length only once the client has delivered a page of it |
| [084](../adr/084-a-number-in-a-request-is-not-a-zig-literal.md) | A number in request text follows a digits grammar, not Zig's literal grammar |
| [085](../adr/085-every-header-without-handing-out-the-head.md) | `c.headers()` iterates every header in arrival order without exporting the head |
| [090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md) | `c.queries()`, `c.queryString()`, `c.host()` and `c.scheme()` read past what a handler names |
| [113](../adr/113-a-path-param-can-parse-itself.md) | A type declares `nilo_parse` and is read anywhere a path param, query or form field is |
| [127](../adr/127-what-a-server-prints-it-can-read.md) | `sql.Timestamp.nilo_parse` is the inverse of its own RFC 3339 writer |
| [131](../adr/131-a-header-a-handler-can-be-given.md) | `FromHeader(name, T)`: a header a handler can be given as a typed argument |
| [132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md) | A query or form field that is a slice is a list, filled from every value under its name |
| [142](../adr/142-required-text-arrives-as-two-spaces.md) | `Str.blank()` and `Str.trimmed()`: required text is checked for more than emptiness |
| [153](../adr/153-an-authorization-header-a-handler-can-ask-for.md) | `Authorization(scheme)` and `app.guard(middleware, cookie)`: a typed auth header and a documented cookie |
| [156](../adr/156-a-route-can-say-how-much-body-it-takes.md) | A route sets its own body-size ceiling with `nilo.maxBody(n)`, over `listen()`'s default |
| [167](../adr/167-a-whole-number-inside-a-range-is-a-type.md) | `Within(min, max)`: a whole number inside a range is a type |
| [193](../adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md) | `Text`/`Email`/`Url` are shaped text, and `nilo_check` puts a whole-struct rule on the struct |

Beside this topic: why a header's name and value are `Str` rather than `[]const u8` is [ADR 003](../adr/003-request-arena-and-the-str-type.md) (the request head is usually borrowed, not copied); the JSON half of a type reading itself is [ADR 166](../adr/166-a-body-field-that-parses-itself.md); what the cookie behind `app.guard` is sealed into is [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md).

## Open

- **Multipart is read whole, never streamed.** `Form(T)` bounds an upload by `max_body`, right for a photo and wrong for a 2 GB video; a streaming version needs a parser that resumes across reads and an `Upload` that is a reader rather than bytes. On record in [the roadmap](../roadmap.md#known-waiting-for-a-caller), tied to [ADR 030](../adr/030-a-form-is-the-body-read-by-another-rule.md).
- **Whether a request carries a CSRF token nilo knows about.** A session cookie's `SameSite=Lax` covers the ordinary cross-site POST; a `SameSite=None` cookie, a state-changing `GET`, and a browser old enough not to enforce Lax are not. On record in [the roadmap](../roadmap.md#open-questions) under `nilo_http`.
