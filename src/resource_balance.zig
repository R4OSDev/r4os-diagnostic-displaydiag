const std = @import("std");
const r4os = @import("r4os");

// IRQ registrations and current work/deadline slots belong to the kernel,
// whereas R4GFX's library references are checked by its provider owner test.
// No cumulative IRQ/timer sample is used as a live-resource count.
pub const Runtime = struct {
    irqs: [256]u8 = @splat(0),
    irq_count: usize = 0,
    work: [12]u32 = @splat(0),

    pub fn capture(app: *r4os.App) ?Runtime {
        const dev = app.devicesLowLevel() orelse return null;
        const work = dev.performanceDriverWork(0) orelse return null;
        var value: Runtime = .{ .work = .{ work.used_slots, work.queued_slots, work.running_slots,
            work.completed_slots, work.cancelled_slots, work.irq_queued_slots, work.task_queued_slots,
            work.waiters_current, work.deadline_queued_slots, work.deadline_running_slots,
            work.queue_capacity, work.deadline_queue_capacity } };
        for (&value.irqs, 0..) |*registered, index| {
            const irq = dev.performanceIrqTiming(@intCast(index)) orelse break;
            registered.* = irq.registered;
            value.irq_count += 1;
        }
        return if (value.irq_count != 0) value else null;
    }

    pub fn balanced(before: Runtime, app: *r4os.App) bool {
        const sys = app.system();
        const limit = sys.ticks() +| sys.ticksFromMilliseconds(1000);
        while (true) {
            const after = capture(app) orelse return false;
            if (std.meta.eql(before, after)) {
                sys.println("DISPLAYD runtime balance: OK IRQ-registrations work-slots deadline-slots waiters");
                return true;
            }
            if (sys.ticks() >= limit) break;
            sys.sleepTicks(1);
        }
        sys.println("DISPLAYD runtime balance: FAILED IRQ/work/deadline counters did not return within 1000ms");
        return false;
    }
};

// These are current owner counters, not cumulative performance samples.
// Compare fields rather than ABI padding; a retained pin is a failed balance
// even when the public object/reference counts happen to match.
pub fn buffers(sys: *const r4os.r4sys.Context, before: r4os.abi.GfxBufferStats, after: r4os.abi.GfxBufferStats) bool {
    var passed = true;
    inline for (std.meta.fields(r4os.abi.GfxBufferStats)) |field| {
        if (comptime !std.mem.eql(u8, field.name, "reserved0")) {
            if (@field(before, field.name) != @field(after, field.name)) {
                sys.write("DISPLAYD resource balance: FAILED " ++ field.name ++ " before=");
                sys.printU64(@field(before, field.name));
                sys.write(" after=");
                sys.printU64(@field(after, field.name));
                sys.println("");
                passed = false;
            }
        }
    }
    return passed;
}
