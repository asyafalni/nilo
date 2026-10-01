//! A day that no month it names has. The 31st of February passes every
//! per-field range check and would leave a worker looking for a next tick
//! that does not exist; read while compiling, it is refused with both fields
//! named (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = job.cron("0 0 31 2 *");
}
