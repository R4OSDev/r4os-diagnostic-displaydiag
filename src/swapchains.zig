//! Explicit, bounded display-writing probe. The generic provider and real
//! software/Virtio presentation path perform the work; timers prove nothing.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const a = r4os.abi;

pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const client = gfx.DeviceV1Client.init(app.startContext()) catch {
        sys.println("DISPLAYD swapchain: FAILED DEVICE_V1 revision8 required"); return 1;
    };
    const allocator = sys.allocator();
    const size = client.storage_size();
    if (size == 0 or size > std.math.maxInt(usize)) return 1;
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(size)) catch return 1;
    @memset(storage, 0);
    var device: gfx.R4GfxDevice = undefined;
    if (client.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
        .storage_bytes = size, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = gfx.device_software_only }, &device) != gfx.status_ok) {
        allocator.free(storage); return 1;
    }
    const passed = exercise(&sys, &client, &device);
    const deadline = (sys.monotonicNanoseconds() orelse 0) +| std.time.ns_per_s;
    while (client.device_close(&device) != gfx.status_ok) {
        if ((sys.monotonicNanoseconds() orelse deadline) >= deadline) {
            sys.println("DISPLAYD swapchain: FAILED retained resources"); return 1;
        }
        sys.sleepTicks(1);
    }
    allocator.free(storage);
    sys.println(if (passed) "DISPLAYD swapchain: OK" else "DISPLAYD swapchain: FAILED");
    return if (passed) 0 else 1;
}
fn descriptor(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1; value.size = @sizeOf(gfx.R4GfxResourceDesc); value.kind = kind;
    return value;
}
fn exercise(sys: *const r4os.r4sys.Context, client: *const gfx.DeviceV1Client, device: *const gfx.R4GfxDevice) bool {
    var info: gfx.R4GfxPresentationInfo = undefined;
    if (client.presentation_info(device, 0, &info) != gfx.status_ok) return false;
    if (info.flags & gfx.present_native != 0) {
        sys.println("  software probe unavailable on active native scanout; use /STATS and the native follow-up"); return false;
    }
    const pixels = @as(u64, info.width) * info.height;
    if (pixels == 0 or pixels > gfx.render_max_pixels or pixels * 4 > 64 * 1024 * 1024) return false;
    var images: [2]gfx.R4GfxResource = undefined;
    var image = descriptor(gfx.resource_image); image.flags = gfx.image_target; image.source_kind = gfx.source_create_system;
    image.image = .{ .cpu_address = 0, .byte_length = pixels * 4, .pitch = @as(u64, info.width) * 4,
        .width = info.width, .height = info.height, .format = gfx.format_xrgb8888, .reserved = 0 };
    for (&images) |*value| if (client.resource_create(device, &image, value) != gfx.status_ok) return false;
    var fill = descriptor(gfx.resource_pipeline); fill.operation = gfx.render_operation_fill;
    var pipeline: gfx.R4GfxResource = undefined;
    if (client.resource_create(device, &fill, &pipeline) != gfx.status_ok) return false;
    var chain: gfx.R4GfxSwapchain = std.mem.zeroes(gfx.R4GfxSwapchain);
    var request: gfx.R4GfxSwapchainDesc = .{ .version = 1, .size = @sizeOf(gfx.R4GfxSwapchainDesc),
        .head_id = info.head_id, .policy = gfx.present_policy_fifo, .flags = gfx.present_require_vsync,
        .count = 2, .display_generation = info.display_generation, .images = @intFromPtr(&images) };
    if (client.swapchain_open(device, &request, &chain) != gfx.status_unsupported or chain.slot != 0) return false;
    request.flags = 0;
    var previous: ?gfx.R4GfxSwapchainFrame = null;
    var copied: u32 = 0; var discarded: u32 = 0;
    for ([_]u32{ gfx.present_policy_fifo, gfx.present_policy_latest_ready, gfx.present_policy_immediate }) |policy| {
        if (info.policies & (@as(u32, 1) << @intCast(policy)) == 0) continue;
        request.policy = policy;
        if (chain.slot == 0) {
            if (client.swapchain_open(device, &request, &chain) != gfx.status_ok) return false;
        } else if (client.swapchain_resize(device, &chain, &request) != gfx.status_ok) return false;
        if (previous) |old| if (client.swapchain_release(device, &chain, &old) != gfx.status_stale) return false;
        var frames: [2]gfx.R4GfxSwapchainFrame = undefined;
        for (&frames, 0..) |*frame, index| {
            const instant = sys.monotonicNanoseconds() orelse return false;
            if (client.swapchain_acquire(device, &chain, instant, frame) != gfx.status_ok) return false;
            var draw = std.mem.zeroes(gfx.R4GfxDraw); draw.target = frame.image; draw.pipeline = pipeline;
            draw.color = if (index == 0) 0x203040 else 0x445566;
            draw.target_rect = .{ .x = 0, .y = 0, .width = info.width, .height = info.height };
            const batch: gfx.R4GfxRenderBatch = .{ .commands = @intFromPtr(&draw), .command_count = 1, .flags = 0, .pixel_budget = pixels };
            var rendered: gfx.R4GfxRenderStats = undefined;
            if (client.render(device, &batch, &rendered) != gfx.status_ok or rendered.cpu.write_bytes != pixels * 4) return false;
            // A window-sized update inside a whole output image exercises
            // exactly the same acquired resource as the fullscreen fill.
            draw.color = 0x88aacc;
            draw.target_rect = .{ .x = info.width / 4, .y = info.height / 4, .width = @max(1, info.width / 2), .height = @max(1, info.height / 2) };
            if (client.render(device, &batch, &rendered) != gfx.status_ok) return false;
            var decision: gfx.R4GfxPresentationDecision = undefined;
            if (client.presentation_plan(device, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxPresentationPlan), .head_id = info.head_id,
                .flags = 3, .source = frame.image, .source_rect = .{ .x = 0, .y = 0, .width = info.width, .height = info.height },
                .target_rect = .{ .x = 0, .y = 0, .width = info.width, .height = info.height }, .color_space = 0, .transform = 0,
                .intent = 1, .reserved = 0 }, &decision) != gfx.status_ok or decision.path != gfx.present_path_software or decision.reasons & 256 == 0) return false;
            if (client.swapchain_present(device, &chain, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxSwapchainPresent), .frame = frame.*,
                .render_job = std.mem.zeroes(gfx.R4GfxJob), .deadline_ns = instant +| 3 * std.time.ns_per_s, .intent = 1, .blockers = 0 }) != gfx.status_ok) return false;
        }
        var denied = frames[0];
        if (client.swapchain_acquire(device, &chain, 0, &denied) != gfx.status_busy or !std.meta.eql(denied, frames[0])) return false;
        var done: [2]bool = @splat(false);
        for (0..8) |_| {
            var state: gfx.R4GfxSwapchainStatus = undefined;
            if (client.swapchain_poll(device, &chain, &state) != gfx.status_ok or state.count != 2 or state.queued_count > 2 or state.held_count > 2 or
                state.path != gfx.present_path_software) return false;
            for ([_]gfx.R4GfxSwapchainFrameStatus{ state.frame0, state.frame1 }, 0..) |frame, i| {
                if (frame.phase != 4 or done[i]) continue;
                if (frame.visible_ns != 0 or frame.held_flags != 0) return false;
                if (frame.result == 2) {
                    if (frame.copied_ns == 0 or frame.copied_ns < frame.submitted_ns or frame.render_end_ns < frame.acquired_ns) return false;
                    copied += 1;
                } else if (frame.result == 3 and policy == gfx.present_policy_latest_ready) discarded += 1 else return false;
                if (client.swapchain_release(device, &chain, &frame.frame) != gfx.status_ok) return false;
                done[i] = true;
            }
            if (done[0] and done[1]) break;
        }
        if (!done[0] or !done[1]) return false;
        previous = frames[0];
    }
    if (client.swapchain_close(device, &chain) != gfx.status_ok or client.swapchain_close(device, &chain) != gfx.status_ok) return false;
    sys.write("  DEVICE_V1 buffers=2 copied="); sys.printU64(copied); sys.write(" discarded="); sys.printU64(discarded);
    sys.println(" visibility=unknown vsync=unavailable direct=rejected resize=stale-safe cleanup=complete");
    return copied >= 2 and (info.policies & 2 == 0 or discarded == 1);
}
