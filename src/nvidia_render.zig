// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Public fixed-shader rendering against the original frozen CPU/f64 images.
//! No receiver query, output activation or presentation.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const cases = @import("r4nv_reference");
const a = r4os.abi;
const source_bytes = cases.source_bytes + 32;
const target_bytes = cases.target_bytes + 64;

fn check(rc: i32) !void {
    if (rc != gfx.status_ok) return error.Graphics;
}
fn platform(rc: i32) !void {
    if (rc != a.gfx_buffer_result_ok) return error.Platform;
}
fn description(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1;
    value.size = @sizeOf(gfx.R4GfxResourceDesc);
    value.kind = kind;
    return value;
}
fn signed(rect: anytype) gfx.R4GfxSignedRect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

pub const Probe = struct {
    sys: r4os.r4sys.Context,
    memory: r4os.gfx_buffers.Context,
    api: gfx.DeviceV1Client,
    device: gfx.R4GfxDevice = undefined,
    identity: gfx.R4GfxDeviceInfo = undefined,
    stage: []const u8 = "open",
    clock: u64 = 0,
    ce: u32 = 0,
    gr: u32 = 0,
    pending_closes: u32 = 0,
    compared: u64 = 0,

    pub fn line(self: *Probe, comptime format: []const u8, args: anytype) void {
        var text: [320]u8 = undefined;
        self.sys.println(std.fmt.bufPrint(&text, format, args) catch "NVIDIA render: report overflow");
    }
    pub fn now(self: *Probe) !u64 {
        const value = self.sys.monotonicNanoseconds() orelse return error.Clock;
        if (value == 0 or value == std.math.maxInt(u64) or value < self.clock) return error.Clock;
        self.clock = value;
        return value;
    }
    pub fn deadline(self: *Probe) !u64 {
        return std.math.add(u64, try self.now(), 3 * std.time.ns_per_s);
    }
    pub fn bind(self: *Probe) !void {
        self.stage = "backend";
        try check(self.api.device_info(&self.device, &self.identity));
        if (self.identity.backend != gfx.render_backend_nvidia or self.identity.adapter_id == 0 or
            self.identity.adapter_id == 0xffff or self.identity.gpu_operations &
            (gfx.device_gpu_render | gfx.device_gpu_copy_rows | gfx.device_gpu_copy_layout) !=
            (gfx.device_gpu_render | gfx.device_gpu_copy_rows | gfx.device_gpu_copy_layout)) return error.NativeUnavailable;
    }
    pub fn finish(self: *Probe, job: *const gfx.R4GfxJob, limit: u64, render: bool) !void {
        while (true) {
            var info: gfx.R4GfxJobInfo = undefined;
            try check(self.api.job_info(&self.device, job, &info));
            if (info.phase == a.gfx_queue_phase_terminal and info.flags == 0) {
                if (info.result != a.gfx_queue_result_complete or info.backend != gfx.render_backend_nvidia or
                    info.timeline == 0 or info.point == 0 or info.device_generation != self.identity.device_generation or
                    info.reset_generation != self.identity.reset_generation) return error.Receipt;
                var identity: gfx.R4GfxDeviceInfo = undefined;
                try check(self.api.device_info(&self.device, &identity));
                if (identity.backend != self.identity.backend or identity.adapter_id != self.identity.adapter_id or
                    identity.device_generation != self.identity.device_generation or identity.reset_generation != self.identity.reset_generation) return error.Stale;
                try check(self.api.job_release(&self.device, job));
                if (render) self.gr += 1 else self.ce += 1;
                return;
            }
            if (try self.now() >= limit) return error.Deadline;
            self.sys.sleepTicks(1);
        }
    }
    pub fn system(self: *Probe, width: u32, height: u32, pitch: u32, format: u32, data: []const u8) !a.GfxBufferReference {
        var reference: a.GfxBufferReference = .{};
        try platform(self.memory.create(&.{ .width = width, .height = height, .format = format,
            .plane_count = 1, .plane_pitches = .{pitch, 0, 0, 0}, .byte_length = data.len, .usage = 15 }, &reference));
        errdefer _ = self.memory.release(&reference.reference);
        var map: a.GfxBufferMap = .{};
        try platform(self.memory.map(&reference.reference, a.gfx_buffer_map_write, 0, data.len, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != data.len or map.cpu_address == 0) return error.Map;
        @memcpy(@as([*]u8, @ptrFromInt(map.cpu_address))[0..data.len], data);
        try platform(self.memory.unmap(&map.lease));
        map.lease = .{};
        return reference;
    }
    pub fn import(self: *Probe, reference: a.GfxBufferHandle) !gfx.R4GfxResource {
        var desc = description(gfx.resource_image);
        desc.flags = gfx.image_target;
        desc.source_kind = gfx.source_import_buffer;
        desc.source_address = @intFromPtr(&reference);
        var resource: gfx.R4GfxResource = undefined;
        try check(self.api.resource_create(&self.device, &desc, &resource));
        return resource;
    }
    pub fn prepare(self: *Probe, resource: gfx.R4GfxResource, target: bool, tiled: bool,
        ready: *gfx.R4GfxCopyFence, limit: u64) !gfx.R4GfxPreparedImage
    {
        var output: gfx.R4GfxPreparedImage = undefined;
        try check(self.api.image_prepare(&self.device, &.{
            .version = 1, .size = @sizeOf(gfx.R4GfxImagePrepareRequest), .source = resource,
            .uses = if (target) gfx.prepare_use_render_target else gfx.prepare_use_texture,
            .preference = if (tiled) gfx.prepare_layout_blocklinear else gfx.prepare_layout_linear,
            .flags = gfx.prepare_force_copy, .dependency_count = 0, .dependencies = 0,
            .deadline_ns = limit, .byte_budget = 65536,
            .ready_dependencies = @intFromPtr(ready), .ready_capacity = 1, .reserved = 0,
        }, &output));
        if (output.flags & gfx.prepared_copy_pending == 0 or output.flags & gfx.prepared_software != 0 or
            output.dependency_count != 1) return error.Preparation;
        var info: gfx.R4GfxResourceInfo = undefined;
        try check(self.api.resource_info(&self.device, &output.image, &info));
        // DEVICE_V1 exposes a BO identity and image geometry, not a BO
        // reference that could be imported/described. image_prepare validates
        // the actual native descriptor against the requested layout itself.
        // The two profiles have distinct pitches for these small images.
        const bytes: u64 = if (info.image.format == gfx.format_r8) 1 else 4;
        const pitch = std.mem.alignForward(u64, @as(u64, info.image.width) * bytes, if (tiled) 64 else 256);
        if (info.source_kind != gfx.source_create_native or info.buffer_id == 0 or info.buffer_generation == 0 or
            info.image.cpu_address != 0 or info.image.pitch != pitch or info.image.byte_length != 65536) return error.Layout;
        return output;
    }
    fn reuse(self: *Probe, resource: gfx.R4GfxResource, target: bool, limit: u64) !void {
        var result: gfx.R4GfxPreparedImage = undefined;
        try check(self.api.image_prepare(&self.device, &.{
            .version = 1, .size = @sizeOf(gfx.R4GfxImagePrepareRequest), .source = resource,
            .uses = if (target) gfx.prepare_use_render_target else gfx.prepare_use_texture,
            .preference = gfx.prepare_layout_compatible, .flags = 0, .dependency_count = 0,
            .dependencies = 0, .deadline_ns = limit, .byte_budget = 0,
            .ready_dependencies = 0, .ready_capacity = 0, .reserved = 0,
        }, &result));
        if (result.flags & gfx.prepared_reused == 0 or result.dependency_count != 0 or
            !std.meta.eql(result.image, resource) or result.job.slot != 0) return error.Reuse;
        try check(self.api.resource_release(&self.device, &result.image));
    }
    fn compare(self: *Probe, reference: a.GfxBufferHandle, index: usize) !u8 {
        var map: a.GfxBufferMap = .{};
        try platform(self.memory.map(&reference, a.gfx_buffer_map_read, 0, target_bytes, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != target_bytes or map.cpu_address == 0) return error.Map;
        const pixels = @as([*]const u8, @ptrFromInt(map.cpu_address))[0..target_bytes];
        const expected = cases.expectedPixels(index);
        const scene = cases.scenes[index];
        var maximum: u8 = 0;
        var mismatches: usize = 0;
        for (pixels, 0..) |actual, at| {
            const x = at % 128;
            const y = at / 128;
            const bpp: usize = if (scene.format == .r8) 1 else 4;
            const drawn = at < expected.len and x < 32 * bpp and scene.inside(@intCast(x / bpp), @intCast(y));
            const want: u8 = if (at < expected.len) expected[at] else 0xcc;
            const delta = @max(actual, want) - @min(actual, want);
            const limit: u8 = if (drawn) scene.tolerance else 0;
            if (delta > limit) {
                if (mismatches < 4) self.line("NVIDIA render pixel: scene={s} byte={d} expected={d} actual={d} tolerance={d}", .{scene.name, at, want, actual, limit});
                mismatches += 1;
            }
            maximum = @max(maximum, delta);
        }
        try platform(self.memory.unmap(&map.lease));
        map.lease = .{};
        if (mismatches != 0) return error.Pixels;
        self.compared += pixels.len;
        return maximum;
    }
    fn exercise(self: *Probe, index: usize, tiled: bool) !void {
        try self.bind();
        const scene = cases.scenes[index];
        const solid_fill = scene.solid and scene.blend == .replace;
        var input: [source_bytes]u8 = undefined;
        var initial: [target_bytes]u8 = undefined;
        cases.initialize(scene, &input, &initial);
        // The public OVER pipeline samples a source. Match the frozen CPU
        // reference's one-texel representation of a constant OVER color.
        if (scene.solid and !solid_fill) std.mem.writeInt(u32, input[0..4], 0x80402010, .little);
        var references: [3]a.GfxBufferReference = @splat(.{});
        defer for (&references) |*ref| if (ref.reference.id != 0) { _ = self.memory.release(&ref.reference); };
        self.stage = "system-images";
        references[0] = try self.system(7, 5, 32, @intFromEnum(scene.source_format), &input);
        references[1] = try self.system(32, 24, 128, @intFromEnum(scene.format), &initial);
        @memset(&initial, 0xcc);
        references[2] = try self.system(32, 24, 128, @intFromEnum(scene.format), &initial);
        const source = try self.import(references[0].reference);
        const target = try self.import(references[1].reference);
        const readback = try self.import(references[2].reference);
        const limit = try self.deadline();
        var ready: [2]gfx.R4GfxCopyFence = undefined;
        var source_prepared: gfx.R4GfxPreparedImage = undefined;
        self.stage = "prepare";
        if (!solid_fill) source_prepared = try self.prepare(source, false, tiled, &ready[0], limit);
        const target_prepared = try self.prepare(target, true, tiled, &ready[1], limit);
        try self.reuse(target_prepared.image, true, limit);
        if (!solid_fill) try self.reuse(source_prepared.image, false, limit);
        var pipeline_desc = description(gfx.resource_pipeline);
        pipeline_desc.operation = if (solid_fill) gfx.render_operation_fill else if (scene.blend == .over) gfx.render_operation_over else gfx.render_operation_blit;
        var pipeline: gfx.R4GfxResource = undefined;
        try check(self.api.resource_create(&self.device, &pipeline_desc, &pipeline));
        var sampler_desc = description(gfx.resource_sampler);
        sampler_desc.sampler = if (scene.filter == .bilinear) gfx.render_sampler_bilinear else gfx.render_sampler_nearest;
        var sampler: gfx.R4GfxResource = undefined;
        if (!solid_fill) try check(self.api.resource_create(&self.device, &sampler_desc, &sampler));
        var request = std.mem.zeroes(gfx.R4GfxRenderRequest);
        request.version = 1;
        request.size = @sizeOf(gfx.R4GfxRenderRequest);
        request.target = target_prepared.image;
        request.pipeline = pipeline;
        request.target_rect = signed(scene.destination);
        request.scissor = signed(scene.scissor);
        request.opacity = scene.opacity;
        request.transfer = @intFromEnum(scene.transfer);
        request.deadline_ns = limit;
        request.dependency_count = if (solid_fill) 1 else 2;
        request.dependencies = if (solid_fill) @intFromPtr(&ready[1]) else @intFromPtr(&ready);
        if (solid_fill) request.color = 0x80402010 else {
            request.source = source_prepared.image;
            request.sampler = sampler;
            request.source_rect = if (scene.solid) .{ .x = 0, .y = 0, .width = 1, .height = 1 } else signed(scene.source_rect);
        }
        self.stage = "render-submit";
        var render_job: gfx.R4GfxJob = undefined;
        try check(self.api.render_submit(&self.device, &request, &render_job));
        var fence: gfx.R4GfxCopyFence = undefined;
        try check(self.api.job_fence(&self.device, &render_job, &fence));
        var native: gfx.R4GfxResourceInfo = undefined;
        try check(self.api.resource_info(&self.device, &target_prepared.image, &native));
        const bpp: u32 = if (scene.format == .r8) 1 else 4;
        var read_job: gfx.R4GfxJob = undefined;
        self.stage = "dependent-readback";
        try check(self.api.copy_submit_ex(&self.device, &.{
            .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx),
            .copy = .{ .source = target_prepared.image, .target = readback, .source_offset = 0,
                .target_offset = 0, .byte_length = 32 * bpp, .deadline_ns = limit },
            .row_count = 24, .source_pitch = native.image.pitch, .target_pitch = 128,
            .dependency_count = 1, .dependencies = @intFromPtr(&fence),
        }, &read_job));
        var pending: gfx.R4GfxJobInfo = undefined;
        try check(self.api.job_info(&self.device, &render_job, &pending));
        if (pending.phase != a.gfx_queue_phase_terminal or pending.flags != 0) self.pending_closes += 1;
        self.stage = "caller-close";
        try check(self.api.resource_release(&self.device, &target_prepared.image));
        if (!solid_fill) try check(self.api.resource_release(&self.device, &source_prepared.image));
        try check(self.api.resource_release(&self.device, &source));
        try check(self.api.resource_release(&self.device, &target));
        self.stage = "completion";
        try self.finish(&read_job, limit, false);
        try self.finish(&render_job, limit, true);
        try self.finish(&target_prepared.job, limit, false);
        if (!solid_fill) try self.finish(&source_prepared.job, limit, false);
        self.stage = "reference-pixels";
        const maximum = try self.compare(references[2].reference, index);
        self.line("NVIDIA render case: OK {s} layout={s} max={d}/{d} LSB bytes={d} fence={d}:{d} device={d} reset={d} source-target-close=before-wait prepare=copy reuse=budget0",
            .{scene.name, if (tiled) "blocklinear" else "linear", maximum, scene.tolerance, target_bytes,
                fence.timeline, fence.point, fence.device_generation, fence.reset_generation});
        try check(self.api.resource_release(&self.device, &readback));
        try check(self.api.resource_release(&self.device, &pipeline));
        if (!solid_fill) try check(self.api.resource_release(&self.device, &sampler));
        for (&references) |*ref| {
            try platform(self.memory.release(&ref.reference));
            ref.* = .{};
        }
    }
};

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
    if (memory.stats(&before) != 1 or before.allocating_bytes != 0 or before.destroying_bytes != 0 or before.retained_bytes != 0) {
        allocator.free(storage);
        return 1;
    }
    const runtime = @import("resource_balance.zig").Runtime.capture(app) orelse { allocator.free(storage); return 1; };
    var probe: Probe = .{ .sys = sys, .memory = memory, .api = api };
    var passed = true;
    outer: for (0..2) |layout| {
        for (0..cases.scenes.len) |index| {
            if (api.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig),
                .storage_address = @intFromPtr(storage.ptr), .storage_bytes = size,
                .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = 0 }, &probe.device) != gfx.status_ok) {
                passed = false;
                break :outer;
            }
            probe.exercise(index, layout != 0) catch |err| {
                probe.line("NVIDIA render failed: case={s} layout={d} stage={s} error={s} CE={d} GR={d}", .{
                    cases.scenes[index].name, layout, probe.stage, @errorName(err), probe.ce, probe.gr,
                });
                passed = false;
            };
            const limit = probe.deadline() catch 0;
            var closed = false;
            while (true) {
                if (api.device_close(&probe.device) == gfx.status_ok) { closed = true; break; }
                if ((probe.now() catch limit) >= limit) break;
                sys.sleepTicks(1);
            }
            if (!closed) {
                sys.println("NVIDIA render device: retained after bounded close failure");
                return 1;
            }
            passed = @import("resource_balance.zig").waitBuffers(&sys, &memory, before) and passed;
            if (!passed) break :outer;
        }
    }
    allocator.free(storage);
    passed = @import("resource_balance.zig").Runtime.balanced(runtime, app) and passed;
    if (passed and probe.gr == 28 and probe.ce == 82 and probe.compared == 87808 and probe.pending_closes != 0) {
        probe.line("NVIDIA render: OK fixed-scenes=14 layouts=2 CE={d} GR={d} compared-bytes={d} pending-closes={d} tolerance=original untouched=exact balance=complete present=none",
            .{probe.ce, probe.gr, probe.compared, probe.pending_closes});
        return 0;
    }
    sys.println("NVIDIA render: FAILED");
    return 1;
}
