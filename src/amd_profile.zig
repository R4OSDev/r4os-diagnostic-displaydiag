// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Explicit, fixed diagnostic scene. Host wall intervals are not GPU timers.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const a = r4os.abi;
const width = 256;
const height = 128;
const bytes = width * height * 4;
const iterations = 32;
const Stats = struct { calls_ns: u64 = 0, waits_ns: u64 = 0, count: u32 = 0 };
const Scene = struct {
    sys: r4os.r4sys.Context,
    api: gfx.DeviceV1Client,
    device: gfx.R4GfxDevice,
    native: bool,
    source: gfx.R4GfxResource = undefined,
    target: gfx.R4GfxResource = undefined,
    staging: gfx.R4GfxResource = undefined,
    fill: gfx.R4GfxResource = undefined,
    blit: gfx.R4GfxResource = undefined,
    sampler: gfx.R4GfxResource = undefined,
    fn now(self: *Scene) !u64 {
        return self.sys.monotonicNanoseconds() orelse error.Clock;
    }
    fn check(rc: i32) !void {
        if (rc != gfx.status_ok) return error.Graphics;
    }
    fn desc(kind: u32) gfx.R4GfxResourceDesc {
        var result = std.mem.zeroes(gfx.R4GfxResourceDesc);
        result.version = 1;
        result.size = @sizeOf(gfx.R4GfxResourceDesc);
        result.kind = kind;
        return result;
    }
    fn image(self: *Scene, native: bool) !gfx.R4GfxResource {
        var request = desc(gfx.resource_image);
        request.flags = gfx.image_target;
        const allocation: gfx.R4GfxNativeImage = .{ .version = 1, .size = @sizeOf(gfx.R4GfxNativeImage), .deadline_ns = (try self.now()) + 3 * std.time.ns_per_s, .width = width, .height = height, .format = gfx.format_xrgb8888, .layout = 0 };
        if (native) {
            request.source_kind = gfx.source_create_native;
            request.source_address = @intFromPtr(&allocation);
        } else request.image = .{ .cpu_address = 0, .byte_length = bytes, .pitch = width * 4, .width = width, .height = height, .format = gfx.format_xrgb8888, .reserved = 0 };
        var result: gfx.R4GfxResource = undefined;
        try check(self.api.resource_create(&self.device, &request, &result));
        return result;
    }
    fn pipeline(self: *Scene, operation: u32) !gfx.R4GfxResource {
        var request = desc(gfx.resource_pipeline);
        request.operation = operation;
        var result: gfx.R4GfxResource = undefined;
        try check(self.api.resource_create(&self.device, &request, &result));
        return result;
    }
    fn cpuFill(self: *Scene, target: gfx.R4GfxResource, color: u32) !void {
        var draw = std.mem.zeroes(gfx.R4GfxDraw);
        draw.target = target;
        draw.pipeline = self.fill;
        draw.target_rect = .{ .x = 0, .y = 0, .width = width, .height = height };
        draw.color = color;
        var stats: gfx.R4GfxRenderStats = undefined;
        try check(self.api.render(&self.device, &.{ .commands = @intFromPtr(&draw), .command_count = 1, .flags = 0, .pixel_budget = width * height }, &stats));
        if (stats.backend != gfx.render_backend_software) return error.Backend;
    }
    fn finish(self: *Scene, job: *gfx.R4GfxJob, deadline: u64, stats: *Stats) !void {
        const begin = try self.now();
        while (true) {
            var info: gfx.R4GfxJobInfo = undefined;
            try check(self.api.job_info(&self.device, job, &info));
            if (info.phase == a.gfx_queue_phase_terminal and info.flags == 0) {
                if (info.result != a.gfx_queue_result_complete or info.backend != @as(u32, if (self.native) gfx.render_backend_amd else gfx.render_backend_software)) return error.Receipt;
                try check(self.api.job_release(&self.device, job));
                break;
            }
            if (try self.now() >= deadline) return error.Deadline;
            self.sys.sleepTicks(1);
        }
        stats.waits_ns += (try self.now()) - begin;
        stats.count += 1;
    }
    fn copy(self: *Scene, source: gfx.R4GfxResource, target: gfx.R4GfxResource, stats: *Stats) !void {
        var from: gfx.R4GfxResourceInfo = undefined;
        var to: gfx.R4GfxResourceInfo = undefined;
        try check(self.api.resource_info(&self.device, &source, &from));
        try check(self.api.resource_info(&self.device, &target, &to));
        const begin = try self.now();
        const deadline = begin + 3 * std.time.ns_per_s;
        var job: gfx.R4GfxJob = undefined;
        try check(self.api.copy_submit_ex(&self.device, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx), .copy = .{ .source = source, .target = target, .source_offset = 0, .target_offset = 0, .byte_length = width * 4, .deadline_ns = deadline }, .row_count = height, .dependency_count = 0, .source_pitch = from.image.pitch, .target_pitch = to.image.pitch, .dependencies = 0 }, &job));
        stats.calls_ns += (try self.now()) - begin;
        try self.finish(&job, deadline, stats);
    }
    fn render(self: *Scene, color: u32, stats: *Stats) !void {
        const begin = try self.now();
        if (!self.native) {
            try self.cpuFill(self.target, color);
            stats.calls_ns += (try self.now()) - begin;
            stats.count += 1;
            return;
        }
        const deadline = begin + 3 * std.time.ns_per_s;
        var request = std.mem.zeroes(gfx.R4GfxRenderRequest);
        request.version = 1;
        request.size = @sizeOf(gfx.R4GfxRenderRequest);
        request.target = self.target;
        request.pipeline = self.fill;
        request.color = color;
        request.opacity = 255;
        request.target_rect = .{ .x = 0, .y = 0, .width = width, .height = height };
        request.scissor = request.target_rect;
        request.deadline_ns = deadline;
        var job: gfx.R4GfxJob = undefined;
        try check(self.api.render_submit(&self.device, &request, &job));
        stats.calls_ns += (try self.now()) - begin;
        try self.finish(&job, deadline, stats);
    }
    fn report(self: *Scene, name: []const u8, stats: Stats) void {
        var text: [256]u8 = undefined;
        self.sys.println(std.fmt.bufPrint(&text, "AMD profile phase={s} count={d} caller-wall-ns={d} wait-wall-ns={d} gpu-duration=unknown", .{ name, stats.count, stats.calls_ns, stats.waits_ns }) catch return);
    }
    fn exercise(self: *Scene, pixels: []u32) !void {
        var info: gfx.R4GfxDeviceInfo = undefined;
        try check(self.api.device_info(&self.device, &info));
        if (info.backend != @as(u32, if (self.native) gfx.render_backend_amd else gfx.render_backend_software)) return error.Backend;
        if (self.native and info.gpu_operations & (gfx.device_gpu_copy_rows | gfx.device_gpu_render) != (gfx.device_gpu_copy_rows | gfx.device_gpu_render)) return error.Backend;
        var text: [256]u8 = undefined;
        self.sys.println(std.fmt.bufPrint(&text, "AMD profile scene=fill-copy-256x128-v1 backend={d} adapter={d} device={d} reset={d} iterations=32", .{ info.backend, info.adapter_id, info.device_generation, info.reset_generation }) catch return error.Format);
        self.source = try self.image(self.native);
        self.target = try self.image(self.native);
        self.staging = try self.image(false);
        self.fill = try self.pipeline(gfx.render_operation_fill);
        self.blit = try self.pipeline(gfx.render_operation_blit);
        var sampler = desc(gfx.resource_sampler);
        try check(self.api.resource_create(&self.device, &sampler, &self.sampler));
        try self.cpuFill(self.staging, 0x204060);
        var upload: Stats = .{};
        var rendering: Stats = .{};
        var copying: Stats = .{};
        var readback: Stats = .{};
        try self.copy(self.staging, self.source, &upload);
        var warmup: Stats = .{};
        try self.render(0x204060, &warmup);
        for (0..iterations) |index| try self.render(0x204060 + @as(u32, @intCast(index)), &rendering);
        try self.copy(self.target, self.source, &copying);
        try self.copy(self.source, self.staging, &readback);
        var view = desc(gfx.resource_image);
        view.flags = gfx.image_target;
        view.source_kind = gfx.source_borrow_cpu;
        view.source_generation = 1;
        view.image = .{ .cpu_address = @intFromPtr(pixels.ptr), .byte_length = bytes, .pitch = width * 4, .width = width, .height = height, .format = gfx.format_xrgb8888, .reserved = 0 };
        var target: gfx.R4GfxResource = undefined;
        try check(self.api.resource_create(&self.device, &view, &target));
        var draw = std.mem.zeroes(gfx.R4GfxDraw);
        draw.source = self.staging;
        draw.target = target;
        draw.pipeline = self.blit;
        draw.sampler = self.sampler;
        draw.opacity = 255;
        draw.source_rect = .{ .x = 0, .y = 0, .width = width, .height = height };
        draw.target_rect = draw.source_rect;
        var result: gfx.R4GfxRenderStats = undefined;
        try check(self.api.render(&self.device, &.{ .commands = @intFromPtr(&draw), .command_count = 1, .flags = 0, .pixel_budget = width * height }, &result));
        for (pixels) |pixel| if (pixel & 0xffffff != 0x204060 + iterations - 1) return error.Pixels;
        self.report("upload", upload);
        self.report("render", rendering);
        self.report("copy", copying);
        self.report("readback", readback);
        try check(self.api.device_info(&self.device, &info));
        var memory: gfx.R4GfxMemoryInfo = undefined;
        try check(self.api.memory_info(&self.device, &memory));
        self.sys.println(std.fmt.bufPrint(&text, "AMD profile bytes: cpu-read={d} cpu-write={d} gpu-copy={d} resident={d} staging={d} pinned={d}", .{ info.cpu_read_bytes, info.cpu_write_bytes, info.gpu_copy_bytes, memory.resident_bytes, memory.system_bytes, memory.pinned_bytes }) catch return error.Format);
        self.sys.println("AMD profile pixels=32768 verified; present=not-requested; clocks=/POWER; allocation and warm-up excluded from phase intervals");
    }
};
pub fn run(app: *r4os.App, native: bool) i32 {
    const sys = app.system();
    const allocator = sys.allocator();
    const api = gfx.DeviceV1Client.init(app.startContext()) catch return 1;
    const size = api.storage_size();
    if (size == 0 or size > std.math.maxInt(usize)) return 1;
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(size)) catch return 1;
    @memset(storage, 0);
    const pixels = allocator.alloc(u32, width * height) catch {
        allocator.free(storage);
        return 1;
    };
    var scene: Scene = .{ .sys = sys, .api = api, .device = undefined, .native = native };
    if (api.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr), .storage_bytes = storage.len, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = if (native) 0 else gfx.device_software_only }, &scene.device) != gfx.status_ok) {
        allocator.free(pixels);
        allocator.free(storage);
        return 1;
    }
    var passed = true;
    scene.exercise(pixels) catch |err| {
        sys.write("AMD profile failed: ");
        sys.println(@errorName(err));
        passed = false;
    };
    const deadline = (sys.monotonicNanoseconds() orelse 0) + 3 * std.time.ns_per_s;
    var closed = false;
    while (true) {
        if (api.device_close(&scene.device) == gfx.status_ok) {
            closed = true;
            break;
        }
        if ((sys.monotonicNanoseconds() orelse deadline) >= deadline) break;
        sys.sleepTicks(1);
    }
    if (closed) {
        allocator.free(pixels);
        allocator.free(storage);
    } // Held GPU/copy endpoints outlive a failed close.
    sys.println(if (passed and closed) "AMD profile: OK resources=closed" else "AMD profile: FAILED");
    return if (passed and closed) 0 else 1;
}
