# A call can skip the certificate check, and only that call

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Extends:** [ADR 267](./267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md), which lets a client trust a private authority and has no way to trust nobody for one call.

## Context

Every `https://` call verifies the chain and the name. For most calls that is the point. For an uptime or health check of an appliance on its factory certificate, or of an internal endpoint whose certificate expired, the question is "does it answer", and a client that cannot ask it reports the endpoint down for the wrong reason. Uptime Kuma ("Ignore TLS/SSL error"), Gatus (`insecure`), the Blackbox exporter (`insecure_skip_verify`), reqwest (`danger_accept_invalid_certs`) and `curl -k` all carry it, and photon (a monitor built on nilo) found it missing. `Settings.roots` does not reach it: the authority is unknown, differs per target, and often does not exist.

## Decision

**`Call.tls: Client.Tls = .verified`, and `Begin.tls` for a caller that drives an `Exchange`. `.unverified` makes that one call without checking the certificate chain or the name.** The enum has room for a later mode (a pinned fingerprint) without a second boolean.

**The field exists on a call and nowhere that can hold a default.** `Settings` has no `tls`, and neither `Target`'s `Options` nor its `Open`: the type does not have the field, so there is nothing to forget to check at run time, and a service called unverified says so on every call. A test holds it with `@hasField`. A private authority's service wants `Settings.roots`, which is the safe way to the same call.

**nilo dials an unverified connection itself**, as it does the proxy's tunnel ([ADR 276](./276-an-https-call-goes-through-a-proxy-in-a-tunnel-nilo-opens.md)): `Exchange.dialTls` lays out std's `Connection.Tls` and runs `std.crypto.tls.Client` with `.ca = .no_verification` and `.host = .no_verification`, directly or inside the `CONNECT` tunnel when `Settings.proxy` carries the host. std offers no way to ask for it on a connection it dials. The copy of the private layout is the one the tunnel already carries and is pinned the same way.

**An unverified connection is pooled under `!host`.** std's pool finds a connection by host, port and protocol and knows nothing of verification, so a connection opened unverified and released would be handed to the next verified call to the same host, which would then send its request over a channel nobody checked. The mark is part of the key: no valid hostname begins with `!`, so a verified lookup of `host` cannot match it, and an unverified lookup of `!host` cannot match a verified connection (reusing one would be harmless, and is not done, to keep the rule one line). The unverified calls to a host still share a connection with each other. A test calls unverified, then verified to the same host and port, and asserts the verified one dials and is refused and the pool still holds one connection; the pool's single node is named `!localhost`.

**An IPv6 literal is refused by name.** The pool key is a `HostName`, which an IPv6 literal is not, and std's TLS client takes the name for the handshake from the same option that switches the check off, so there is nothing to give it. `error.UnverifiedNeedsHostName` is returned before anything is dialled, where falling through to std would have verified the call it was told not to and failed. An IPv4 literal is a valid host name and is answered.

**A followed redirect keeps the permission at its origin, as the credentials stay at theirs** ([ADR 183](./183-a-redirect-is-a-decision-with-a-name.md)). Inside the origin the hops are unverified; past a change of scheme, host or port the next hop is `.verified` again, and a certificate there that the client does not trust ends the call with the usual error. A test follows `localhost` to `127.0.0.1` and sees the refusal.

**A verified call that fails on the certificate is `error.TlsInitializationFailed`, and the way out is named in the documentation of `Call.tls` and in the guide.** std collapses an unknown authority, a wrong name and an expired certificate into that one error before nilo sees it (read in `connectTcpOptions`, and held by a test), so the error cannot say which; it stays what it was, because callers match on it, and `nilo_fetch` logs nothing on a call, so there is no warn line to put the option in. A distinct error for the certificate cases would need nilo to run the handshake for every call, which is the dial this decision keeps to the calls that ask.

## What was rejected

- **A field on `Settings` or a `Target`.** The case is a per-call one (a monitor setting per endpoint), and a client-wide or target-wide switch is a default that one forgotten line turns into every call trusting whoever answers. A target would be natural for "this internal service has a bad certificate", and `Settings.roots` is the right answer there.
- **A boolean (`insecure_skip_verify: bool`).** Go's spelling, and a second boolean the day a fingerprint pin is wanted. An enum named for the trade is read in the call.
- **Not pooling an unverified connection.** Simpler to say and a handshake per call, which a monitor that checks every thirty seconds does not feel and a program checking a hundred endpoints a second does. The key costs nothing at run time and the separation is the same.
- **Marking the connection `closing` after the call.** std overwrites `closing` from each response's `connection` header, so the mark does not hold.
- **Verifying the chain but not the name, or the reverse.** The use case is neither half; either would be a second option with its own surprise.
- **Sending the server name.** `std.crypto.tls.Client` takes the name for the handshake and for the check from one option (`.host`), so skipping the check sends none. A host that picks its certificate by name answers with its default; for the "does it answer" question that is the usual answer. A split option in std would be the better place.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 on a verified call, which takes the path it took. An unverified call allocates one node per new connection, as a verified one does |
| Memory per idle connection | the node of a TLS connection, the same size, plus one byte of name; the handshake's stack is in a frame that is gone before the call parks (`dialTls`, not inlined) |
| Throughput and p99 | 0: one comparison of the call's `tls` in `pickConnection`; an unverified handshake skips the chain check and is cheaper |
| Binary size | the branch on `verify` in `dialTls` and `pickUnverified`; not separately measured, see the handoff |
