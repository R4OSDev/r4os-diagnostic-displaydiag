// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! The same public Fill/Blit/OVER scene on CPU and native resources.
//! Explicit diagnostic only; no receiver query, presentation or GPU fault.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const nv = @import("r4nv");
const cases = @import("r4nv_reference");
const Probe = @import("nvidia_render.zig").Probe;
const balance = @import("resource_balance.zig");
const a = r4os.abi;
const bytes = cases.target_bytes + 64;

fn check(rc: i32) !void { if (rc != gfx.status_ok) return error.Graphics; }
fn platform(rc: i32) !void { if (rc != a.gfx_buffer_result_ok) return error.Platform; }
fn desc(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1; value.size = @sizeOf(gfx.R4GfxResourceDesc); value.kind = kind;
    return value;
}

fn negative(probe: *Probe, app: *r4os.App, source: gfx.R4GfxResource) !void {
    const draw = app.drawing() orelse return error.Platform;
    const queue = draw.queues();
    var backend: a.GfxBackendInfo = .{};
    var found = false;
    for (0..16) |index| {
        if (queue.backendInfo(@intCast(index), &backend) == 1 and backend.binding.adapter_id == probe.identity.adapter_id) { found = true; break; }
    }
    if (!found or backend.binding.device_generation != probe.identity.device_generation or
        backend.binding.reset_generation != probe.identity.reset_generation) return error.Backend;
    const profile = std.mem.bytesToValue(nv.R4NvDriverProfile, backend.profile.data[0..@sizeOf(nv.R4NvDriverProfile)]);
    const client = nv.BackendV1Client.init(app.startContext()) catch return error.Platform;
    const identity: nv.R4NvDeviceProfile = .{ .version = 1, .size = @sizeOf(nv.R4NvDeviceProfile),
        .vendor_id = profile.vendor_id, .copy_class = profile.copy_class, .rm_release = profile.rm_release,
        .command_abi = profile.command_abi, .adapter_id = backend.binding.adapter_id,
        .device_generation = backend.binding.device_generation, .reset_generation = backend.binding.reset_generation, .flags = 0 };
    var request: nv.R4NvImageRequest = .{ .view = .{ .version = 1, .size = @sizeOf(nv.R4NvImageView),
        .width = 7, .height = 5, .format = gfx.format_argb8888, .location = 1, .modifier = 0,
        .byte_length = 65536, .pitch = 256, .alignment = 65536, .usage = 28, .reserved = 0 },
        .uses = nv.image_use_texture, .preference = nv.image_prefer_compatible, .flags = 0, .reserved = 0 };
    var plan: nv.R4NvImagePlan = undefined;
    if (client.image_layout(&identity, &request, &plan) != nv.status_ok or plan.action != nv.image_action_reuse) return error.Layout;
    const original = plan;
    // Metadata rejection: no device-local BO with an invented modifier is
    // created, and no such descriptor can reach a hardware command.
    for ([_]u64{ 0x0100000000000001, 0x030000000060601f }) |modifier| {
        request.view.modifier = modifier;
        if (client.image_layout(&identity, &request, &plan) != nv.status_unsupported or !std.meta.eql(plan, original)) return error.Modifier;
    }
    var ready = std.mem.zeroes(gfx.R4GfxCopyFence);
    ready.point = 79;
    const original_ready = ready;
    var output = std.mem.zeroes(gfx.R4GfxPreparedImage);
    output.flags = 79;
    const original_output = output;
    var prepare: gfx.R4GfxImagePrepareRequest = .{ .version = 1, .size = @sizeOf(gfx.R4GfxImagePrepareRequest),
        .source = source, .uses = gfx.prepare_use_texture, .preference = gfx.prepare_layout_blocklinear,
        .flags = gfx.prepare_force_copy, .deadline_ns = try probe.deadline(), .byte_budget = 0,
        .dependency_count = 0, .dependencies = 0, .ready_dependencies = @intFromPtr(&ready), .ready_capacity = 1, .reserved = 0 };
    var before: a.GfxBufferStats = .{};
    try platform(probe.memory.stats(&before));
    if (probe.api.image_prepare(&probe.device, &prepare, &output) != gfx.status_limit) return error.Budget;
    prepare.preference = 3;
    if (probe.api.image_prepare(&probe.device, &prepare, &output) != gfx.status_invalid or
        !std.meta.eql(ready, original_ready) or !std.meta.eql(output, original_output)) return error.RejectedOutput;
    var after: a.GfxBufferStats = .{};
    try platform(probe.memory.stats(&after));
    if (!std.meta.eql(before, after)) return error.RejectedAllocation;
    probe.line("NVIDIA scene boundaries: OK budget0-convert=limit preference=invalid unknown-modifiers=2 metadata-only outputs=unchanged allocations=0", .{});
}

fn exercise(probe: *Probe, app: *r4os.App, tiled: bool) !void {
    try probe.bind();
    var source_pixels: [cases.source_bytes + 32]u8 = undefined;
    var initial: [bytes]u8 = undefined;
    cases.initialize(cases.scenes[0], &source_pixels, &initial);
    var references: [4]a.GfxBufferReference = @splat(.{});
    defer for (&references) |*ref| if (ref.reference.id != 0) { _ = probe.memory.release(&ref.reference); };
    probe.stage = "scene-images";
    references[0] = try probe.system(7, 5, 32, gfx.format_argb8888, &source_pixels);
    references[1] = try probe.system(32, 24, 128, gfx.format_argb8888, &initial);
    references[2] = try probe.system(32, 24, 128, gfx.format_argb8888, &initial);
    @memset(&initial, 0xcc);
    references[3] = try probe.system(32, 24, 128, gfx.format_argb8888, &initial);
    var images: [4]gfx.R4GfxResource = undefined;
    for (&images, references) |*image, ref| image.* = try probe.import(ref.reference);
    probe.stage = "scene-boundaries";
    if (!tiled) try negative(probe, app, images[0]);
    var pipelines: [3]gfx.R4GfxResource = undefined;
    for (&pipelines, [_]u32{gfx.render_operation_fill, gfx.render_operation_blit, gfx.render_operation_over}) |*pipeline, op| {
        var request = desc(gfx.resource_pipeline); request.operation = op;
        try check(probe.api.resource_create(&probe.device, &request, pipeline));
    }
    var sampler: gfx.R4GfxResource = undefined;
    var sampling = desc(gfx.resource_sampler); sampling.sampler = gfx.render_sampler_nearest;
    try check(probe.api.resource_create(&probe.device, &sampling, &sampler));
    var commands: [3]gfx.R4GfxDraw = @splat(std.mem.zeroes(gfx.R4GfxDraw));
    const rectangles = [_]gfx.R4GfxRect{
        .{ .x = 2, .y = 3, .width = 26, .height = 18 },
        .{ .x = 3, .y = 4, .width = 17, .height = 13 },
        .{ .x = 8, .y = 5, .width = 11, .height = 9 },
    };
    for (&commands, 0..) |*command, index| {
        command.target = images[1]; command.pipeline = pipelines[index]; command.target_rect = rectangles[index];
        // CPU Fill reserves opacity=0; its color already carries alpha.
        command.opacity = if (index == 0) 0 else if (index == 2) 137 else 255;
        if (index == 0) command.color = 0xff204080 else {
            command.source = images[0]; command.sampler = sampler;
            command.source_rect = .{ .x = 1, .y = 1, .width = 5, .height = 3 };
        }
    }
    probe.stage = "scene-software";
    var statistics: gfx.R4GfxRenderStats = undefined;
    try check(probe.api.render(&probe.device, &.{ .commands = @intFromPtr(&commands), .command_count = 3,
        .flags = 0, .pixel_budget = 32 * 24 * 3 }, &statistics));
    if (statistics.backend != gfx.render_backend_software or statistics.cpu.write_bytes == 0) return error.Software;
    const limit = try probe.deadline();
    var ready: [2]gfx.R4GfxCopyFence = undefined;
    probe.stage = "scene-prepare";
    const source = try probe.prepare(images[0], false, tiled, &ready[0], limit);
    const target = try probe.prepare(images[2], true, tiled, &ready[1], limit);
    var jobs: [3]gfx.R4GfxJob = undefined;
    var fences: [3]gfx.R4GfxCopyFence = undefined;
    probe.stage = "scene-native";
    for (commands, 0..) |command, index| {
        var request = std.mem.zeroes(gfx.R4GfxRenderRequest);
        request.version = 1; request.size = @sizeOf(gfx.R4GfxRenderRequest);
        request.target = target.image; request.pipeline = command.pipeline; request.color = command.color;
        request.target_rect = .{ .x = @intCast(command.target_rect.x), .y = @intCast(command.target_rect.y),
            .width = command.target_rect.width, .height = command.target_rect.height };
        request.scissor = .{ .x = 0, .y = 0, .width = 32, .height = 24 };
        // Native Fill multiplies the color by opacity, so the same opaque
        // fill uses 255 at this public async boundary.
        request.opacity = if (index == 0) 255 else command.opacity; request.deadline_ns = limit;
        request.dependencies = if (index == 0) @intFromPtr(&ready) else @intFromPtr(&fences[index - 1]);
        request.dependency_count = if (index == 0) 2 else 1;
        if (index != 0) {
            request.source = source.image; request.sampler = command.sampler;
            request.source_rect = .{ .x = @intCast(command.source_rect.x), .y = @intCast(command.source_rect.y),
                .width = command.source_rect.width, .height = command.source_rect.height };
        }
        try check(probe.api.render_submit(&probe.device, &request, &jobs[index]));
        try check(probe.api.job_fence(&probe.device, &jobs[index], &fences[index]));
    }
    var native: gfx.R4GfxResourceInfo = undefined;
    try check(probe.api.resource_info(&probe.device, &target.image, &native));
    var readback: gfx.R4GfxJob = undefined;
    try check(probe.api.copy_submit_ex(&probe.device, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx),
        .copy = .{ .source = target.image, .target = images[3], .source_offset = 0, .target_offset = 0, .byte_length = 128, .deadline_ns = limit },
        .row_count = 24, .source_pitch = native.image.pitch, .target_pitch = 128, .dependency_count = 1,
        .dependencies = @intFromPtr(&fences[2]) }, &readback));
    try check(probe.api.resource_release(&probe.device, &source.image));
    try check(probe.api.resource_release(&probe.device, &target.image));
    probe.stage = "scene-completion";
    try probe.finish(&readback, limit, false);
    var index: usize = jobs.len;
    while (index != 0) { index -= 1; try probe.finish(&jobs[index], limit, true); }
    try probe.finish(&target.job, limit, false);
    try probe.finish(&source.job, limit, false);
    probe.stage = "scene-compare";
    var maps: [2]a.GfxBufferMap = @splat(.{});
    defer for (&maps) |*map| if (map.lease.id != 0) { _ = probe.memory.unmap(&map.lease); };
    try platform(probe.memory.map(&references[1].reference, 0, 0, bytes, &maps[0]));
    try platform(probe.memory.map(&references[3].reference, 0, 0, bytes, &maps[1]));
    for (maps) |map| if (map.cpu_address == 0 or map.byte_length != bytes) return error.Map;
    const expected = @as([*]const u8, @ptrFromInt(maps[0].cpu_address))[0..bytes];
    const actual = @as([*]const u8, @ptrFromInt(maps[1].cpu_address))[0..bytes];
    var maximum: u8 = 0;
    for (expected, actual, 0..) |want, got, at| {
        const delta = @max(want, got) - @min(want, got);
        const x = (at % 128) / 4; const y = at / 128;
        const tolerance: u8 = if (x >= 8 and x < 19 and y >= 5 and y < 14) 1 else 0;
        if (delta > tolerance) {
            probe.line("NVIDIA scene pixel: byte={d} cpu={d} gpu={d} tolerance={d}", .{at, want, got, tolerance});
            return error.Pixels;
        }
        maximum = @max(maximum, delta);
    }
    // Preserve both results for the later manual visual comparison. These
    // are ordinary temporary files, never an active output or presentation.
    if (probe.sys.fileWrite(if (tiled) "C:\\TEMP\\NVSC-C1.RAW" else "C:\\TEMP\\NVSC-C0.RAW", expected) != bytes or
        probe.sys.fileWrite(if (tiled) "C:\\TEMP\\NVSC-G1.RAW" else "C:\\TEMP\\NVSC-G0.RAW", actual) != bytes) return error.Evidence;
    for (&maps) |*map| { try platform(probe.memory.unmap(&map.lease)); map.* = .{}; }
    probe.compared += bytes;
    for (&images) |*image| try check(probe.api.resource_release(&probe.device, image));
    for (&pipelines) |*pipeline| try check(probe.api.resource_release(&probe.device, pipeline));
    try check(probe.api.resource_release(&probe.device, &sampler));
    for (&references) |*ref| { try platform(probe.memory.release(&ref.reference)); ref.* = .{}; }
    probe.line("NVIDIA scene case: OK layout={s} same-commands=Fill-Blit-OVER max-LSB={d} bytes={d} untouched=exact CPU-reference=public-render GPU=render-submit present=none", .{
        if (tiled) "blocklinear" else "linear", maximum, bytes,
    });
}

pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const memory = draw.buffers();
    const api = gfx.DeviceV1Client.init(app.startContext()) catch return 1;
    const size = api.storage_size();
    if (size == 0 or size > std.math.maxInt(usize)) return 1;
    const allocator = sys.allocator();
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(size)) catch return 1;
    @memset(storage, 0);
    var before: a.GfxBufferStats = .{};
    if (memory.stats(&before) != 1 or before.allocating_bytes != 0 or before.destroying_bytes != 0 or before.retained_bytes != 0) { allocator.free(storage); return 1; }
    const runtime = balance.Runtime.capture(app) orelse { allocator.free(storage); return 1; };
    var probe: Probe = .{ .sys = sys, .memory = memory, .api = api };
    var passed = true;
    for (0..2) |layout| {
        if (api.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
            .storage_bytes = size, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = 0 }, &probe.device) != gfx.status_ok) { passed = false; break; }
        exercise(&probe, app, layout != 0) catch |err| {
            probe.line("NVIDIA scene failed: layout={d} stage={s} error={s} CE={d} GR={d}", .{layout, probe.stage, @errorName(err), probe.ce, probe.gr});
            passed = false;
        };
        const limit = probe.deadline() catch 0;
        var closed = false;
        while (true) {
            if (api.device_close(&probe.device) == gfx.status_ok) { closed = true; break; }
            if ((probe.now() catch limit) >= limit) break;
            sys.sleepTicks(1);
        }
        if (!closed) { sys.println("NVIDIA scene device: retained after bounded close failure"); return 1; }
        passed = balance.waitBuffers(&sys, &memory, before) and passed;
        if (!passed) break;
    }
    allocator.free(storage);
    passed = balance.Runtime.balanced(runtime, app) and passed;
    if (passed and probe.ce == 6 and probe.gr == 6 and probe.compared == 6272) {
        sys.println("NVIDIA scene: OK layouts=2 CE=6 GR=6 compared-bytes=6272 same-consumer software-native balance=complete present=none");
        return 0;
    }
    sys.println("NVIDIA scene: FAILED");
    return 1;
}
