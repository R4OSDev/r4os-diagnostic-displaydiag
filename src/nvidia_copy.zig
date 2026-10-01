// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Public R4GFX dependent row copies. No receiver query or presentation.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const a = r4os.abi;
const row_bytes = 69;
const rows = 19;
const upload_bytes = 83 * 24;
const readback_bytes = 79 * 25;
const round_bytes = 3 * row_bytes * rows;

fn check(rc: i32) !void { if (rc != gfx.status_ok) return error.Graphics; }
fn platform(rc: i32) !void { if (rc != a.gfx_buffer_result_ok) return error.Platform; }
fn pattern(index: usize, round: u32) u8 {
    return @truncate(index * 197 + (index / 11) * 43 + @as(usize, round) * 97);
}
const Probe = struct {
    sys: r4os.r4sys.Context,
    memory: r4os.gfx_buffers.Context,
    queues: r4os.gfx_queue.Context,
    api: gfx.DeviceV1Client,
    device: gfx.R4GfxDevice = undefined,
    identity: gfx.R4GfxDeviceInfo = undefined,
    backend: a.GfxBackendInfo = .{},
    stage: []const u8 = "open",
    last_clock: u64 = 0,
    completed: u32 = 0,
    exact_bytes: u64 = 0,
    cpu_initialized: u64 = 0,
    cpu_compared: u64 = 0,

    fn line(self: *Probe, comptime format: []const u8, args: anytype) void {
        var storage: [320]u8 = undefined;
        self.sys.println(std.fmt.bufPrint(&storage, format, args) catch "NVIDIA copy: diagnostic line overflow");
    }
    fn now(self: *Probe) !u64 {
        const value = self.sys.monotonicNanoseconds() orelse return error.Clock;
        if (value == 0 or value == std.math.maxInt(u64) or value < self.last_clock) return error.Clock;
        self.last_clock = value;
        return value;
    }
    fn deadline(self: *Probe) !u64 { return std.math.add(u64, try self.now(), 3 * std.time.ns_per_s); }
    fn identityValid(self: *Probe) !void {
        var value: gfx.R4GfxDeviceInfo = undefined;
        try check(self.api.device_info(&self.device, &value));
        if (value.backend != gfx.render_backend_nvidia or value.adapter_id != self.identity.adapter_id or
            value.device_generation != self.identity.device_generation or value.reset_generation != self.identity.reset_generation)
            return error.Stale;
    }
    fn system(self: *Probe, pitch: u32, height: u32) !a.GfxBufferReference {
        var reference: a.GfxBufferReference = .{};
        try platform(self.memory.create(&.{ .width = pitch, .height = height, .format = a.gfx_buffer_format_r8,
            .plane_count = 1, .plane_pitches = .{pitch, 0, 0, 0}, .byte_length = @as(u64, pitch) * height,
            .usage = 15 }, &reference));
        return reference;
    }
    fn rawSystem(self: *Probe, bytes: u64) !a.GfxBufferReference {
        var reference: a.GfxBufferReference = .{};
        try platform(self.memory.create(&.{ .byte_length = bytes, .usage = 15 }, &reference));
        return reference;
    }
    fn native(self: *Probe, width: u32, height: u32, tiled: bool) !a.GfxBufferReference {
        var status: a.GfxNativeStatus = .{};
        try platform(self.memory.nativeStart(&.{ .adapter_id = self.identity.adapter_id,
            .memory_generation = self.backend.memory_generation, .deadline_ns = try self.deadline(), .kind = 1,
            .width = width, .height = height, .format = a.gfx_buffer_format_r8, .usage = 12,
            .layout = if (tiled) 1 else 0 }, &status));
        const request = status.request;
        var received = false;
        defer if (!received) { _ = self.memory.nativeClose(&request); };
        try platform(self.memory.nativeWait(&request, self.sys.ticksFromMilliseconds(3000), &status));
        try platform(status.result);
        var reference: a.GfxBufferReference = .{};
        try platform(self.memory.nativeReceive(&request, &reference));
        received = true;
        return reference;
    }
    fn import(self: *Probe, reference: a.GfxBufferHandle) !gfx.R4GfxResource {
        var request = std.mem.zeroes(gfx.R4GfxResourceDesc);
        request.version = 1; request.size = @sizeOf(gfx.R4GfxResourceDesc); request.kind = gfx.resource_image;
        request.flags = gfx.image_target; request.source_kind = gfx.source_import_buffer; request.source_address = @intFromPtr(&reference);
        var resource: gfx.R4GfxResource = undefined;
        try check(self.api.resource_create(&self.device, &request, &resource));
        return resource;
    }
    fn initialize(self: *Probe, reference: a.GfxBufferHandle, bytes: usize, round: ?u32) !void {
        var map: a.GfxBufferMap = .{};
        try platform(self.memory.map(&reference, 1, 0, bytes, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != bytes or map.cpu_address == 0) return error.Map;
        const data: [*]u8 = @ptrFromInt(map.cpu_address);
        for (data[0..bytes], 0..) |*value, index| value.* = if (round) |number| pattern(index, number) else 0xa5;
        try platform(self.memory.unmap(&map.lease)); map.lease = .{};
        self.cpu_initialized += bytes;
    }
    fn compare(self: *Probe, reference: a.GfxBufferHandle, bytes: usize, round: u32, upload: bool) !void {
        var map: a.GfxBufferMap = .{};
        try platform(self.memory.map(&reference, 0, 0, bytes, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != bytes or map.cpu_address == 0) return error.Map;
        const data: [*]const u8 = @ptrFromInt(map.cpu_address);
        var mismatches: usize = 0;
        for (data[0..bytes], 0..) |actual, index| {
            const relative = index -| 37;
            const expected: u8 = if (upload) pattern(index, round)
                else if (index >= 37 and relative / 79 < rows and relative % 79 < row_bytes)
                    pattern(17 + (relative / 79) * 83 + relative % 79, round) else 0xa5;
            if (actual != expected) {
                if (mismatches < 4) self.line("NVIDIA copy mismatch: upload={} offset={d} expected={x:0>2} actual={x:0>2}", .{upload, index, expected, actual});
                mismatches += 1;
            }
        }
        try platform(self.memory.unmap(&map.lease)); map.lease = .{};
        if (mismatches != 0) return error.Bytes;
        self.exact_bytes += bytes; self.cpu_compared += bytes;
    }
    fn rowRequest(source: a.GfxBufferHandle, target: a.GfxBufferHandle, from: u64, to: u64, from_pitch: u64, to_pitch: u64, limit: u64) a.GfxSubmission {
        return .{ .operation = a.gfx_queue_operation_copy_rows, .source = source, .target = target,
            .source_offset = from, .target_offset = to, .byte_length = row_bytes, .deadline_ns = limit,
            .row_count = rows, .source_pitch = from_pitch, .target_pitch = to_pitch };
    }
    fn finishCommon(self: *Probe, fence: *const a.GfxFence, limit: u64) !void {
        while (true) {
            var receipt: a.GfxFenceStatus = .{};
            try platform(self.queues.query(fence, &receipt));
            if (!std.meta.eql(receipt.fence, fence.*)) return error.Receipt;
            if (receipt.phase == a.gfx_queue_phase_terminal and receipt.flags == 0) {
                if (receipt.result != a.gfx_queue_result_complete or fence.timeline == 0 or fence.point == 0 or
                    fence.device_generation != self.identity.device_generation or fence.reset_generation != self.identity.reset_generation) return error.Receipt;
                try self.identityValid();
                try platform(self.queues.release(fence));
                self.completed += 1;
                return;
            }
            if (try self.now() >= limit) return error.Deadline;
            self.sys.sleepTicks(1);
        }
    }
    fn finish(self: *Probe, job: *const gfx.R4GfxJob, limit: u64, result: i32) !gfx.R4GfxJobInfo {
        while (true) {
            var receipt: gfx.R4GfxJobInfo = undefined;
            try check(self.api.job_info(&self.device, job, &receipt));
            if (receipt.phase == a.gfx_queue_phase_terminal and receipt.flags == 0) {
                if (receipt.result != result or receipt.backend != gfx.render_backend_nvidia or receipt.timeline == 0 or receipt.point == 0 or
                    receipt.device_generation != self.identity.device_generation or receipt.reset_generation != self.identity.reset_generation)
                    return error.Receipt;
                try self.identityValid();
                try check(self.api.job_release(&self.device, job));
                if (result == a.gfx_queue_result_complete) self.completed += 1;
                return receipt;
            }
            if (try self.now() >= limit) return error.Deadline;
            self.sys.sleepTicks(1);
        }
    }
    fn bind(self: *Probe) !void {
        self.stage = "backend";
        try check(self.api.device_info(&self.device, &self.identity));
        self.backend = for (0..a.gfx_queue_backend_capacity) |index| {
            var value: a.GfxBackendInfo = .{};
            if (self.queues.backendInfo(@intCast(index), &value) == 1 and value.binding.adapter_id == self.identity.adapter_id and
                value.binding.milestone == a.gfx_queue_milestone_device_execution and value.memory_generation != 0 and
                value.binding.device_generation == self.identity.device_generation and value.binding.reset_generation == self.identity.reset_generation)
                break value;
        } else return error.NativeUnavailable;
        if (self.identity.backend != gfx.render_backend_nvidia or self.identity.adapter_id == 0 or self.backend.memory_generation == 0 or
            self.identity.gpu_operations & (gfx.device_gpu_copy_rows | gfx.device_gpu_copy_layout) != (gfx.device_gpu_copy_rows | gfx.device_gpu_copy_layout)) return error.NativeUnavailable;
    }
    fn exercise(self: *Probe, tiled: bool, first_height: u32) !void {
        try self.bind();
        self.stage = "allocate";
        var references: [4]a.GfxBufferReference = @splat(.{});
        defer for (&references) |*reference| if (reference.reference.id != 0) { _ = self.memory.release(&reference.reference); };
        // These original vectors have a raw byte prefix before the first
        // pitched row. R4GFX image resources have a zero-origin image plane;
        // use the public BO queue for raw spans, without forging image bounds.
        references[0] = try self.rawSystem(upload_bytes);
        references[1] = try self.native(129, first_height, tiled);
        references[2] = try self.native(193, 41, tiled);
        references[3] = try self.rawSystem(readback_bytes);
        var descriptions: [4]a.GfxBufferDescriptor = @splat(.{});
        for (references, &descriptions) |reference, *description| {
            try platform(self.memory.describe(&reference.reference, description));
        }
        const first = descriptions[1]; const second = descriptions[2];
        const one_pitch = first.plane_pitches[0]; const two_pitch = second.plane_pitches[0];
        if (first.location != a.gfx_buffer_location_device_local or second.location != a.gfx_buffer_location_device_local or
            first.device_generation != self.backend.memory_generation or second.device_generation != self.backend.memory_generation or
            first.byte_length != 65536 or second.byte_length != 65536 or
            one_pitch != @as(u64, if (tiled) 192 else 256) or two_pitch != 256 or
            first.modifier & 15 != @as(u64, if (!tiled) 0 else if (first_height == 41) 2 else 1) or
            second.modifier & 15 != @as(u64, if (tiled) 2 else 0)) return error.Layout;
        const source_y: u64 = if (first_height == 21) 2 else 3;
        const from = source_y * one_pitch + 57; const to = 9 * two_pitch + 93;
        var queue: a.GfxQueueHandle = .{};
        try platform(self.queues.open(&.{ .adapter_id = self.identity.adapter_id, .capacity = 3, .milestone = a.gfx_queue_milestone_device_execution,
            .device_generation = self.identity.device_generation, .reset_generation = self.identity.reset_generation }, &queue));
        defer if (queue.timeline != 0) { _ = self.queues.close(&queue); };
        var before: a.GfxBufferStats = .{};
        try platform(self.memory.stats(&before));
        var cached: a.GfxBufferStats = .{};
        const started = try self.now();
        for (1..3) |round| {
            self.stage = "initialize";
            try self.initialize(references[0].reference, upload_bytes, @intCast(round));
            try self.initialize(references[3].reference, readback_bytes, null);
            const limit = try self.deadline();
            var requests = [_]a.GfxSubmission{
                rowRequest(references[0].reference, references[1].reference, 17, from, 83, one_pitch, limit),
                rowRequest(references[1].reference, references[2].reference, from, to, one_pitch, two_pitch, limit),
                rowRequest(references[2].reference, references[3].reference, to, 37, two_pitch, 79, limit),
            };
            var fences: [3]a.GfxFence = undefined;
            self.stage = "dependent-copy";
            for (&requests, &fences, 0..) |*submission, *fence, index| {
                if (index != 0) { submission.dependency_count = 1; submission.dependencies[0] = fences[index - 1]; }
                var status: a.GfxFenceStatus = .{};
                const rc = self.queues.submit(&queue, submission, &status);
                if (rc != 1) { self.line("NVIDIA copy admission: stage={d} rc={d}", .{index, rc}); return error.Admission; }
                fence.* = status.fence;
            }
            // All three requests were submitted through the public API before
            // waiting for the final fence. A GET pointer is never consulted.
            try self.finishCommon(&fences[2], limit);
            try self.finishCommon(&fences[1], limit);
            try self.finishCommon(&fences[0], limit);
            const last = fences[2];
            self.stage = "readback";
            try self.compare(references[3].reference, readback_bytes, @intCast(round), false);
            try self.compare(references[0].reference, upload_bytes, @intCast(round), true);
            var state: gfx.R4GfxDeviceInfo = undefined;
            try check(self.api.device_info(&self.device, &state));
            // This raw matrix bypasses the R4GFX job counter. Do not present
            // caller-counted completed row bytes as a library counter.
            if (state.gpu_copy_bytes != 0 or state.cpu_read_bytes != 0 or state.cpu_write_bytes != 0 or
                state.imports != 0 or state.upload_bytes != 0) return error.Counters;
            var current: a.GfxBufferStats = .{};
            try platform(self.memory.stats(&current));
            if (current.objects != before.objects or
                current.device_bytes != before.device_bytes or current.system_bytes != before.system_bytes or current.retained_bytes != 0) return error.Growth;
            if (round == 1) cached = current else if (current.references > cached.references or current.leases > cached.leases or
                current.device_mapped_bytes > cached.device_mapped_bytes) return error.MappingGrowth;
            self.line("NVIDIA copy round: OK tiled={} heights={d}/41 round={d} fence={d}:{d} queue={d} reset={d} memory={d} completed-row-bytes={d} R4GFX-copy-bytes=0 public=BO-queue",
                .{tiled, first_height, round, last.timeline, last.point, last.device_generation, last.reset_generation, self.backend.memory_generation, round * round_bytes});
        }
        if (tiled) {
            self.stage = "reject-raw";
            var rejected: a.GfxFenceStatus = .{ .result = 79 };
            const untouched = rejected;
            const limit = try self.deadline();
            if (self.queues.submit(&queue, &.{ .operation = a.gfx_queue_operation_copy, .source = references[1].reference, .target = references[2].reference,
                .source_offset = from, .target_offset = to, .byte_length = row_bytes, .deadline_ns = limit }, &rejected) != a.gfx_queue_error_unsupported or
                !std.meta.eql(untouched, rejected)) return error.RawAccepted;
            self.stage = "reject-stride";
            const invalid = rowRequest(references[1].reference, references[2].reference, from, to, one_pitch + 1, two_pitch, limit);
            if (self.queues.submit(&queue, &invalid, &rejected) != a.gfx_queue_error_invalid or !std.meta.eql(untouched, rejected)) return error.StrideAccepted;
            self.line("NVIDIA copy rejection: OK raw=unsupported stride=invalid admission=denied output=unchanged GPU-submit=none", .{});
        }
        self.stage = "release";
        try platform(self.queues.close(&queue)); queue = .{};
        for (&references) |*reference| if (reference.reference.id != 0) { try platform(self.memory.release(&reference.reference)); reference.* = .{}; };
        self.line("NVIDIA copy layout: OK tiled={} size=129x{d}/193x41 pitches={d}/{d} gob-log2={d}/{d} origins=57,{d}/93,9 bytes=69x19 RAM-pitches=83/79 rounds=2 ns={d}",
            .{tiled, first_height, one_pitch, two_pitch, first.modifier & 15, second.modifier & 15, source_y, (try self.now()) - started});
    }
    fn shared(self: *Probe, draw: *const r4os.r4draw.Context) !void {
        try self.bind();
        self.stage = "raster-create";
        var handle: a.GuiSharedRasterHandle = .{};
        try check(draw.guiSharedRasterCreate(&.{ .format = a.gui_shared_raster_format_xrgb32,
            .width = 4, .height = 4, .stride_bytes = 16, .data_bytes = 64 }, &handle));
        defer if (handle.id != 0) { _ = draw.guiSharedRasterDestroy(&handle); };
        var frame_live = false;
        defer if (frame_live) {
            if (draw.guiFrameBegin() == a.gui_frame_result_ok) _ = draw.guiFrameCommit();
        };
        var leases: [4]a.GuiSharedRasterMap = @splat(.{});
        defer for (&leases) |*lease| if (lease.lease.lease_token != 0) { _ = draw.guiSharedRasterRelease(&lease.lease); };
        var sources: [2]gfx.R4GfxResource = undefined;
        var infos: [2]gfx.R4GfxResourceInfo = undefined;
        for (0..2) |round| {
            self.stage = "raster-publish";
            var write: a.GuiSharedRasterWriteMap = .{};
            try check(draw.guiSharedRasterMapWrite(&handle, &write));
            if (write.byte_length != 64 or write.data_address == 0) return error.Raster;
            const pixels: [*]u8 = @ptrFromInt(write.data_address);
            for (pixels[0..64], 0..) |*byte, index| byte.* = pattern(index, @intCast(round + 1));
            self.cpu_initialized += 64;
            var generation: u64 = 0;
            try check(draw.guiSharedRasterPublish(&write, &generation));
            const descriptor: a.GuiSharedRasterResource = .{ .handle = handle, .raster_generation = generation,
                .format = a.gui_shared_raster_format_xrgb32, .source_w = 4, .source_h = 4,
                .guest_w = 4, .guest_h = 4, .viewport_w = 4, .viewport_h = 4 };
            const commands = [_]a.GuiFrameCommand{.{ .kind = a.gui_frame_command_kind_shared_raster, .w = 4, .h = 4,
                .resource_bytes = @sizeOf(a.GuiSharedRasterResource) }};
            try check(draw.guiFrameBegin());
            errdefer _ = draw.guiFrameCancel();
            try check(draw.guiFrameAppend(&commands, std.mem.asBytes(&descriptor)));
            try check(draw.guiFrameCommit()); frame_live = true;
            var frame: a.GuiFrameInfo = .{};
            try check(draw.guiFrameInfo(null, &frame));
            self.stage = "raster-leases";
            for (0..2) |lease_index| {
                const lease = &leases[round * 2 + lease_index];
                try check(draw.guiSharedRasterAcquire(&frame.owner, frame.committed_generation, &handle, generation, lease));
                if (lease.byte_length != 64 or lease.lease.raster_generation != generation) return error.Raster;
                var request = std.mem.zeroes(gfx.R4GfxResourceDesc);
                request.version = 1; request.size = @sizeOf(gfx.R4GfxResourceDesc); request.kind = gfx.resource_image;
                request.source_kind = gfx.source_shared_raster; request.source_address = @intFromPtr(&lease.lease);
                var resource: gfx.R4GfxResource = undefined;
                try check(self.api.resource_create(&self.device, &request, &resource));
                if (lease_index == 0) sources[round] = resource else {
                    if (!std.meta.eql(sources[round], resource) or leases[round * 2].lease.lease_token == lease.lease.lease_token) return error.DuplicateImport;
                    try check(self.api.resource_release(&self.device, &resource));
                }
            }
            try check(self.api.resource_info(&self.device, &sources[round], &infos[round]));
            var state: gfx.R4GfxDeviceInfo = undefined;
            try check(self.api.device_info(&self.device, &state));
            if (state.imports != round + 1 or state.imported_bytes != (round + 1) * 64 or state.upload_bytes != 0) return error.DuplicateImport;
        }
        if (std.meta.eql(sources[0], sources[1]) or infos[0].source_generation == infos[1].source_generation or
            (infos[0].buffer_id == infos[1].buffer_id and infos[0].buffer_generation == infos[1].buffer_generation)) return error.RasterGeneration;
        // Both immutable generations remain imported while their frame and all
        // four independent reader leases end. No stale lease is re-exported.
        self.stage = "raster-owner-release";
        try check(draw.guiFrameBegin());
        try check(draw.guiFrameCommit()); frame_live = false;
        for (&leases) |*lease| { try check(draw.guiSharedRasterRelease(&lease.lease)); lease.lease.lease_token = 0; }
        try check(draw.guiSharedRasterDestroy(&handle)); handle = .{};
        var readback = try self.system(16, 4);
        defer if (readback.reference.id != 0) { _ = self.memory.release(&readback.reference); };
        const target = try self.import(readback.reference);
        for (sources, 0..) |source, round| {
            self.stage = "raster-copy";
            const limit = try self.deadline();
            var job: gfx.R4GfxJob = undefined;
            try check(self.api.copy_submit(&self.device, &.{ .source = source, .target = target,
                .source_offset = 0, .target_offset = 0, .byte_length = 64, .deadline_ns = limit }, &job));
            // End the last public source reference before waiting. Only the
            // accepted job may keep the old generation alive now.
            try check(self.api.resource_release(&self.device, &source));
            _ = try self.finish(&job, limit, a.gfx_queue_result_complete);
            try self.compare(readback.reference, 64, @intCast(round + 1), true);
        }
        var state: gfx.R4GfxDeviceInfo = undefined;
        try check(self.api.device_info(&self.device, &state));
        if (state.imports != 3 or state.imported_bytes != 192 or state.gpu_copy_bytes != 128 or state.upload_bytes != 0 or
            state.cpu_read_bytes != 0 or state.cpu_write_bytes != 0) return error.RasterCounters;
        try check(self.api.resource_release(&self.device, &target));
        try platform(self.memory.release(&readback.reference)); readback = .{};
        self.line("NVIDIA copy raster: OK leases=4 generations={d}/{d} source-imports=2 distinct-BOs=yes CE=2 bytes=128 upload=0 producer-frame-and-leases=ended public-source=ended-before-wait",
            .{infos[0].source_generation, infos[1].source_generation});
    }
};

pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const memory = draw.buffers();
    const api = gfx.DeviceV1Client.init(app.startContext()) catch return 1;
    const allocator = sys.allocator();
    const bytes = api.storage_size();
    if (bytes == 0 or bytes > std.math.maxInt(usize)) return 1;
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(bytes)) catch return 1;
    @memset(storage, 0);
    var before: a.GfxBufferStats = .{};
    if (memory.stats(&before) != 1 or before.allocating_bytes != 0 or before.destroying_bytes != 0 or before.retained_bytes != 0) { allocator.free(storage); return 1; }
    const runtime = @import("resource_balance.zig").Runtime.capture(app) orelse { allocator.free(storage); return 1; };
    var probe: Probe = .{ .sys = sys, .memory = memory, .queues = draw.queues(), .api = api };
    var passed = true;
    for (0..4) |index| {
        if (api.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
            .storage_bytes = bytes, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = 0 }, &probe.device) != gfx.status_ok) { passed = false; break; }
        // The public allocation contract chooses block height automatically:
        // 41 rows gives log2=2. An additional 21-row case gives log2=1;
        // source_y=2 keeps the same 69x19 rectangle inside that image.
        // The public API cannot force the old model's 41-row/log2=1 layout.
        const operation = if (index == 3) probe.shared(&draw) else probe.exercise(index != 0, if (index == 2) 21 else 41);
        operation catch |err| {
            probe.line("NVIDIA copy failed: stage={s} error={s} completed={d}", .{probe.stage, @errorName(err), probe.completed});
            passed = false;
        };
        const limit = probe.deadline() catch 0;
        var closed = false;
        while (true) {
            if (api.device_close(&probe.device) == gfx.status_ok) { closed = true; break; }
            if ((probe.now() catch limit) >= limit) break;
            sys.sleepTicks(1);
        }
        if (!closed) { sys.println("NVIDIA copy device: retained after bounded close failure"); return 1; }
        // A new layout case must not inherit the previous case's asynchronous
        // native destruction or idle mapping eviction in its baseline.
        passed = @import("resource_balance.zig").waitBuffers(&sys, &memory, before) and passed;
        if (!passed) break;
    }
    allocator.free(storage);
    passed = @import("resource_balance.zig").waitBuffers(&sys, &memory, before) and passed;
    passed = @import("resource_balance.zig").Runtime.balanced(runtime, app) and passed;
    if (passed and probe.completed == 20 and probe.exact_bytes == 6 * (upload_bytes + readback_bytes) + 128) {
        probe.line("NVIDIA copy: OK CE=20 dependencies=12 exact-bytes={d} native-row-bytes={d} CPU-initialized={d} CPU-compared={d} raw=stride=rejected BO-reuse=2 balance=complete present=none",
            .{probe.exact_bytes, 6 * round_bytes + 128, probe.cpu_initialized, probe.cpu_compared});
        return 0;
    }
    sys.println("NVIDIA copy: FAILED");
    return 1;
}
