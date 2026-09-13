const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const a = r4os.abi;
const ok = a.gfx_buffer_result_ok;

pub fn run(app: *r4os.App, require_driver: bool) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const buffers = draw.buffers();
    const library = gfx.ApiV1Client.init(app.startContext()) catch return 1;
    const render = gfx.RenderV1Client.init(app.startContext()) catch return 1;
    var before: a.GfxBufferStats = .{};
    var after: a.GfxBufferStats = .{};
    var passed = buffers.stats(&before) == ok and exercise(&sys, &buffers, &library, &render);
    passed = passed and @import("render_resources.zig").run(app);
    passed = buffers.stats(&after) == ok and passed;
    passed = passed and before.objects == after.objects and before.references == after.references and
        before.leases == after.leases and before.committed_bytes == after.committed_bytes and before.retained_bytes == after.retained_bytes;
    sys.println(if (passed) "DISPLAYD software-buffer: OK" else "DISPLAYD software-buffer: FAILED");
    if (require_driver) {
        for ([_][]const u8{
            "EXAMPLE.R4D gfx-memory result: OK bytes=83886080 segments=20480 submission=none",
            "EXAMPLE.R4D gfx-memory work: OK init-import=same-BO query=worker mmio=denied dedicated=denied release=balanced",
            "EXAMPLE.R4D gfx-owned init: OK prefix=112 canary=preserved exact-tickets=balanced",
            "EXAMPLE.R4D gfx-owned work: OK imported-and-GPU=retained system-collect=independent",
        }) |marker| {
            const verified = logContains(&sys, marker);
            sys.println(if (verified) marker else "DISPLAYD driver-memory: FAILED");
            passed = passed and verified;
        }
        const rejected = "EXAMPLE.R4D gfx-memory deliberate init rejection: code=-79 cleanup-probe";
        if (logContains(&sys, rejected)) {
            sys.println(rejected);
            const closed = "EXAMPLE.R4D gfx-memory close: OK admission=closed cached-release=allowed DMA-GPU-CPU=balanced";
            const verified = logContains(&sys, closed);
            sys.println(if (verified) closed else "DISPLAYD driver-memory close: FAILED");
            passed = passed and verified;
            const native_closed = "EXAMPLE.R4D gfx-owned close: OK admission=closed abort-and-retire=balanced";
            const native_verified = logContains(&sys, native_closed);
            sys.println(if (native_verified) native_closed else "DISPLAYD driver-memory close: FAILED");
            passed = passed and native_verified;
        }
    }
    sys.println(if (passed) "DISPLAYD buffers result: OK library=R4GFX software=shared-BO maps=2 release=balanced" else "DISPLAYD buffers result: FAILED");
    return if (passed) 0 else 1;
}

pub fn logContains(sys: *const r4os.r4sys.Context, needle: []const u8) bool {
    var chunk: [2048]u8 = undefined;
    var offset: u32 = 0;
    // Overlap reads so a record split at a chunk boundary remains visible.
    while (offset < 1024 * 1024) {
        const count = sys.bootLogRead(offset, &chunk);
        if (count <= 0) return false;
        const n: usize = @intCast(count);
        if (std.mem.indexOf(u8, chunk[0..n], needle) != null) return true;
        var lines = std.mem.splitScalar(u8, chunk[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "EXAMPLE.R4D") != null) sys.println(line);
        }
        if (n < chunk.len) return false;
        offset += @intCast(n - needle.len);
    }
    return false;
}

fn exercise(sys: *const r4os.r4sys.Context, buffers: *const r4os.gfx_buffers.Context, library: *const gfx.ApiV1Client, render: *const gfx.RenderV1Client) bool {
    var layout: gfx.R4GfxLinearLayout = undefined;
    if (library.linear_layout(13, 7, a.gfx_buffer_format_xrgb8888, 64, &layout) != gfx.status_ok or layout.pitch != 64 or layout.byte_length != 448) return false;
    const descriptor = a.GfxBufferDescriptor{
        .byte_length = layout.byte_length,
        .width = layout.width,
        .height = layout.height,
        .format = layout.format,
        .plane_count = 1,
        .plane_pitches = .{ layout.pitch, 0, 0, 0 },
    };
    var first: a.GfxBufferReference = .{};
    if (buffers.create(&descriptor, &first) != ok) return false;
    defer if (first.reference.id != 0) {
        _ = buffers.release(&first.reference);
    };
    if (!pageableOutputs(sys, buffers, first.reference, descriptor)) return false;
    var write: a.GfxBufferMap = .{};
    if (buffers.map(&first.reference, 1, 0, layout.byte_length, &write) != ok) return false;
    defer if (write.lease.id != 0) {
        _ = buffers.unmap(&write.lease);
    };
    const image = gfx.R4GfxCpuImage{ .cpu_address = write.cpu_address, .byte_length = write.byte_length, .pitch = layout.pitch, .width = layout.width, .height = layout.height, .format = layout.format, .reserved = 0 };
    if (!renderScene(sys, buffers, render, image)) return false;
    if (library.fill_rect(&image, &.{ .x = 1, .y = 2, .width = 5, .height = 3 }, 0x123456) != gfx.status_ok) return false;
    if (buffers.unmap(&write.lease) != ok) return false;
    write.lease = .{};
    var imported: a.GfxBufferReference = .{};
    if (buffers.import(&first.reference, &imported) != ok or !std.meta.eql(first.buffer, imported.buffer)) return false;
    defer if (imported.reference.id != 0) {
        _ = buffers.release(&imported.reference);
    };
    var read: a.GfxBufferMap = .{};
    var second: a.GfxBufferMap = .{};
    if (buffers.map(&first.reference, 0, 0, layout.byte_length, &read) != ok) return false;
    defer if (read.lease.id != 0) {
        _ = buffers.unmap(&read.lease);
    };
    if (buffers.map(&imported.reference, 0, 0, layout.byte_length, &second) != ok) return false;
    defer if (second.lease.id != 0) {
        _ = buffers.unmap(&second.lease);
    };
    if (read.cpu_address != second.cpu_address or buffers.map(&first.reference, 1, 0, 1, &write) != a.gfx_buffer_error_busy) return false;
    if (buffers.release(&first.reference) != ok) return false;
    first.reference = .{};
    if (buffers.release(&imported.reference) != ok) return false;
    imported.reference = .{};
    const bytes: [*]const u8 = @ptrFromInt(read.cpu_address);
    var y: usize = 0;
    while (y < 7) : (y += 1) {
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            const pixel = std.mem.readInt(u32, bytes[y * 64 + x * 4 ..][0..4], .little);
            const expected: u32 = if (y >= 2 and y < 5 and x >= 1 and x < 6) 0x123456 else 0;
            if (pixel != expected) return false;
        }
    }
    if (buffers.unmap(&read.lease) != ok) return false;
    read.lease = .{};
    if (buffers.unmap(&second.lease) != ok or buffers.unmap(&second.lease) != a.gfx_buffer_error_stale) return false;
    second.lease = .{};
    var invalid = descriptor;
    invalid.plane_pitches[0] = std.math.maxInt(u64) - 3;
    var rejected: a.GfxBufferReference = .{};
    return buffers.create(&invalid, &rejected) == a.gfx_buffer_error_overflow and rejected.reference.id == 0;
}

fn renderScene(sys: *const r4os.r4sys.Context, buffers: *const r4os.gfx_buffers.Context, render: *const gfx.RenderV1Client, target: gfx.R4GfxCpuImage) bool {
    var caps: gfx.R4GfxRenderCaps = undefined;
    if (render.capabilities(&caps) != gfx.status_ok or caps.version != 1 or caps.size != @sizeOf(gfx.R4GfxRenderCaps) or
        caps.backend != gfx.render_backend_software or caps.max_images < 2 or caps.max_commands < 3 or
        caps.operations & 7 != 7 or caps.samplers & 3 != 3 or caps.features & gfx.render_feature_validate_first == 0) return false;
    var source: a.GfxBufferReference = .{};
    if (buffers.create(&.{ .byte_length = 16, .width = 2, .height = 2, .format = a.gfx_buffer_format_argb8888, .plane_count = 1, .plane_pitches = .{ 8, 0, 0, 0 } }, &source) != ok) return false;
    defer if (source.reference.id != 0) {
        _ = buffers.release(&source.reference);
    };
    var map: a.GfxBufferMap = .{};
    if (buffers.map(&source.reference, 1, 0, 16, &map) != ok) return false;
    defer if (map.lease.id != 0) {
        _ = buffers.unmap(&map.lease);
    };
    const pixels: [*]u8 = @ptrFromInt(map.cpu_address);
    for (0..4) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0x80800000, .little);
    if (buffers.unmap(&map.lease) != ok) return false;
    map.lease = .{};
    if (buffers.map(&source.reference, 0, 0, 16, &map) != ok) return false;
    // The read lease, not the producer reference, holds this image alive.
    if (buffers.release(&source.reference) != ok) return false;
    source.reference = .{};
    const images = [_]gfx.R4GfxCpuImage{ target, .{ .cpu_address = map.cpu_address, .byte_length = map.byte_length, .pitch = 8, .width = 2, .height = 2, .format = gfx.format_argb8888, .reserved = 0 } };
    const empty = gfx.R4GfxRect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var commands = [_]gfx.R4GfxCpuDraw{
        .{ .operation = gfx.render_operation_fill, .source_index = 0, .target_index = 0, .sampler = 0, .source_rect = empty, .target_rect = .{ .x = 0, .y = 0, .width = 13, .height = 7 }, .color = 0x0000ff, .opacity = 0, .reserved0 = 0, .reserved1 = 0 },
        .{ .operation = gfx.render_operation_over, .source_index = 1, .target_index = 0, .sampler = gfx.render_sampler_bilinear, .source_rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .target_rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .color = 0, .opacity = 255, .reserved0 = 0, .reserved1 = 0 },
        .{ .operation = gfx.render_operation_blit, .source_index = 1, .target_index = 0, .sampler = gfx.render_sampler_nearest, .source_rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .target_rect = .{ .x = 6, .y = 0, .width = 4, .height = 4 }, .color = 0, .opacity = 255, .reserved0 = 0, .reserved1 = 0 },
    };
    var request = gfx.R4GfxCpuBatch{ .images = @intFromPtr(&images), .commands = @intFromPtr(&commands), .image_count = images.len, .command_count = commands.len, .pixel_budget = 123, .flags = 0, .reserved = 0 };
    var stats = gfx.R4GfxCpuStats{ .read_bytes = 1, .write_bytes = 2, .pixels = 3, .commands = 4, .reserved = 5 };
    const untouched = stats;
    const bytes: [*]const u8 = @ptrFromInt(target.cpu_address);
    commands[2].target_rect.width = 8;
    if (render.execute_cpu(&request, &stats) != gfx.status_invalid or !std.meta.eql(untouched, stats) or
        !std.mem.allEqual(u8, bytes[0..448], 0)) return false;
    commands[2].target_rect.width = 4;
    if (render.execute_cpu(&request, &stats) != gfx.status_ok or stats.commands != 3 or stats.pixels != 123 or
        stats.read_bytes != 384 or stats.write_bytes != 492 or stats.reserved != 0) return false;
    for (0..7) |y| for (0..16) |x| {
        const expected: u32 = if (x >= 13) 0 else if (y < 4 and x < 4) 0x80007f else if (y < 4 and x >= 6 and x < 10) 0x800000 else 0x0000ff;
        if (std.mem.readInt(u32, bytes[y * 64 + x * 4 ..][0..4], .little) != expected) return false;
    };
    const source_bytes: [*]const u8 = @ptrFromInt(map.cpu_address);
    for (0..4) |i| if (std.mem.readInt(u32, source_bytes[i * 4 ..][0..4], .little) != 0x80800000) return false;
    if (buffers.unmap(&map.lease) != ok) return false;
    map.lease = .{};
    commands[0].color = 0;
    request.command_count = 1;
    // The source map is gone; do not leave its address in the reset batch.
    request.image_count = 1;
    if (render.execute_cpu(&request, &stats) != gfx.status_ok) return false;
    sys.println("DISPLAYD render: OK backend=software batch=3 pixels=123 read=384 write=492");
    return true;
}

fn pageableOutputs(sys: *const r4os.r4sys.Context, buffers: *const r4os.gfx_buffers.Context, reference: a.GfxBufferHandle, descriptor: a.GfxBufferDescriptor) bool {
    inline for (.{ a.GfxBufferDescriptor, a.GfxBufferReference, a.GfxBufferMap, a.GfxBufferStats }) |T| {
        const region = sys.vmReserve(8192, 4096, 0) orelse return false;
        var released = false;
        defer if (!released) {
            _ = sys.vmRelease(region.id);
        };
        if (sys.vmCommit(region.id, 0, 8192) != a.vm_ok) return false;
        // Only the header is resident. The API must publish the tail to the
        // second page AFTER releasing its no-sleep metadata owner.
        const out: *T = @ptrFromInt(region.base + 4096 - 8);
        out.version = 1;
        out.size = @sizeOf(T);
        const before = sys.vmQuery(region.id) orelse return false;
        if (before.resident_bytes != 4096) return false;
        if (T == a.GfxBufferDescriptor) {
            if (buffers.describe(&reference, out) != ok or !std.meta.eql(descriptor, out.*)) return false;
        } else if (T == a.GfxBufferReference) {
            if (buffers.import(&reference, out) != ok) return false;
            if (buffers.release(&out.reference) != ok) return false;
        } else if (T == a.GfxBufferMap) {
            if (buffers.map(&reference, 0, 0, descriptor.byte_length, out) != ok) return false;
            if (buffers.unmap(&out.lease) != ok) return false;
        } else {
            if (buffers.stats(out) != ok or out.objects == 0) return false;
        }
        const after = sys.vmQuery(region.id) orelse return false;
        if (after.resident_bytes != 8192 or sys.vmRelease(region.id) != a.vm_ok) return false;
        released = true;
    }
    sys.println("DISPLAYD pageable-output: OK operations=4 faults=outside-owner");
    return true;
}
