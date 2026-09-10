const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;

pub fn exercise(app: *r4os.App, expect_failure: bool, expect_resize: bool) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const dev = app.devicesLowLevel() orelse return 1;
    const initial = dev.displayState() orelse return 1;
    if (initial.state != a.display_state_software_native or !std.mem.startsWith(u8, &initial.backend_name, "VIRTGPU")) {
        _ = run(app);
        sys.println("DISPLAYD virtio: FAILED native backend unavailable");
        return 1;
    }
    const width = draw.screenWidth(); const height = draw.screenHeight();
    if (width < 512 or height < 384 or @as(u64, width) * height > 16 * 1024 * 1024) return 1;
    const allocator = sys.allocator();
    const pixels = allocator.alloc(u32, @as(usize, width) * height) catch return 1;
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const buffers = draw.buffers();
    var before: a.GfxBufferStats = .{};
    if (buffers.stats(&before) != a.gfx_buffer_result_ok) return 1;
    const rectangles = [_]a.DisplayDamageRect{
        .{ .x = @intCast(width / 4), .y = @intCast(height / 4), .w = 128, .h = 96 },
        .{ .x = @intCast(width / 2), .y = @intCast(height / 2), .w = 64, .h = 64 },
    };
    var failed = false;
    for (0..@as(usize, if (expect_failure) 4 else 32)) |index| {
        const odd = index % 2 == 0;
        for (rectangles, 0..) |rect, part| {
            const color: u32 = if (part == 0) (if (odd) 0x00E07030 else 0x0030B070) else (if (odd) 0x003060D0 else 0x00B03090);
            for (0..rect.h) |row| @memset(pixels[(@as(usize, @intCast(rect.y)) + row) * width + @as(usize, @intCast(rect.x)) ..][0..rect.w], color);
        }
        const request = a.DisplayPresentRequest{ .source_width = width, .source_height = height, .source_stride_pixels = width, .source_generation = index + 1 };
        var result: a.DisplayPresentResult = .{};
        const rc = draw.displayPresentRegions(&request, pixels, &rectangles, &result);
        if (rc != 0) {
            failed = true;
            if (!expect_failure or index != 2) {
                _ = run(app);
                sys.println("DISPLAYD virtio: FAILED unexpected present result");
                return 1;
            }
            break;
        }
        if (result.fence == 0 or result.fence != result.completed_fence or result.pixel_count != 128 * 96 + 64 * 64) return 1;
        if (!expect_failure and (index == 0 or index == 31)) {
            const outputs = draw.outputs();
            const previous = outputSnapshot(outputs, initial.adapter_id) orelse return 1;
            sys.println(if (index == 0) "[GFX07908] screen=1" else "[GFX07908] screen=2");
            sys.sleepTicks(sys.ticksFromMilliseconds(if (expect_resize) 5000 else 2000));
            if (expect_resize) {
                const current = outputSnapshot(outputs, initial.adapter_id) orelse return 1;
                var mode: a.GfxOutputMode = .{};
                var stale: a.GfxEdidBlock = .{};
                if (current.identity.connection_generation <= previous.identity.connection_generation or
                    current.flags & (a.gfx_output_flag_active | a.gfx_output_flag_fixed_geometry) != a.gfx_output_flag_active | a.gfx_output_flag_fixed_geometry or
                    outputs.edid(&previous.identity, 0, &stale) != a.gfx_output_error_stale or
                    outputs.mode(&current.identity, 0, &mode) != a.gfx_output_ok or mode.width != width or mode.height != height or
                    draw.screenWidth() != width or draw.screenHeight() != height)
                {
                    _ = run(app);
                    sys.println("DISPLAYD virtio resize: FAILED receiver generation or fixed surface");
                    return 1;
                }
                sys.println("DISPLAYD virtio resize: OK idle-event=received stale-EDID=rejected active-surface=preserved");
            }
        }
    }
    var after: a.GfxBufferStats = .{};
    if (expect_failure) {
        const deadline = sys.ticks() +| sys.ticksFromMilliseconds(2000);
        while (true) {
            if (buffers.stats(&after) != a.gfx_buffer_result_ok) return 1;
            if (after.objects < before.objects and after.leases < before.leases) break;
            if (sys.ticks() >= deadline) break;
            sys.sleepTicks(1);
        }
        const restored = dev.displayState() orelse return 1;
        const passed = failed and restored.state == a.display_state_bootfb and restored.driver_owner == 0 and
            restored.capabilities & a.display_state_cap_firmware_writable != 0 and
            after.objects + 1 == before.objects and after.references + 2 == before.references and after.leases + 1 == before.leases and
            after.retained_bytes == before.retained_bytes and after.committed_bytes < before.committed_bytes;
        _ = run(app);
        sys.println(if (passed) "DISPLAYD virtio recovery: OK timeout=observed bootfb=restored source-BO=released leases=balanced" else "DISPLAYD virtio recovery: FAILED");
        return if (passed) 0 else 1;
    }
    if (buffers.stats(&after) != a.gfx_buffer_result_ok) return 1;
    const passed = before.objects == after.objects and before.references == after.references and before.leases == after.leases and
        before.committed_bytes == after.committed_bytes and before.retained_bytes == after.retained_bytes;
    _ = run(app);
    sys.println(if (passed) "DISPLAYD virtio frames: OK count=32 shared-BO=reused resources=balanced completion=device-execution vblank=unknown" else "DISPLAYD virtio frames: FAILED");
    return if (passed) 0 else 1;
}
fn outputSnapshot(outputs: anytype, adapter: u32) ?a.GfxOutputInfo {
    for (0..32) |index| {
        var value: a.GfxOutputInfo = .{};
        if (outputs.info(@intCast(index), &value) != a.gfx_output_ok) continue;
        if (value.identity.adapter_id == adapter and value.flags & a.gfx_output_flag_connected != 0) return value;
    }
    return null;
}

// Report the driver's normal structured boot log through diagnostic stdout.
// No driver UART path and no inference from PCI presence alone.
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    var chunk: [2048]u8 = undefined;
    var line: [600]u8 = undefined;
    var used: usize = 0;
    var offset: u32 = 0;
    var found = false;
    while (offset < 65536) {
        const count = sys.bootLogRead(offset, &chunk);
        if (count <= 0) break;
        for (chunk[0..@intCast(count)]) |byte| {
            if (byte == '\n') {
                if (std.mem.indexOf(u8, line[0..used], "VIRTGPU") != null) {
                    sys.println(std.mem.trimEnd(u8, line[0..used], "\r"));
                    found = true;
                }
                used = 0;
            } else if (used < line.len) {
                line[used] = byte;
                used += 1;
            }
        }
        offset += @intCast(count);
    }
    return if (found) 0 else 1;
}
