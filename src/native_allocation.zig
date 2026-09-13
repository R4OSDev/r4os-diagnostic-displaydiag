//! Common kernel/R4D path under the opt-in EXAMPLE synthetic provider.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub fn run(app: *r4os.App) bool {
    const sys = app.system();
    if (!@import("buffers.zig").logContains(&sys, "EXAMPLE.R4D gfx-allocation: ready synthetic-backing no-GPU")) return true;
    sys.println("EXAMPLE.R4D gfx-allocation: ready synthetic-backing no-GPU");
    const buffers = (app.drawing() orelse return false).buffers();
    const passed = exercise(&sys, &buffers);
    sys.println(if (passed) "DISPLAYD native-allocation: OK driver-work wait transfer stale=denied failed-output=unchanged synthetic-no-GPU" else "DISPLAYD native-allocation: FAILED");
    return passed;
}
fn exercise(sys: *const r4os.r4sys.Context, memory: *const r4os.gfx_buffers.Context) bool {
    const deadline = (sys.monotonicNanoseconds() orelse return false) + 3_000_000_000;
    var input: a.GfxNativeAllocation = .{ .adapter_id = 0xffff, .memory_generation = 0x079190002, .deadline_ns = deadline, .kind = 1, .width = 5, .height = 3, .format = a.gfx_buffer_format_xrgb8888, .usage = 28 };
    var status: a.GfxNativeStatus = .{ .result = 77 };
    const unchanged = status;
    if (memory.nativeStart(&input, &status) != a.gfx_buffer_error_stale or !std.meta.eql(status, unchanged)) return false;
    input.memory_generation -= 1;
    if (memory.nativeStart(&input, &status) != 1) return false;
    var request = status.request;
    defer if (request.id != 0) {
        _ = memory.nativeClose(&request);
    };
    if (memory.nativeWait(&request, sys.ticksFromMilliseconds(2000), &status) != 1 or status.phase != 2 or status.result != 1) return false;
    var reference: a.GfxBufferReference = .{};
    if (memory.nativeReceive(&request, &reference) != 1) return false;
    if (memory.nativeQuery(&request, &status) >= 0) return false;
    request = .{};
    defer if (reference.reference.id != 0) {
        _ = memory.release(&reference.reference);
    };
    var descriptor: a.GfxBufferDescriptor = .{};
    if (memory.describe(&reference.reference, &descriptor) != 1 or descriptor.location != 1 or descriptor.adapter_id != input.adapter_id or
        descriptor.device_generation != input.memory_generation or descriptor.driver_owner == 0 or descriptor.byte_length != 65536 or
        descriptor.plane_pitches[0] != 256 or descriptor.width != 5 or descriptor.height != 3) return false;
    var map: a.GfxBufferMap = .{};
    if (memory.map(&reference.reference, 0, 0, 1, &map) != a.gfx_buffer_error_unsupported) return false;
    var imported: a.GfxBufferReference = .{};
    if (memory.import(&reference.reference, &imported) != 1 or memory.release(&reference.reference) != 1) return false;
    reference = imported;
    if (memory.describe(&reference.reference, &descriptor) != 1 or memory.release(&reference.reference) != 1) return false;
    reference = .{};
    // A rejected format exercises failure completion and lets the provider
    // collect the previously released synthetic native backing.
    input.format = a.gfx_buffer_format_r8;
    if (memory.nativeStart(&input, &status) != 1) return false;
    request = status.request;
    if (memory.nativeWait(&request, sys.ticksFromMilliseconds(2000), &status) != 1 or status.result != a.gfx_buffer_error_unsupported) return false;
    reference.flags = 79;
    const before = reference;
    if (memory.nativeReceive(&request, &reference) != a.gfx_buffer_error_unsupported or !std.meta.eql(reference, before)) return false;
    return true;
}
