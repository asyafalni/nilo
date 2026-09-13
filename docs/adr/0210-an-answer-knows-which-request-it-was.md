# An answer knows which request it was

`testing.Answer.body` points into the client's one response buffer, and the
next request writes over it — the comment on `takeCookies` says as much, and
copies for that reason. `Answer.status` is a `u16` by value. So this:

```zig
const made = try w.send("POST", "/api/rabs", …);
try testing.expectEqual(201, made.status);        // true
_ = try w.send("POST", "/api/rabs", …);           // a 403, from somebody else
const id = try w.idOf(made);                       // reads the 403's body
```

fails as `error.MissingField` out of `std.json` three frames down, with
`made.status` still reading 201 on the line above. It cost twenty minutes.
The version that costs more is the assertion that *passes* because the second
body happened to carry the same key.

## A generation, copied into the answer

The client counts the requests it has answered. Each `Answer` carries the
number it was and a pointer to the count, and the three readers of the body —
`text`, `bytes`, `json` — refuse with `error.AnswerStale` when the two
disagree. An answer parsed with no client behind it carries no pointer and
reads whenever it is asked, since there is no next request for it to go stale
under.

The fields themselves — `raw`, `head`, `body` — still borrow. They are what
the buffer holds, and a test that reads them directly is reading the buffer
on purpose. `header`, `headerAt` and `setCookie` read `head` and still answer
`?[]const u8`: a `!?` on a hundred and sixty call sites was not the trade for
a trap the body readers now name, and a stale header reads as a missing one
rather than as a passing assertion.

## What was not done

**Copying every answer.** It is what the client was written not to do, and
`json` already copies what a test keeps. The counter keeps that, and costs
one integer per answer.

**Resetting the client's buffer between requests.** A zeroed buffer makes a
stale read fail as `error.NoHead` somewhere in `parse`, which is the same
three-frames-down failure with a different name.

## Against ADR 0018's four axes

Nothing on the server. The client is a test harness.

## Consequences

- `Client.made`, `Answer.made`, `Answer.counter`, `error.AnswerStale`.
- A test that reads a first answer's body after a second request on the same
  client, expecting the refusal, and reads the second's as before.
- A test in the port that read one answer's status and another's body fails
  on the line that did it, in a sentence.
