//! What a handler hands back to its connection instead of holding it.
//!
//! A suspended fiber holds its stack at its high-water mark, so a connection
//! that is going to wait for a long time waits from the connection loop's own
//! frame rather than from inside the request (ADR 062). Two things do that: a
//! Socket whose loop the handler named, and an event stream whose every
//! event comes from Rooms (ADR 227). Only one can be handed over per request,
//! so they share a slot.
//!
//! **`none` rather than an optional**, because the slot lives in the
//! connection loop's frame, which is the frame ADR 062 keeps under a page:
//! an optional of this union would carry a second tag beside the union's own,
//! padded to the Socket's sixteen-byte alignment, on every connection
//! whether it ever upgrades or not.
//!
//! **An event stream is handed over with its `run` as a pointer**, as a
//! Socket is with its loop: the connection loop names every variant, so a
//! direct call would link the stream's loop and the Room behind it into a
//! server that never calls `eventsFrom`. Called through the pointer, only the
//! handler that set it pays (ADR 017).

const stream_mod = @import("stream.zig");
const websocket = @import("websocket.zig");

pub const Handover = union(enum) {
    none,
    socket: websocket.Handover,
    events: Events,
};

pub const Events = struct {
    stream: stream_mod.RoomEvents,
    run: *const fn (*stream_mod.RoomEvents) void,
};
