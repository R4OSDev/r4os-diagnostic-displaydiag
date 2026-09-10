const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx_outputs");
const producer = @import("r4gfx_queue");
const a = r4os.abi;
const ok = a.gfx_output_ok;
const test_adapter: u32 = 0xffff0007;
var receiver: gfx.edid.Report = .{};
var raw: [a.gfx_output_max_edid_bytes]u8 = undefined;
fn check(sys: *const r4os.r4sys.Context, condition: bool, line: u32) bool {
    if (condition) return true;
    sys.write("DISPLAYD outputs FAILED line="); sys.printU64(line); sys.println("");
    return false;
}
fn find(ctx: *const r4os.gfx_outputs.Context, adapter: u32) ?a.GfxOutputInfo {
    for (0..a.gfx_output_capacity) |index| {
        var info: a.GfxOutputInfo = .{};
        if (ctx.info(@intCast(index), &info) == ok and info.identity.adapter_id == adapter) return info;
    }
    return null;
}
pub fn run(app: *r4os.App, native: bool) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const ctx = draw.outputs();
    const buffers = draw.buffers();
    var before: a.GfxBufferStats = .{}; var after: a.GfxBufferStats = .{};
    if (buffers.stats(&before) != ok) return 1;
    var passed = firmware(app, &ctx);
    if (passed and native) passed = hotplug(app, &ctx);
    passed = buffers.stats(&after) == ok and passed;
    passed = check(&sys, before.objects == after.objects and before.references == after.references and before.leases == after.leases and before.committed_bytes == after.committed_bytes, @src().line) and passed;
    sys.println(if (passed) "DISPLAYD outputs result: OK resources=balanced hardware-writes=none" else "DISPLAYD outputs result: FAILED");
    return if (passed) 0 else 1;
}
fn firmware(app: *r4os.App, ctx: *const r4os.gfx_outputs.Context) bool {
    const sys = app.system();
    const dev = app.devicesLowLevel() orelse return false;
    const draw = app.drawing() orelse return false;
    const info = find(ctx, 0) orelse return check(&sys, false, @src().line);
    var mode: a.GfxOutputMode = .{};
    if (!check(&sys, info.mode_count == 1 and info.connector_kind == a.gfx_output_kind_firmware and
        info.limits.flags == 0 and info.limits.rotations == 1 and ctx.mode(&info.identity, 0, &mode) == ok and
        mode.width == draw.screenWidth() and mode.height == draw.screenHeight() and mode.pixel_clock_hz == 0 and mode.refresh_millihz == 0, @src().line)) return false;
    var absent: a.GfxEdidBlock = .{ .block_index = 55 };
    const sentinel = absent;
    if (!check(&sys, ctx.edid(&info.identity, info.edid_bytes / 128, &absent) == 0 and std.meta.eql(sentinel, absent), @src().line)) return false;
    if (info.edid_bytes > 0) {
        gfx.readReceiver(ctx, &info, &raw, &receiver) catch return check(&sys, false, @src().line);
        sys.write("DISPLAYD outputs EDID: OK bytes="); sys.printU64(info.edid_bytes);
        sys.write(" extensions="); sys.printU64(receiver.valid_extensions); sys.putc('/'); sys.printU64(receiver.declared_extensions);
        sys.write(" warnings="); sys.printU64(receiver.warnings); sys.println(" source=firmware-snapshot");
    } else sys.println("DISPLAYD outputs EDID: unavailable source=firmware-snapshot");
    var state = a.GfxAtomicState{ .topology_revision = info.topology_revision, .count = 1 };
    state.assignments[0] = .{ .output = info.identity, .mode_id = mode.mode_id,
        .source_width = mode.width, .source_height = mode.height, .destination_width = mode.width, .destination_height = mode.height };
    var result: a.GfxAtomicResult = .{};
    if (!check(&sys, ctx.testState(&state, &result) == ok and result.outcome == a.gfx_output_outcome_validated, @src().line)) return false;
    const old = dev.displayState() orelse return false;
    const accepted = state;
    const untouched = result;
    state.assignments[0].plane_id = 32;
    if (!check(&sys, ctx.commit(&state, &result) == a.gfx_output_error_routing and std.meta.eql(untouched, result), @src().line)) return false;
    state = accepted; state.assignments[0].destination_width += 1;
    if (!check(&sys, ctx.testState(&state, &result) == a.gfx_output_error_invalid and std.meta.eql(untouched, result), @src().line)) return false;
    state = accepted; state.topology_revision -|= 1;
    if (!check(&sys, ctx.commit(&state, &result) == a.gfx_output_error_stale and std.meta.eql(untouched, result), @src().line)) return false;
    state = accepted; state.assignments[0].ready_fence = .{ .slot = 0xffff_ffff, .timeline = 3, .point = 7 };
    if (!check(&sys, ctx.testState(&state, &result) == a.gfx_output_error_invalid and std.meta.eql(untouched, result), @src().line)) return false;
    // An actual valid BO is still not a legal replacement for Limine scanout.
    const buffers = draw.buffers();
    var reference: a.GfxBufferReference = .{};
    var descriptor = a.GfxBufferDescriptor{ .byte_length = 4096, .width = 8, .height = 8, .format = a.gfx_buffer_format_xrgb8888,
        .plane_count = 1, .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_cpu_write };
    descriptor.plane_pitches[0] = 32;
    if (!check(&sys, buffers.create(&descriptor, &reference) == ok, @src().line)) return false;
    defer _ = buffers.release(&reference.reference);
    state = accepted; state.assignments[0].buffer = reference.reference;
    if (!check(&sys, ctx.commit(&state, &result) == a.gfx_output_error_unsupported and std.meta.eql(untouched, result), @src().line)) return false;
    const after = dev.displayState() orelse return false;
    if (!check(&sys, std.meta.eql(old, after), @src().line)) return false;
    state = accepted;
    if (!check(&sys, ctx.commit(&state, &result) == ok and result.outcome == a.gfx_output_outcome_applied and
        result.commit_sequence == untouched.commit_sequence + 1 and result.topology_revision > accepted.topology_revision and result.retained == 0, @src().line)) return false;
    if (!check(&sys, ctx.testState(&accepted, &result) == a.gfx_output_error_stale, @src().line)) return false;
    sys.println("DISPLAYD outputs atomic: OK rejected-before-device-change old-output=preserved boot-retain=applied refresh=unknown");
    return true;
}
fn barrier(sys: *const r4os.r4sys.Context, queue: *producer.Queue, result: *a.GfxFenceStatus) bool {
    if (queue.barrier((sys.monotonicNanoseconds() orelse 0) + 5_000_000_000, 0, &.{}, result) != a.gfx_queue_ok) return false;
    return true;
}
fn finish(sys: *const r4os.r4sys.Context, queue: *producer.Queue, result: *a.GfxFenceStatus, expected: u32) bool {
    const fence = result.fence;
    defer _ = queue.context.release(&fence);
    return queue.context.wait(&fence, sys.ticksFromMilliseconds(3000), a.gfx_queue_wait_resources_released, result) == a.gfx_queue_ok and result.result == expected;
}
fn hotplug(app: *r4os.App, ctx: *const r4os.gfx_outputs.Context) bool {
    const sys = app.system();
    const draw = app.drawing() orelse return false;
    const desk = app.desktop() orelse return false;
    const before = find(ctx, test_adapter) orelse return check(&sys, false, @src().line);
    if (!check(&sys, before.connector_kind == a.gfx_output_kind_virtual and before.edid_bytes == 256 and before.limits.flags == 0, @src().line)) return false;
    gfx.readReceiver(ctx, &before, &raw, &receiver) catch return check(&sys, false, @src().line);
    if (!check(&sys, receiver.complete(), @src().line)) return false;
    const queues = draw.queues();
    var binding: a.GfxBackendBinding = .{};
    for (0..a.gfx_queue_backend_capacity) |index| {
        if (queues.backend(@intCast(index), &binding) == a.gfx_queue_ok and binding.adapter_id == test_adapter) break;
    }
    if (!check(&sys, binding.adapter_id == test_adapter, @src().line)) return false;
    var queue = producer.Queue{ .context = queues };
    if (!check(&sys, queue.open(.{ .adapter_id = binding.adapter_id, .device_generation = binding.device_generation, .reset_generation = binding.reset_generation, .milestone = binding.milestone }) == a.gfx_queue_ok, @src().line)) return false;
    defer _ = queue.close();
    var sequence: u64 = 0;
    _ = desk.desktopActivityWait(0, 0, &sequence);
    const last = sequence;
    var result: a.GfxFenceStatus = .{};
    if (!check(&sys, barrier(&sys, &queue, &result), @src().line)) return false;
    if (!check(&sys, desk.desktopActivityWait(last, sys.ticksFromMilliseconds(1500), &sequence) == 1 and sequence != last, @src().line)) return false;
    if (!check(&sys, finish(&sys, &queue, &result, a.gfx_queue_result_complete), @src().line)) return false;
    const disconnected = find(ctx, test_adapter) orelse return false;
    if (!check(&sys, disconnected.identity.connector_id == before.identity.connector_id and disconnected.identity.connection_generation > before.identity.connection_generation and
        disconnected.flags & a.gfx_output_flag_connected == 0 and disconnected.mode_count == 0 and disconnected.edid_bytes == 0, @src().line)) return false;
    var stale: a.GfxOutputMode = .{ .width = 79 };
    if (!check(&sys, ctx.mode(&before.identity, 0, &stale) == a.gfx_output_error_stale and stale.width == 79, @src().line)) return false;
    if (!check(&sys, barrier(&sys, &queue, &result) and finish(&sys, &queue, &result, a.gfx_queue_result_complete), @src().line)) return false;
    const changed = find(ctx, test_adapter) orelse return false;
    if (!check(&sys, changed.identity.connection_generation > disconnected.identity.connection_generation and changed.edid_bytes == 128 and changed.mode_count > 0, @src().line)) return false;
    gfx.readReceiver(ctx, &changed, &raw, &receiver) catch return check(&sys, false, @src().line);
    if (!check(&sys, !receiver.complete() and receiver.warnings & gfx.edid.Warning.missing != 0 and receiver.audio_count == 0, @src().line)) return false;
    if (!check(&sys, ctx.mode(&disconnected.identity, 0, &stale) == a.gfx_output_error_stale, @src().line)) return false;
    if (!check(&sys, barrier(&sys, &queue, &result) and finish(&sys, &queue, &result, a.gfx_queue_result_device_lost), @src().line)) return false;
    const deadline = sys.ticks() + sys.ticksFromMilliseconds(1000);
    var reset = find(ctx, test_adapter) orelse return false;
    while (reset.edid_bytes == 0 and sys.ticks() < deadline) {
        sys.sleepTicks(1);
        reset = find(ctx, test_adapter) orelse return false;
    }
    if (!check(&sys, reset.identity.connection_generation > changed.identity.connection_generation and reset.edid_bytes == 256 and
        ctx.mode(&changed.identity, 0, &stale) == a.gfx_output_error_stale, @src().line)) return false;
    sys.println("DISPLAYD outputs hotplug: OK desktop-wait=woken disconnect=empty replug=new-generation reset=invalidated stale=untouched");
    return true;
}
