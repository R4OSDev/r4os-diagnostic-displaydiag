// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Small public DEVICE_V1 workload. No receiver query, present or modeset.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const a = r4os.abi;
const width = 32;
const height = 16;
const pixel_count = width * height;
const pixel_bytes = pixel_count * 4;
const color = 0x002ca47e;
const full: gfx.R4GfxRect = .{ .x = 0, .y = 0, .width = width, .height = height };
const rectangle: gfx.R4GfxSignedRect = .{ .x = 3, .y = 2, .width = 17, .height = 9 };

fn check(rc: i32) !void { if (rc != gfx.status_ok) return error.Graphics; }
fn desc(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1; value.size = @sizeOf(gfx.R4GfxResourceDesc); value.kind = kind;
    return value;
}
fn pattern(index: usize, round: u32) u32 {
    const i: u32 = @intCast(index);
    return ((i * 197 + round * 31) & 255) | (((i * 43 + 73) & 255) << 8) | (((i * 113 + round * 97) & 255) << 16);
}
const Scene = struct {
    sys: r4os.r4sys.Context,
    api: gfx.DeviceV1Client,
    device: gfx.R4GfxDevice = undefined,
    identity: gfx.R4GfxDeviceInfo = undefined,
    stage: []const u8 = "open",
    last_clock: u64 = 0,
    jobs: u32 = 0,
    resources: [9]gfx.R4GfxResource = undefined,
    resource_count: usize = 0,

    fn now(self: *Scene) !u64 {
        const value = self.sys.monotonicNanoseconds() orelse return error.Clock;
        if (value == 0 or value == std.math.maxInt(u64) or value < self.last_clock) return error.Clock;
        self.last_clock = value;
        return value;
    }
    fn deadline(self: *Scene) !u64 { return std.math.add(u64, try self.now(), 3 * std.time.ns_per_s); }
    fn identityValid(self: *Scene) !void {
        var info: gfx.R4GfxDeviceInfo = undefined;
        try check(self.api.device_info(&self.device, &info));
        if (info.backend != gfx.render_backend_nvidia or info.adapter_id != self.identity.adapter_id or
            info.generation != self.identity.generation or info.device_generation != self.identity.device_generation or
            info.reset_generation != self.identity.reset_generation) return error.Stale;
    }
    fn create(self: *Scene, request: *const gfx.R4GfxResourceDesc) !gfx.R4GfxResource {
        if (self.resource_count == self.resources.len) return error.Bounds;
        const result = &self.resources[self.resource_count];
        try check(self.api.resource_create(&self.device, request, result));
        self.resource_count += 1;
        return result.*;
    }
    fn image(self: *Scene, native: bool) !gfx.R4GfxResource {
        var request = desc(gfx.resource_image);
        request.flags = gfx.image_target;
        const allocation: gfx.R4GfxNativeImage = .{ .version = 1, .size = @sizeOf(gfx.R4GfxNativeImage),
            .deadline_ns = try self.deadline(), .width = width, .height = height, .format = gfx.format_xrgb8888, .layout = 0 };
        if (native) {
            request.source_kind = gfx.source_create_native; request.source_address = @intFromPtr(&allocation);
        } else request.image = .{ .cpu_address = 0, .byte_length = pixel_bytes, .pitch = width * 4,
            .width = width, .height = height, .format = gfx.format_xrgb8888, .reserved = 0 };
        return self.create(&request);
    }
    fn view(self: *Scene, pixels: []u32) !gfx.R4GfxResource {
        var request = desc(gfx.resource_image);
        request.flags = gfx.image_target; request.source_kind = gfx.source_borrow_cpu; request.source_generation = 1;
        request.image = .{ .cpu_address = @intFromPtr(pixels.ptr), .byte_length = pixel_bytes, .pitch = width * 4,
            .width = width, .height = height, .format = gfx.format_xrgb8888, .reserved = 0 };
        return self.create(&request);
    }
    fn pipeline(self: *Scene, operation: u32) !gfx.R4GfxResource {
        var request = desc(gfx.resource_pipeline); request.operation = operation;
        return self.create(&request);
    }
    fn cpuBlit(self: *Scene, source: gfx.R4GfxResource, target: gfx.R4GfxResource, blit: gfx.R4GfxResource, sampler: gfx.R4GfxResource) !void {
        var draw = std.mem.zeroes(gfx.R4GfxDraw);
        draw.source = source; draw.target = target; draw.pipeline = blit; draw.sampler = sampler;
        draw.opacity = 255; draw.source_rect = full; draw.target_rect = full;
        var stats: gfx.R4GfxRenderStats = undefined;
        try check(self.api.render(&self.device, &.{ .commands = @intFromPtr(&draw), .command_count = 1, .flags = 0, .pixel_budget = pixel_count }, &stats));
        if (stats.backend != gfx.render_backend_software) return error.CpuStaging;
    }
    fn finish(self: *Scene, job: *const gfx.R4GfxJob, limit: u64) !void {
        while (true) {
            var info: gfx.R4GfxJobInfo = undefined;
            try check(self.api.job_info(&self.device, job, &info));
            if (info.phase == a.gfx_queue_phase_terminal) {
                if (info.flags != 0 or info.result != a.gfx_queue_result_complete or info.backend != gfx.render_backend_nvidia or
                    info.device_generation != self.identity.device_generation or info.reset_generation != self.identity.reset_generation or
                    info.timeline == 0 or info.point == 0) return error.Receipt;
                try self.identityValid();
                try check(self.api.job_release(&self.device, job));
                self.jobs += 1;
                return;
            }
            if (try self.now() >= limit) return error.Deadline;
            self.sys.sleepTicks(1);
        }
    }
    fn copy(self: *Scene, source: gfx.R4GfxResource, target: gfx.R4GfxResource) !void {
        var from: gfx.R4GfxResourceInfo = undefined;
        var to: gfx.R4GfxResourceInfo = undefined;
        try check(self.api.resource_info(&self.device, &source, &from));
        try check(self.api.resource_info(&self.device, &target, &to));
        const limit = try self.deadline();
        var job: gfx.R4GfxJob = undefined;
        try check(self.api.copy_submit_ex(&self.device, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx),
            .copy = .{ .source = source, .target = target, .source_offset = 0, .target_offset = 0, .byte_length = width * 4, .deadline_ns = limit },
            .row_count = height, .dependency_count = 0, .source_pitch = from.image.pitch, .target_pitch = to.image.pitch, .dependencies = 0 }, &job));
        try self.finish(&job, limit);
    }
    fn exercise(self: *Scene, input: []u32, output: []u32, round: u32) !void {
        self.stage = "backend";
        try check(self.api.device_info(&self.device, &self.identity));
        if (self.identity.backend != gfx.render_backend_nvidia or self.identity.adapter_id == 0 or self.identity.adapter_id == 0xffff or
            self.identity.device_generation == 0 or self.identity.gpu_operations & (gfx.device_gpu_copy_rows | gfx.device_gpu_render) !=
            (gfx.device_gpu_copy_rows | gfx.device_gpu_render)) return error.NativeUnavailable;
        var line: [224]u8 = undefined;
        self.sys.println(try std.fmt.bufPrint(&line, "NVIDIA smoke round={d} adapter={d} device={d} reset={d} pixels=512", .{
            round, self.identity.adapter_id, self.identity.device_generation, self.identity.reset_generation }));
        self.stage = "resources";
        const upload = try self.image(false);
        const readback = try self.image(false);
        const first = try self.image(true);
        const second = try self.image(true);
        const source_view = try self.view(input);
        const target_view = try self.view(output);
        const fill = try self.pipeline(gfx.render_operation_fill);
        const blit = try self.pipeline(gfx.render_operation_blit);
        const sampling = desc(gfx.resource_sampler);
        const sampler = try self.create(&sampling);
        for (input, 0..) |*pixel, index| pixel.* = pattern(index, round);
        @memset(output, 0x005a5a5a);
        try self.cpuBlit(source_view, upload, blit, sampler);
        self.stage = "ce-upload"; try self.copy(upload, first);
        self.stage = "ce-native-copy"; try self.copy(first, second);
        self.stage = "ce-readback"; try self.copy(second, readback);
        try self.cpuBlit(readback, target_view, blit, sampler);
        for (output, 0..) |pixel, index| if (pixel & 0xffffff != pattern(index, round)) return error.CopyPixels;
        self.sys.println("NVIDIA smoke CE: OK nonconstant-upload native-copy separate-readback pixels=512");
        self.stage = "gr-fill";
        var request = std.mem.zeroes(gfx.R4GfxRenderRequest);
        request.version = 1; request.size = @sizeOf(gfx.R4GfxRenderRequest); request.target = second; request.pipeline = fill;
        request.color = color; request.opacity = 255; request.target_rect = rectangle; request.scissor = rectangle;
        request.deadline_ns = try self.deadline();
        var job: gfx.R4GfxJob = undefined;
        try check(self.api.render_submit(&self.device, &request, &job));
        try self.finish(&job, request.deadline_ns);
        self.stage = "gr-readback";
        @memset(output, 0x00a5a5a5);
        try self.copy(second, readback);
        try self.cpuBlit(readback, target_view, blit, sampler);
        var mismatches: usize = 0;
        var unchanged: usize = 0;
        var filled: usize = 0;
        for (output, 0..) |pixel, index| {
            const x = index % width; const y = index / width;
            const expected = if (x >= 3 and x < 20 and y >= 2 and y < 11) color else pattern(index, round);
            if (pixel & 0xffffff == pattern(index, round)) unchanged += 1;
            if (pixel & 0xffffff == color) filled += 1;
            if (pixel & 0xffffff != expected) {
                if (mismatches < 4) self.sys.println(try std.fmt.bufPrint(&line,
                    "NVIDIA smoke pixel: x={d} y={d} expected={x:0>6} actual={x:0>8} original={x:0>6}",
                    .{x, y, expected, pixel, pattern(index, round)}));
                mismatches += 1;
            }
        }
        if (mismatches != 0) {
            self.sys.println(try std.fmt.bufPrint(&line,
                "NVIDIA smoke pixels: mismatches={d}/512 unchanged={d} filled={d}", .{mismatches, unchanged, filled}));
            return error.RenderPixels;
        }
        try self.identityValid();
        self.sys.println("NVIDIA smoke GR: OK fill=153 preserved=359 readback=512 GPU-receipts=5");
        self.stage = "release";
        while (self.resource_count != 0) {
            try check(self.api.resource_release(&self.device, &self.resources[self.resource_count - 1]));
            self.resource_count -= 1;
        }
    }
};

fn runScene(app: *r4os.App, round: u32) bool {
    const sys = app.system();
    const allocator = sys.allocator();
    const api = gfx.DeviceV1Client.init(app.startContext()) catch return false;
    const size = api.storage_size();
    if (size == 0 or size > std.math.maxInt(usize)) return false;
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(size)) catch return false;
    @memset(storage, 0);
    const pixels = allocator.alloc(u32, pixel_count * 2) catch { allocator.free(storage); return false; };
    var scene: Scene = .{ .sys = sys, .api = api };
    if (api.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
        .storage_bytes = storage.len, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = 0 }, &scene.device) != gfx.status_ok) {
        allocator.free(pixels); allocator.free(storage); return false;
    }
    var passed = true;
    scene.exercise(pixels[0..pixel_count], pixels[pixel_count..], round) catch |err| {
        var line: [180]u8 = undefined;
        sys.println(std.fmt.bufPrint(&line, "NVIDIA smoke failed: stage={s} error={s} confirmed-jobs={d}", .{scene.stage, @errorName(err), scene.jobs}) catch "NVIDIA smoke failed");
        passed = false;
    };
    const limit = scene.deadline() catch 0;
    var closed = false;
    while (true) {
        if (api.device_close(&scene.device) == gfx.status_ok) { closed = true; break; }
        if ((scene.now() catch limit) >= limit) break;
        sys.sleepTicks(1);
    }
    if (closed) { allocator.free(pixels); allocator.free(storage); }
    sys.println(if (closed) "NVIDIA smoke device: closed" else "NVIDIA smoke device: retained after bounded close failure");
    return passed and closed;
}

fn settledBuffers(app: *r4os.App, out: *a.GfxBufferStats) bool {
    const sys = app.system();
    const draw = app.drawing() orelse return false;
    const buffers = draw.buffers();
    const limit = sys.ticks() +| sys.ticksFromMilliseconds(1000);
    while (true) {
        if (buffers.stats(out) != a.gfx_buffer_result_ok) return false;
        // device_close ends public ownership, but RM destruction and idle
        // mapping eviction continue in the driver worker. Do not freeze an
        // intermediate retirement count into the steady-state reference.
        if (out.allocating_bytes == 0 and out.destroying_bytes == 0 and out.retained_bytes == 0) return true;
        if (sys.ticks() >= limit) break;
        sys.sleepTicks(1);
    }
    var line: [200]u8 = undefined;
    sys.println(std.fmt.bufPrint(&line, "NVIDIA smoke settlement: FAILED allocating={d} destroying={d} retained={d} limit=1000ms",
        .{out.allocating_bytes, out.destroying_bytes, out.retained_bytes}) catch "NVIDIA smoke settlement: FAILED");
    return false;
}

pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const buffers = draw.buffers();
    // First-use driver resources are separate from producer retirement.
    // Full cache retirement still belongs to driver shutdown.
    var cold: a.GfxBufferStats = .{};
    if (!settledBuffers(app, &cold) or !runScene(app, 1)) return 1;
    var before: a.GfxBufferStats = .{};
    if (!settledBuffers(app, &before)) return 1;
    sys.println(if (std.meta.eql(cold, before)) "NVIDIA smoke first-use: common BO counters unchanged" else "NVIDIA smoke first-use: common BO counters changed; driver-cache retirement remains unproven");
    const runtime = @import("resource_balance.zig").Runtime.capture(app) orelse return 1;
    if (!runScene(app, 2)) return 1;
    var after: a.GfxBufferStats = .{};
    const limit = sys.ticks() +| sys.ticksFromMilliseconds(1000);
    while (true) {
        if (buffers.stats(&after) != a.gfx_buffer_result_ok) return 1;
        if (std.meta.eql(before, after) or sys.ticks() >= limit) break;
        sys.sleepTicks(1);
    }
    var passed = @import("resource_balance.zig").buffers(&sys, before, after);
    passed = @import("resource_balance.zig").Runtime.balanced(runtime, app) and passed;
    sys.println(if (passed) "NVIDIA smoke: OK CE=8 GR=2 exact-pixels=2048 steady-state=balanced present=none" else "NVIDIA smoke: FAILED steady-state resource balance");
    return if (passed) 0 else 1;
}
