# Services

**A service is a long-lived thing (a database connection, config, a logger) registered once when the App is built, then asked for by handlers by its type.**

**Reference:** [`app.provide`](../reference/app.md#app), [`nilo.blocking` and `nilo.Mutex`](../reference/app.md#concurrency) · **Design:** [Lifecycle](../design/lifecycle.md), [Memory](../design/memory.md)

```zig
var db = try Db.open("app.sqlite");
try app.provide(&db);

fn getUser(db: *Db, id: u32) !User { … }   // matched by type, no name anywhere
```

## Registering a service

**Registration order doesn't matter, and a service nobody asks for costs nothing.** A service a handler asks for that nobody registered stops `listen()` before the socket opens:

```
error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()
```

`*const Config` and `*Config` are different types and are looked up separately, so a read-only service can say so. From a handler that took no typed arguments, or from middleware, `c.service(*Db)` does the same lookup.

The App is a service like any other (`try app.provide(&app)`), which is how an admin endpoint gets at `app.shutdown()`.

See [ADR 005](../adr/005-services-via-a-runtime-registry.md).

## Locking a shared service

**Handlers run at the same time on several OS threads, so a service that gets written to needs a lock, and it has to be `nilo.Mutex`, not `std.Thread.Mutex`.** A service you only read from is fine as it is. `std.Thread.Mutex` blocks the whole thread and every other request being served on it:

```zig
const Store = struct {
    lock: nilo.Mutex = .init,
    users: std.ArrayList(User) = .empty,
};

fn addUser(store: *Store, incoming: NewUser) !User {
    try store.lock.lock();
    defer store.lock.unlock();
    ...
}
```

`lock()` can fail with `error.Canceled` if the request went away while waiting, and that already maps to a 503. It also works with no server running, so a handler that takes the lock can still be tested as a plain function. See [ADR 010](../adr/010-shared-services-need-a-lock-from-the-bulkhead.md).

## Storing request text in a service

**A service must copy request text before storing it.** This is the first problem most people coming from Go or Node hit, and it is worth spelling out because the compiler will not catch it.

Text from a request is a [`Str`](./handlers.md#request-text-str), and it points into memory that is thrown away when the request ends. A service outlives the request. So this compiles, passes every test you write for it, and serves the *next* request's bytes to the one that asked:

```zig
fn addTodo(store: *Store, incoming: NewTodo) !Todo {
    const todo = Todo{ .id = store.next_id, .title = incoming.title };  // ✗
    try store.todos.append(store.gpa, todo);
    …
}
```

In a debug build nilo panics on the read instead, and names the request that did it. The fix is to copy:

```zig
const Store = struct {
    gpa: std.mem.Allocator,
    lock: nilo.Mutex = .init,
    todos: std.ArrayList(Todo) = .empty,

    /// Everything a Todo owns, freed in one place. Worth having even for one
    /// string: the day a `due` is added, this is the only function to change.
    fn free(self: *Store, todo: Todo) void {
        self.gpa.free(todo.title);
    }

    fn deinit(self: *Store) void {
        for (self.todos.items) |t| self.free(t);
        self.todos.deinit(self.gpa);
    }

    fn add(self: *Store, title: []const u8) !Todo {
        try self.lock.lock();
        defer self.lock.unlock();
        // The copy, and the whole of the rule: the store owns its strings.
        const todo = Todo{ .id = self.next_id, .title = try self.gpa.dupe(u8, title) };
        try self.todos.append(self.gpa, todo);
        self.next_id += 1;
        return todo;
    }
};

fn addTodo(store: *Store, incoming: NewTodo) !Todo {
    return store.add(incoming.title.view());   // ✓ view() to read, add() copies
}
```

Two habits cover the rest:

- **The service takes `[]const u8`, not `Str`.** `Str` is a request type, and a service that never names it cannot store one by accident. The handler calls `.view()` at the boundary, the one line where the lifetime matters. `.keep(gpa)` makes the same copy when a handler does it itself.
- **One `free` per stored type, called from `deinit` and from every replace and remove.** When replacing a row, allocate the new string *before* freeing the old one, so a failed allocation leaves the row as it was instead of pointing at freed memory.

None of this is specific to nilo: it is what owning memory costs in Zig, and a real part of the work in a CRUD app in this language. What nilo adds is that getting it wrong fails on your laptop, not in production.

### One arena per row

**When a row holds nested text, give each row its own arena**, so freeing it is one call that stays correct when the type changes. A `free` per stored type stops scaling once a row holds a customer, an address and a list of lines, each with text of its own:

```zig
const Row = struct { memory: std.heap.ArenaAllocator, order: Order };

fn place(self: *Orders, incoming: NewOrder) !Order {
    const row = try self.gpa.create(Row);
    row.* = .{ .memory = .init(self.gpa), .order = undefined };
    errdefer row.memory.deinit();

    const mine = row.memory.allocator();
    row.order = .{ .customer = try keepCustomer(mine, incoming.customer), … };
    …
}

fn drop(self: *Orders, row: *Row) void {
    row.memory.deinit();       // the customer, the address, every line
    self.gpa.destroy(row);
}
```

Hold the rows **by pointer**, not by value: if an `ArenaAllocator` moves when the list grows, any `allocator()` handle taken from it points at where the arena used to be.

### Returning text a service owns

**A read returns a copy in the request arena, not a view into the store.** A handler returns to nilo, and nilo writes the response *after* it returns. In between, another request on another thread can delete that row and free the text the response is about to be written from:

```zig
fn get(self: *Orders, into: std.mem.Allocator, id: u32) !?Order {
    try self.lock.lock();
    defer self.lock.unlock();
    const row = self.rowFor(id) orelse return null;
    return try copyOut(into, row.order);   // under the lock, into the request
}
```

It costs one walk of a structure that is about to be walked again anyway, and the copy is thrown away with the request. A store that nothing ever deletes from does not need it, but "nothing ever deletes from it" can stop being true without anyone noticing.

[`examples/orders`](../../examples/orders/main.zig) does all of this on a domain with lines, an address and a customer.

### Converting deeply nested types

**Past two levels of nesting, write the converter once, using reflection.** Count the walks: a service takes `[]const u8` and a handler has `Str`, so something converts on the way **in**. A row that owns its text copies on the way in as well. A read returns a copy in the request arena, so something walks it on the way **out**. That is three walks of one shape. `orders` writes all three by hand, because at that size hand-written is clearer.

That stops being true quickly. A document with an optional `meta`, a list of `sections` each holding a list of `lines`, and a list of `tags` needs three hand-written recursive walks, and those are three places to forget the field somebody adds next month, silently, with the compiler agreeing.

```zig
/// `source` walked into `Target`, borrowing its text or copying it.
fn into(comptime Target: type, gpa: std.mem.Allocator, source: anytype, own: enum { borrow, own }) !Target
```

It is one function over `@typeInfo`, about a hundred lines with comments, and it covers every field because it never names one. nilo does not ship it, on purpose: a converter that walks *your* types has to decide what "the same shape" means (whether a null `?T` is a field at all, what happens to a `Str` inside a union), and shipping it would mean owning those decisions in every future version. Yours can just decide.

The point of this section is to notice when you need it, which is the hard part. The application that went looking for it had already written its fourth `dupe` loop.

## Handlers must not block

**Many requests share one OS thread, so a handler that waits stops all of them.** `nilo.Mutex` is one case of this rule. It is not just the waiting request that stalls: every other request on that thread does too, including ones with no work left to do.

It is easy to measure. One handler sits in `nanosleep` for two seconds, and a second request asks for a route that does nothing:

```
$ curl localhost:8787/slow &        # 2 seconds of blocking
$ curl -w '%{time_total}\n' localhost:8787/
1.701                               # ...paid by a request that had nothing to wait for
```

The fix is [`nilo.blocking`](../reference/app.md#concurrency), which hands the call to a pool of real threads and parks only this request:

```zig
fn getUser(db: *Db, id: u32) !User {
    return nilo.blocking(Db.query, .{ db, id });   // instead of db.query(id)
}
```

It takes the same arguments and returns the same value, errors included. It allocates nothing, and outside a running server it just calls the function, so the handler is still an ordinary function a test can call.

### What needs wrapping

| | |
|---|---|
| a database driver: `libpq`, SQLite, a socket you opened yourself | `nilo.blocking` |
| `std.fs`: reading or writing a file | `nilo.blocking` |
| `std.http.Client`, or any call out to another service | `nilo.blocking` |
| a `std.Thread.Mutex`, semaphore, or channel from `std` | `nilo.Mutex` |
| sleeping, backing off, waiting out a rate limit | `try nilo.sleep(ms)` |

Pure computation does not need it: parsing, JSON, a hash, a loop over a slice. Those *use* the thread, they do not wait on it. A long computation is a different problem, and `nilo.blocking` handles that too.

`nilo.sleep` takes milliseconds and fails with `error.Canceled` if the request went away while waiting, the same way `Mutex.lock` does.

### The blocking warning

**A handler that blocks its thread is reported in the log, on the first request.** Nothing *forces* you to wrap a call: Zig has no way to mark a function as blocking, so a handler that calls the driver directly still compiles and still passes its tests. But it does not go unnoticed. The server times each handler, minus the time it spent legitimately waiting, and says so:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 013).
```

The useful part is *when*: on the first request, with nobody else on the server. That is what makes this bug hard. One `curl` against a handler that queries the database synchronously gives the right answer at the right speed, and looks correct in every way you can check. It only misbehaves once there is a second request, which usually means production.

The default threshold is a quarter of a second. `listen(.{ .block_warning_ms = … })` changes it and `0` turns it off. A handler that keeps doing it is logged once a second with a count of the rest, not once per request.

It measures the longest stretch the fiber ran **without parking**, not the total. That is what lets it watch a handler that never returns: a stream, a body reader and a WebSocket used to be excused entirely, because a total has no upper bound on a connection that stays open for an hour. One stretch means the same thing on a request that lasts a millisecond and on a connection that lasts a day, so a blocking call inside a WebSocket loop is now reported. That is where the mistake costs the most, since a stalled fiber there holds its executor against every other socket that executor serves ([ADR 013](../adr/013-handlers-must-not-block-the-thread.md)).

A handler that yields every 30ms is not holding its thread, however long the request takes overall, and is not reported.

See [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) for the rule and what enforces it.
