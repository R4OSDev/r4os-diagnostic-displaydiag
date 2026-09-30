// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Opt-in physical memory qualification through existing public BO/queue APIs.
//! No receiver query, native present, raw MMIO or CPU mapping of VRAM.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const producer = @import("r4gfx_queue");
const a = r4os.abi;
const nv = @import("r4nv");
const large_bytes: u64 = 34 * 1024 * 1024 + 123;
// The >8175-page case qualifies whole system-BO registration, partial
// mappings and repeated GPU access. GSP RM's internal heap is separate
// from the CPU-managed VRAM regions: use a bounded native working buffer.
const working_sizes = [_]u64{ 8 * 1024 * 1024 + 5, 1024 * 1024 + 5, 64 * 1024 + 5 };
const child_bytes: u64 = 12293;
const child_pattern: u32 = 3;
const child_marker = "NVIDIA-MEMORY-CHILD ";

fn pattern(index: u64, round: u32) u8 {
    return @truncate((index *% 197 +% (index >> 8) *% 43 +% round *% 73) ^ (index >> 17));
}

const Probe = struct {
    app: *r4os.App,
    sys: r4os.r4sys.Context,
    memory: r4os.gfx_buffers.Context,
    queues: r4os.gfx_queue.Context,
    queue: producer.Queue,
    backend: a.GfxBackendInfo,
    stage: []const u8 = "open",
    code: i32 = 0,
    last_clock: u64 = 0,
    jobs: u32 = 0,
    native_jobs: u32 = 0,
    exact_bytes: u64 = 0,

    fn workingBuffer(self: *Probe, bytes: u64) !struct { reference: a.GfxBufferReference, bytes: u64 } {
        // A fixed, shrinking candidate list does not consume memory until
        // exhaustion. Only acknowledged OOM may select a smaller buffer.
        for (working_sizes) |limit| {
            const wanted: u64 = @min(bytes, limit);
            if (self.native(wanted)) |reference| return .{ .reference = reference, .bytes = wanted } else |err| {
                if (err != error.NativeAllocation or self.code != a.gfx_buffer_error_oom) return err;
                try self.identity();
                self.line("NVIDIA memory working buffer: requested={d} result=oom epoch=unchanged", .{wanted});
                if (wanted == bytes) return err;
            }
        }
        return error.NativeAllocation;
    }

    fn checked(self: *Probe, rc: i32) !void {
        if (rc != 1) {
            self.code = rc;
            self.line("NVIDIA memory API rejected: stage={s} code={d}", .{self.stage, rc});
            return error.Api;
        }
    }
    fn programChecked(self: *Probe, rc: i32) !void {
        self.code = rc;
        if (rc != a.program_handle_ok) return error.Child;
    }
    fn now(self: *Probe) !u64 {
        const value = self.sys.monotonicNanoseconds() orelse return error.Clock;
        if (value == 0 or value == std.math.maxInt(u64) or value < self.last_clock) return error.Clock;
        self.last_clock = value;
        return value;
    }
    fn deadline(self: *Probe) !u64 { return std.math.add(u64, try self.now(), 10 * std.time.ns_per_s); }
    fn line(self: *Probe, comptime format: []const u8, args: anytype) void {
        var text: [256]u8 = undefined;
        self.sys.println(std.fmt.bufPrint(&text, format, args) catch "NVIDIA memory: diagnostic overflow");
    }
    fn identity(self: *Probe) !void {
        for (0..a.gfx_queue_backend_capacity) |index| {
            var current: a.GfxBackendInfo = .{};
            if (self.queues.backendInfo(@intCast(index), &current) == 1 and
                current.binding.adapter_id == self.backend.binding.adapter_id) {
                if (!std.meta.eql(current.binding, self.backend.binding) or
                    current.memory_generation != self.backend.memory_generation) return error.Stale;
                return;
            }
        }
        return error.Lost;
    }
    fn system(self: *Probe, bytes: u64) !a.GfxBufferReference {
        var reference: a.GfxBufferReference = .{};
        try self.checked(self.memory.create(&.{ .byte_length = bytes, .usage = 15 }, &reference));
        return reference;
    }
    fn native(self: *Probe, bytes: u64) !a.GfxBufferReference {
        const reference = try self.nativeAllocation(.{ .kind = 0, .byte_length = bytes, .usage = 12 });
        errdefer _ = self.memory.release(&reference.reference);
        var descriptor: a.GfxBufferDescriptor = .{};
        try self.checked(self.memory.describe(&reference.reference, &descriptor));
        if (descriptor.location != a.gfx_buffer_location_device_local or descriptor.byte_length != bytes or
            descriptor.alignment != 65536 or descriptor.driver_owner == 0 or
            descriptor.adapter_id != self.backend.binding.adapter_id or descriptor.device_generation != self.backend.memory_generation)
            return error.Descriptor;
        self.line("NVIDIA memory native: logical={d} alignment={d} owner={d} memory-generation={d}",
            .{bytes, descriptor.alignment, descriptor.driver_owner, descriptor.device_generation});
        return reference;
    }
    fn nativeAllocation(self: *Probe, requested: a.GfxNativeAllocation) !a.GfxBufferReference {
        var status: a.GfxNativeStatus = .{};
        var input = requested;
        input.adapter_id = self.backend.binding.adapter_id;
        input.memory_generation = self.backend.memory_generation;
        input.deadline_ns = try self.deadline();
        try self.checked(self.memory.nativeStart(&input, &status));
        var request = status.request;
        defer if (request.id != 0) { _ = self.memory.nativeClose(&request); };
        try self.checked(self.memory.nativeWait(&request, self.sys.ticksFromMilliseconds(10000), &status));
        if (status.phase != 2 or status.result != 1 or status.flags != 0) {
            self.code = status.result;
            return error.NativeAllocation;
        }
        var reference: a.GfxBufferReference = .{};
        try self.checked(self.memory.nativeReceive(&request, &reference));
        request = .{};
        return reference;
    }
    fn initialize(self: *Probe, reference: a.GfxBufferHandle, bytes: u64, round: ?u32) !void {
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&reference, 1, 0, bytes, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != bytes or map.cpu_address == 0) return error.Map;
        const data: [*]u8 = @ptrFromInt(map.cpu_address);
        if (round) |value| {
            for (data[0..@intCast(bytes)], 0..) |*item, index| item.* = pattern(index, value);
        } else @memset(data[0..@intCast(bytes)], 0xa5);
        try self.checked(self.memory.unmap(&map.lease));
        map.lease = .{};
    }
    fn copy(self: *Probe, source: a.GfxBufferHandle, target: a.GfxBufferHandle, from: u64, to: u64, bytes: u64) !void {
        return self.submit(.{ .operation = a.gfx_queue_operation_copy, .source = source, .target = target,
            .source_offset = from, .target_offset = to, .byte_length = bytes });
    }
    fn submit(self: *Probe, requested: a.GfxSubmission) !void {
        var status: a.GfxFenceStatus = .{};
        var input = requested;
        input.deadline_ns = try self.deadline();
        try self.checked(self.queues.submit(&self.queue.handle, &input, &status));
        const fence = status.fence;
        defer _ = self.queues.release(&fence);
        try self.checked(self.queues.wait(&fence, self.sys.ticksFromMilliseconds(10000), a.gfx_queue_wait_resources_released, &status));
        if (status.phase != a.gfx_queue_phase_terminal or status.result != a.gfx_queue_result_complete or
            status.flags != 0 or status.milestone != a.gfx_queue_milestone_device_execution or
            !std.meta.eql(status.fence, fence) or fence.adapter_id != self.backend.binding.adapter_id or
            fence.device_generation != self.backend.binding.device_generation or fence.reset_generation != self.backend.binding.reset_generation) {
            self.line("NVIDIA memory completion rejected: phase={d} result={d} flags={x} milestone={d}",
                .{status.phase, status.result, status.flags, status.milestone});
            return error.Completion;
        }
        try self.identity();
        self.jobs += 1;
        if (self.jobs <= 6 or self.jobs % 128 == 0)
            self.line("NVIDIA memory completion: point={d} timeline={d} bytes={d} offsets={d}/{d} device-execution=yes resources=released",
                .{fence.point, fence.timeline, input.byte_length, input.source_offset, input.target_offset});
    }
    fn compare(self: *Probe, reference: a.GfxBufferHandle, bytes: u64, tile_bytes: u64, round: u32) !void {
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&reference, 0, 0, bytes + 31, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != bytes + 31 or map.cpu_address == 0) return error.Map;
        const data: [*]const u8 = @ptrFromInt(map.cpu_address);
        var mismatches: u64 = 0;
        for (data[0..@intCast(map.byte_length)], 0..) |actual, index| {
            const expected: u8 = if (index < 7 or index >= 7 + bytes) 0xa5 else blk: {
                const native_index = index - 7;
                const tile_start = native_index / tile_bytes * tile_bytes;
                const span: u64 = @min(tile_bytes, bytes - tile_start);
                const local = native_index - tile_start;
                // Each tile's second copy changes [5, span-6), while the
                // source pattern still includes its absolute BO offset.
                break :blk pattern(if (local >= 5 and local < span - 6) native_index - 2 else native_index, round);
            };
            if (actual != expected) {
                if (mismatches < 4) self.line("NVIDIA memory mismatch: index={d} expected={x:0>2} actual={x:0>2}", .{index,expected,actual});
                mismatches += 1;
            }
        }
        try self.checked(self.memory.unmap(&map.lease));
        map.lease = .{};
        if (mismatches != 0) { self.line("NVIDIA memory mismatches: {d}", .{mismatches}); return error.Bytes; }
        self.exact_bytes += bytes + 31;
    }
    fn raw(self: *Probe, bytes: u64) !void {
        self.stage = "raw-create";
        var upload = try self.system(bytes);
        defer if (upload.reference.id != 0) { _ = self.memory.release(&upload.reference); };
        var readback = try self.system(bytes + 31);
        defer if (readback.reference.id != 0) { _ = self.memory.release(&readback.reference); };
        const working = try self.workingBuffer(bytes);
        const tile_bytes = working.bytes;
        var target = working.reference;
        defer if (target.reference.id != 0) { _ = self.memory.release(&target.reference); };
        for (0..2) |round| {
            self.stage = "raw-fill";
            try self.initialize(upload.reference, bytes, @intCast(round));
            try self.initialize(readback.reference, bytes + 31, null);
            var offset: u64 = 0;
            while (offset < bytes) {
                const span: u64 = @min(tile_bytes, bytes - offset);
                if (span <= 11) return error.Size;
                self.stage = "raw-upload";
                try self.copy(upload.reference, target.reference, offset, 0, span);
                self.stage = "raw-odd-copy";
                try self.copy(upload.reference, target.reference, offset + 3, 5, span - 11);
                self.stage = "raw-readback";
                try self.copy(target.reference, readback.reference, 0, offset + 7, span);
                offset += span;
            }
            self.stage = "raw-compare";
            try self.compare(readback.reference, bytes, tile_bytes, @intCast(round));
            if (round == 0) {
                self.stage = "raw-reference-end";
                var alias: a.GfxBufferReference = .{};
                try self.checked(self.memory.import(&upload.reference, &alias));
                errdefer _ = self.memory.release(&alias.reference);
                try self.checked(self.memory.release(&upload.reference));
                upload = alias;
                // The second round uses the same BO after its original
                // reference ends. This is not a killed-process assertion.
            }
        }
        self.stage = "raw-close";
        try self.checked(self.memory.release(&target.reference)); target = .{};
        try self.checked(self.memory.release(&readback.reference)); readback = .{};
        try self.checked(self.memory.release(&upload.reference)); upload = .{};
        self.line("NVIDIA memory raw: OK logical={d} pages={d} working={d} rounds=2 original-reference=closed aliases=same-BO guards=31",
            .{bytes, (bytes + 4095) / 4096, tile_bytes});
    }
    fn image(self: *Probe, format: u32, tiled: bool, round: u32) !void {
        self.stage = "image-create";
        const multi = format == a.gfx_buffer_format_nv12 or format == a.gfx_buffer_format_p010;
        const planes: usize = if (multi) 2 else 1;
        const pitch: u64 = if (format == a.gfx_buffer_format_p010) (if (tiled) 320 else 512)
            else if (multi) (if (tiled) 192 else 256) else (if (tiled) 576 else 768);
        const log2_gobs: u64 = if (multi) 1 else 2;
        const modifier: u64 = if (tiled) (@as(u64, 3) << 56) | 0x10 | log2_gobs | (6 << 12) | (2 << 20) | (1 << 22) else 0;
        const native_bytes: u64 = if (multi) 131072 else 65536;
        // Frozen GA106 geometry, independent of the driver's plan builder.
        // Other page kinds do not silently inherit this hardware qualification.
        var target = try self.nativeAllocation(.{ .kind = 1, .width = 129, .height = 41, .format = format,
            .usage = 12, .layout = if (tiled) 1 else 0 });
        defer if (target.reference.id != 0) { _ = self.memory.release(&target.reference); };
        var descriptor: a.GfxBufferDescriptor = .{};
        try self.checked(self.memory.describe(&target.reference, &descriptor));
        if (descriptor.location != a.gfx_buffer_location_device_local or descriptor.driver_owner == 0 or
            descriptor.adapter_id != self.backend.binding.adapter_id or descriptor.device_generation != self.backend.memory_generation or
            descriptor.byte_length != native_bytes or descriptor.alignment != 65536 or descriptor.modifier != modifier or
            descriptor.format != format or descriptor.width != 129 or descriptor.height != 41 or descriptor.plane_count != planes)
            return error.ImageDescriptor;
        for (0..4) |plane| {
            if (descriptor.plane_pitches[plane] != (if (plane < planes) pitch else 0) or
                descriptor.plane_offsets[plane] != (if (plane == 1 and multi) @as(u64, 65536) else 0)) return error.ImageDescriptor;
        }
        // Public VA bindings require whole4KB logical spans. Allocate and
        // compare the entire extra guard page; never round a binding beyond
        // its BO's logical length to satisfy this contract.
        const bytes = native_bytes + 4096;
        var upload = try self.system(bytes);
        defer if (upload.reference.id != 0) { _ = self.memory.release(&upload.reference); };
        var readback = try self.system(bytes);
        defer if (readback.reference.id != 0) { _ = self.memory.release(&readback.reference); };
        var command = try self.system(4096);
        defer if (command.reference.id != 0) { _ = self.memory.release(&command.reference); };
        self.stage = "image-raw-properties";
        const backend = try self.copyBackend();
        var ranges: [4]a.GfxVirtualStatus = @splat(.{});
        var bindings: [4]a.GfxVirtualStatus = @splat(.{});
        defer for (&ranges) |*value| if (value.resource.id != 0) { self.virtualRetire(&value.resource) catch {}; };
        defer for (&bindings) |*value| if (value.resource.id != 0) { self.virtualRetire(&value.resource) catch {}; };
        const references = [_]a.GfxBufferHandle{upload.reference, target.reference, readback.reference, command.reference};
        const lengths = [_]u64{bytes, native_bytes, bytes, 4096};
        for (&ranges, &bindings, 0..) |*range, *binding, index| {
            self.stage = "image-raw-range";
            range.* = try self.virtualCreate(.{ .kind = 1, .byte_length = std.mem.alignForward(u64, lengths[index], 65536),
                .alignment = 65536, .location = if (index == 1) 1 else 0 });
            self.stage = switch (index) {
                0 => "image-raw-upload-binding",
                1 => "image-raw-native-binding",
                2 => "image-raw-readback-binding",
                3 => "image-raw-command-binding",
                else => unreachable,
            };
            binding.* = try self.virtualCreate(.{ .kind = 2, .parent = range.resource, .reference = references[index],
                .byte_length = lengths[index] });
            if (binding.address != range.address) return error.Virtual;
        }
        var queue: producer.Queue = .{ .context = self.queues };
        try self.checked(queue.open(.{ .adapter_id = self.backend.binding.adapter_id,
            .milestone = a.gfx_queue_milestone_device_execution, .device_generation = self.backend.binding.device_generation,
            .reset_generation = self.backend.binding.reset_generation }));
        defer _ = queue.close();
        // Poison the complete native allocation, including GOB padding and
        // 64KB plane tails, through a raw linear VA copy before logical writes.
        // This does not assume public allocations promise initial zeroing.
        self.stage = "image-raw-poison";
        try self.initialize(upload.reference, bytes, null);
        try self.virtualCopy(&queue, &backend.api, backend.copy_class, command.reference, bindings[3].address, &bindings,
            bindings[0].address, bindings[1].address, native_bytes);
        try self.initialize(upload.reference, bytes, round);
        try self.initialize(readback.reference, bytes, null);
        for (0..planes) |plane| {
            const base = descriptor.plane_offsets[plane];
            const rows: u32 = if (plane == 0) 41 else 21;
            const columns: u64 = if (multi and plane == 1) 130 else 129;
            const row_bytes = columns * @as(u64, if (format == a.gfx_buffer_format_p010) 2 else if (multi) 1 else 4);
            // Public geometric copies are bounded by the logical plane width,
            // not by pitch. Native padding needs a separate raw-VA copy.
            self.stage = "image-upload";
            try self.submit(.{ .operation = a.gfx_queue_operation_copy_rows, .source = upload.reference, .target = target.reference,
                .source_offset = base + 13, .target_offset = base, .byte_length = row_bytes,
                .source_pitch = pitch + 17, .target_pitch = pitch, .row_count = rows });
            self.stage = "image-odd-rectangle";
            try self.submit(.{ .operation = a.gfx_queue_operation_copy_rows, .source = upload.reference, .target = target.reference,
                .source_offset = base + 13 + pitch + 17 + 3, .target_offset = base + pitch + 5, .byte_length = row_bytes - 11,
                .source_pitch = pitch + 17, .target_pitch = pitch, .row_count = rows - 2 });
            self.stage = "image-readback";
            try self.submit(.{ .operation = a.gfx_queue_operation_copy_rows, .source = target.reference, .target = readback.reference,
                .source_offset = base, .target_offset = base + 7, .byte_length = row_bytes,
                .source_pitch = pitch, .target_pitch = pitch + 23, .row_count = rows });
        }
        self.stage = "image-compare";
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&readback.reference, 0, 0, bytes, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.byte_length != bytes or map.cpu_address == 0) return error.Map;
        const data: [*]const u8 = @ptrFromInt(map.cpu_address);
        var mismatches: u64 = 0;
        for (data[0..@intCast(bytes)], 0..) |actual, index| {
            var expected: u8 = 0xa5;
            for (0..planes) |plane| {
                const base = descriptor.plane_offsets[plane];
                const rows: u64 = if (plane == 0) 41 else 21;
                if (index < base + 7) continue;
                const relative = index - base - 7;
                const y = relative / (pitch + 23);
                const x = relative % (pitch + 23);
                const columns: u64 = if (multi and plane == 1) 130 else 129;
                const row_bytes = columns * @as(u64, if (format == a.gfx_buffer_format_p010) 2 else if (multi) 1 else 4);
                if (y >= rows or x >= row_bytes) continue;
                const source_x = if (y >= 1 and y < rows - 1 and x >= 5 and x < row_bytes - 6) x - 2 else x;
                expected = pattern(base + 13 + y * (pitch + 17) + source_x, round);
                break;
            }
            if (actual != expected) {
                if (mismatches < 4) self.line("NVIDIA image mismatch: format={x} tiled={} index={d} expected={x:0>2} actual={x:0>2}",
                    .{format, tiled, index, expected, actual});
                mismatches += 1;
            }
        }
        try self.checked(self.memory.unmap(&map.lease)); map.lease = .{};
        if (mismatches != 0) return error.ImageBytes;
        self.exact_bytes += bytes;
        // A second copy reads the complete native VA representation without
        // geometric detiling. Compare an independent GOB inverse, every pitch
        // byte, padded row, plane tail and the system readback guard span.
        self.stage = "image-raw-readback";
        try self.initialize(readback.reference, bytes, null);
        try self.virtualCopy(&queue, &backend.api, backend.copy_class, command.reference, bindings[3].address, &bindings,
            bindings[1].address, bindings[2].address + 7, native_bytes);
        self.stage = "image-raw-compare";
        try self.compareRawImage(readback.reference, bytes, &descriptor, round);
        self.stage = "image-close";
        try self.checked(queue.close());
        for (&bindings) |*value| try self.virtualRetire(&value.resource);
        for (&ranges) |*value| try self.virtualRetire(&value.resource);
        try self.checked(self.memory.release(&command.reference)); command = .{};
        try self.checked(self.memory.release(&target.reference)); target = .{};
        try self.checked(self.memory.release(&readback.reference)); readback = .{};
        try self.checked(self.memory.release(&upload.reference)); upload = .{};
        self.line("NVIDIA memory image: OK format={x} tiled={} size=129x41 planes={d} pitch={d} gob-log2={d} exact-bytes={d} raw-VA-GOB-and-padding=yes",
            .{format, tiled, planes, pitch, if (tiled) log2_gobs else 0, bytes * 2});
    }
    fn compareRawImage(self: *Probe, reference: a.GfxBufferHandle, bytes: u64, descriptor: *const a.GfxBufferDescriptor, round: u32) !void {
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&reference, 0, 0, bytes, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.cpu_address == 0 or map.byte_length != bytes) return error.Map;
        const data: [*]const u8 = @ptrFromInt(map.cpu_address);
        var mismatches: u64 = 0;
        var payload_bytes: u64 = 0;
        var padding_bytes: u64 = 0;
        const multi = descriptor.plane_count == 2;
        const tiled = descriptor.modifier != 0;
        for (data[0..@intCast(bytes)], 0..) |actual, index| {
            var expected: u8 = 0xa5;
            if (index >= 7 and index - 7 < descriptor.byte_length) {
                const offset = index - 7;
                const plane: usize = if (multi and offset >= descriptor.plane_offsets[1]) 1 else 0;
                const base = descriptor.plane_offsets[plane];
                const pitch = descriptor.plane_pitches[plane];
                const within = offset - base;
                const xy: @import("nvidia_gob.zig").Coordinate = if (tiled)
                    try @import("nvidia_gob.zig").coordinate(within, pitch, if (multi) 1 else 2)
                else .{ .x = within % pitch, .y = within / pitch };
                const rows: u64 = if (plane == 0) 41 else 21;
                const columns: u64 = if (multi and plane == 1) 130 else 129;
                const row_bytes = columns * @as(u64, if (descriptor.format == a.gfx_buffer_format_p010) 2 else if (multi) 1 else 4);
                if (xy.y < rows and xy.x < row_bytes) {
                    const source_x = if (xy.y >= 1 and xy.y < rows - 1 and xy.x >= 5 and xy.x < row_bytes - 6) xy.x - 2 else xy.x;
                    expected = pattern(base + 13 + xy.y * (pitch + 17) + source_x, round);
                    payload_bytes += 1;
                } else padding_bytes += 1;
            }
            if (actual != expected) {
                if (mismatches < 4) self.line("NVIDIA raw image mismatch: format={x} tiled={} index={d} expected={x:0>2} actual={x:0>2}",
                    .{descriptor.format, tiled, index, expected, actual});
                mismatches += 1;
            }
        }
        try self.checked(self.memory.unmap(&map.lease)); map.lease = .{};
        if (mismatches != 0) return error.RawImageBytes;
        if (payload_bytes == 0 or padding_bytes == 0 or payload_bytes + padding_bytes != descriptor.byte_length) return error.ImageDescriptor;
        self.exact_bytes += bytes;
        self.line("NVIDIA memory raw image: OK payload={d} padding={d} guards={d} representation=native-VA kind={d}",
            .{payload_bytes, padding_bytes, bytes - descriptor.byte_length, if (tiled) @as(u8, 6) else 0});
    }
    fn virtualCopy(self: *Probe, queue: *const producer.Queue, api: *const nv.BackendV1Client, copy_class: u32,
        command: a.GfxBufferHandle, command_va: u64, bindings: []const a.GfxVirtualStatus,
        source: u64, target: u64, bytes: u64) !void
    {
        return self.virtualCopyEngine(queue, api, copy_class, command, command_va, bindings, source, target, bytes, true);
    }
    fn virtualCopyEngine(self: *Probe, queue: *const producer.Queue, api: *const nv.BackendV1Client, copy_class: u32,
        command: a.GfxBufferHandle, command_va: u64, bindings: []const a.GfxVirtualStatus,
        source: u64, target: u64, bytes: u64, graphics: bool) !void
    {
        const point = self.native_jobs + 1;
        var words: [64]u32 = @splat(0);
        var written: u32 = 0;
        self.code = api.encode_copy(&.{ .version = 1, .size = @sizeOf(nv.R4NvCopy), .source = source,
            .target = target, .bytes = bytes, .semaphore = command_va + 2048, .copy_class = copy_class,
            .rows = 0, .source_pitch = 0, .target_pitch = 0, .point = point,
            .flags = if (graphics) nv.copy_flag_graphics_channel else 0 }, &words, words.len, &written);
        if (self.code != nv.status_ok or written == 0 or written > words.len) return error.Encode;
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&command, 1, 0, 4096, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.cpu_address == 0 or map.byte_length != 4096) return error.Map;
        const data: [*]u8 = @ptrFromInt(map.cpu_address);
        @memset(data[0..4096], 0);
        @memcpy(data[0 .. written * 4], std.mem.sliceAsBytes(words[0..written]));
        try self.checked(self.memory.unmap(&map.lease)); map = .{};
        const Packet = extern struct { header: nv.R4NvNativeSubmitHeader, push: nv.R4NvNativePush };
        const packet: Packet = .{ .header = .{ .version = nv.native_submit_version, .size = @sizeOf(nv.R4NvNativeSubmitHeader),
            .engine_mask = nv.native_engine_copy | (if (graphics) nv.native_engine_graphics else @as(u32, 0)), .push_count = 1, .reserved0 = 0, .reserved1 = 0 },
            .push = .{ .address = command_va, .byte_length = written * 4, .flags = 0 } };
        if (bindings.len != 4) return error.Virtual;
        var resources: [4]a.GfxNativeResource = undefined;
        for (&resources, bindings, 0..) |*resource, binding, index|
            resource.* = .{ .binding = binding.resource, .access = if (index == 0) 0 else 1 };
        const submission: a.GfxNativeSubmission = .{ .interface_id_lo = nv.backend_v1_header.interface_id_lo,
            .interface_id_hi = nv.backend_v1_header.interface_id_hi, .revision = 1,
            .command_bytes = @sizeOf(Packet), .commands = @intFromPtr(&packet),
            .resource_count = resources.len, .resources = @intFromPtr(&resources) };
        var status: a.GfxFenceStatus = .{};
        try self.checked(self.queues.submitNative(&queue.handle,
            &.{ .operation = a.gfx_queue_operation_native, .deadline_ns = try self.deadline() }, &submission, &status));
        const fence = status.fence;
        defer _ = self.queues.release(&fence);
        try self.checked(self.queues.wait(&fence, self.sys.ticksFromMilliseconds(10000), a.gfx_queue_wait_resources_released, &status));
        if (status.phase != a.gfx_queue_phase_terminal or status.result != a.gfx_queue_result_complete or
            status.flags != 0 or status.milestone != a.gfx_queue_milestone_device_execution or
            !std.meta.eql(status.fence, fence) or fence.adapter_id != self.backend.binding.adapter_id or
            fence.device_generation != self.backend.binding.device_generation or fence.reset_generation != self.backend.binding.reset_generation) {
            self.line("NVIDIA VA completion rejected: phase={d} result={d} flags={x} milestone={d}",
                .{status.phase, status.result, status.flags, status.milestone});
            return error.Completion;
        }
        try self.identity();
        try self.checked(self.memory.map(&command, 0, 2048, 4, &map));
        if (map.cpu_address == 0 or map.byte_length != 4) return error.Map;
        const semaphore: *const [4]u8 = @ptrFromInt(map.cpu_address);
        if (std.mem.readInt(u32, semaphore, .little) != point) return error.CeSemaphore;
        try self.checked(self.memory.unmap(&map.lease)); map = .{};
        self.native_jobs += 1;
        self.line("NVIDIA memory VA completion: point={d} fence={d}:{d} bytes={d} CE-semaphore=exact device-execution=yes resources=released",
            .{point, fence.timeline, fence.point, bytes});
    }
    fn compareVirtual(self: *Probe, reference: a.GfxBufferHandle, round: ?u32) !void {
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&reference, 0, 0, 20480, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.cpu_address == 0 or map.byte_length != 20480) return error.Map;
        const data: [*]const u8 = @ptrFromInt(map.cpu_address);
        var mismatches: u64 = 0;
        for (data[0..20480], 0..) |actual, index| {
            const expected: u8 = if (index < 7 or index >= 7 + 16384) 0xa5 else blk: {
                const target_index = index - 7;
                if (round) |value| if (target_index >= 5 and target_index < 5 + 8181) {
                    const offset: u64 = if (value == 31) 4096 else 0;
                    break :blk pattern(offset + 3 + target_index - 5, value);
                };
                break :blk pattern(target_index, 31);
            };
            if (actual != expected) {
                if (mismatches < 4) self.line("NVIDIA VA mismatch: index={d} expected={x:0>2} actual={x:0>2}", .{index, expected, actual});
                mismatches += 1;
            }
        }
        try self.checked(self.memory.unmap(&map.lease)); map = .{};
        if (mismatches != 0) return error.VirtualBytes;
        self.exact_bytes += 20480;
    }
    fn copyBackend(self: *Probe) !struct { api: nv.BackendV1Client, copy_class: u32 } {
        const api = try nv.BackendV1Client.init(self.app.startContext());
        var properties: a.GfxBackendProperties = .{};
        try self.checked(self.queues.backendProperties(&self.backend.binding, &properties));
        if (properties.interface_id_lo != nv.backend_v1_header.interface_id_lo or
            properties.interface_id_hi != nv.backend_v1_header.interface_id_hi or properties.revision != nv.architecture_version or
            properties.data_bytes != @sizeOf(nv.R4NvArchitecture)) return error.Architecture;
        const architecture = std.mem.bytesToValue(nv.R4NvArchitecture, properties.data[0..@sizeOf(nv.R4NvArchitecture)]);
        if (architecture.version != properties.revision or architecture.size != @sizeOf(nv.R4NvArchitecture) or
            architecture.vendor_id != 0x10de or architecture.memory_generation != self.backend.memory_generation or
            architecture.copy_class != 0xc7b5 or architecture.gpfifo_class != 0xc56f or architecture.bind_alignment != 65536)
            return error.Architecture;
        var features: nv.R4NvFeatures = undefined;
        self.code = api.negotiate(&.{ .version = 1, .size = @sizeOf(nv.R4NvDeviceProfile),
            .vendor_id = architecture.vendor_id, .copy_class = architecture.copy_class,
            .rm_release = architecture.rm_release, .command_abi = nv.command_abi,
            .adapter_id = self.backend.binding.adapter_id, .flags = 0,
            .device_generation = self.backend.binding.device_generation,
            .reset_generation = self.backend.binding.reset_generation }, &features);
        if (self.code != nv.status_ok or features.features & nv.feature_copy_graphics_channel == 0)
            return error.Architecture;
        return .{ .api = api, .copy_class = architecture.copy_class };
    }
    fn explicitVa(self: *Probe) !void {
        self.stage = "VA-properties";
        const backend = try self.copyBackend();
        self.stage = "VA-buffers";
        var source_a = try self.system(16384);
        defer if (source_a.reference.id != 0) { _ = self.memory.release(&source_a.reference); };
        var source_b = try self.system(16384);
        defer if (source_b.reference.id != 0) { _ = self.memory.release(&source_b.reference); };
        var target = try self.native(16384);
        defer if (target.reference.id != 0) { _ = self.memory.release(&target.reference); };
        var readback = try self.system(20480);
        defer if (readback.reference.id != 0) { _ = self.memory.release(&readback.reference); };
        var command = try self.system(4096);
        defer if (command.reference.id != 0) { _ = self.memory.release(&command.reference); };
        try self.initialize(source_a.reference, 16384, 31);
        try self.initialize(source_b.reference, 16384, 47);
        try self.initialize(readback.reference, 20480, null);
        var ranges: [4]a.GfxVirtualStatus = @splat(.{});
        var bindings: [4]a.GfxVirtualStatus = @splat(.{});
        // Every child retires before any parent, including partial failures.
        defer for (&ranges) |*value| if (value.resource.id != 0) { self.virtualRetire(&value.resource) catch {}; };
        defer for (&bindings) |*value| if (value.resource.id != 0) { self.virtualRetire(&value.resource) catch {}; };
        const references = [_]a.GfxBufferHandle{ source_a.reference, target.reference, readback.reference, command.reference };
        const lengths = [_]u64{8192, 16384, 20480, 4096};
        for (&ranges, &bindings, 0..) |*range, *binding, index| {
            self.stage = "VA-range";
            range.* = try self.virtualCreate(.{ .kind = 1, .byte_length = 65536, .alignment = 65536, .location = if (index == 1) 1 else 0 });
            self.stage = "VA-binding";
            const offset: u64 = if (index == 0) 4096 else 0;
            binding.* = try self.virtualCreate(.{ .kind = 2, .parent = range.resource, .reference = references[index],
                .byte_offset = offset, .virtual_offset = offset, .byte_length = lengths[index] });
            if (binding.address != range.address + offset) return error.Virtual;
        }
        const source_address = bindings[0].address;
        var queue: producer.Queue = .{ .context = self.queues };
        try self.checked(queue.open(.{ .adapter_id = self.backend.binding.adapter_id,
            .milestone = a.gfx_queue_milestone_device_execution, .device_generation = self.backend.binding.device_generation,
            .reset_generation = self.backend.binding.reset_generation }));
        defer _ = queue.close();
        // Public native allocations do not promise private-control zeroing.
        // Seed every logical byte through the qualified canonical CE path;
        // the explicit-VA read must reproduce that independent known pattern.
        self.stage = "VA-initial-pattern";
        try self.copy(source_a.reference, target.reference, 0, 0, 16384);
        try self.virtualCopy(&queue, &backend.api, backend.copy_class, command.reference, bindings[3].address, &bindings,
            bindings[1].address, bindings[2].address + 7, 16384);
        try self.compareVirtual(readback.reference, null);
        for ([_]u32{31,47}) |round| {
            if (round == 47) {
                self.stage = "VA-unmap-A";
                try self.virtualRetire(&bindings[0].resource);
                self.stage = "VA-remap-B";
                bindings[0] = try self.virtualCreate(.{ .kind = 2, .parent = ranges[0].resource, .reference = source_b.reference,
                    .virtual_offset = 4096, .byte_length = 8192 });
                if (bindings[0].address != source_address) return error.Virtual;
            }
            try self.initialize(readback.reference, 20480, null);
            self.stage = "VA-upload";
            try self.virtualCopy(&queue, &backend.api, backend.copy_class, command.reference, bindings[3].address, &bindings,
                source_address + 3, bindings[1].address + 5, 8181);
            self.stage = "VA-readback";
            try self.virtualCopy(&queue, &backend.api, backend.copy_class, command.reference, bindings[3].address, &bindings,
                bindings[1].address, bindings[2].address + 7, 16384);
            try self.compareVirtual(readback.reference, round);
        }
        self.stage = "VA-retire";
        try self.checked(queue.close());
        self.line("NVIDIA memory VA: OK native-jobs=5 exact-bytes=61440 source-VA={x} remap=A-to-B initial-pattern=exact CE-semaphores=5",
            .{source_address});
        try self.sharedCopyChannels(&backend.api, backend.copy_class, source_b.reference, readback.reference, command.reference, &bindings);
        self.stage = "VA-retire";
        for (&bindings) |*value| try self.virtualRetire(&value.resource);
        for (&ranges) |*value| try self.virtualRetire(&value.resource);
        for ([_]*a.GfxBufferReference{ &command, &readback, &target, &source_b, &source_a }) |value| {
            try self.checked(self.memory.release(&value.reference)); value.* = .{};
        }
    }

    fn sharedCopyChannels(self: *Probe, api: *const nv.BackendV1Client, copy_class: u32,
        source: a.GfxBufferHandle, readback: a.GfxBufferHandle, command: a.GfxBufferHandle,
        bindings: []const a.GfxVirtualStatus) !void
    {
        self.stage = "shared-CE-queues";
        var queues: [2]producer.Queue = @splat(.{ .context = self.queues });
        defer for (&queues) |*queue| { _ = queue.close(); };
        for (&queues) |*queue| try self.checked(queue.open(.{ .adapter_id = self.backend.binding.adapter_id,
            .milestone = a.gfx_queue_milestone_device_execution, .device_generation = self.backend.binding.device_generation,
            .reset_generation = self.backend.binding.reset_generation }));
        const timelines = [_]u64{queues[0].handle.timeline, queues[1].handle.timeline};
        if (timelines[0] == timelines[1]) return error.SharedChannel;
        for ([_]u32{61,73,89}, 0..) |round, index| {
            self.stage = "shared-CE-pattern";
            try self.initialize(source, 16384, round);
            try self.initialize(readback, 20480, null);
            const queue = &queues[if (index == 0) @as(usize, 0) else 1];
            try self.virtualCopyEngine(queue, api, copy_class, command, bindings[3].address, bindings,
                bindings[0].address + 3, bindings[1].address + 5, 8181, false);
            try self.virtualCopyEngine(queue, api, copy_class, command, bindings[3].address, bindings,
                bindings[1].address, bindings[2].address + 7, 16384, false);
            try self.compareVirtual(readback, round);
            if (index == 1) {
                self.stage = "shared-CE-first-retire";
                const before = try self.snapshot();
                try self.checked(queues[0].close());
                var after = try self.snapshot();
                const end = try self.deadline();
                while ((after.objects >= before.objects or after.device_bytes >= before.device_bytes) and try self.now() < end) {
                    self.sys.sleepTicks(1); after = try self.snapshot();
                }
                if (after.objects >= before.objects or after.device_bytes >= before.device_bytes) return error.SharedRetirement;
                self.line("NVIDIA memory shared CE: first={d} closed objects={d}->{d} native-bytes={d}->{d} second={d} survivor-work=next",
                    .{timelines[0], before.objects, after.objects, before.device_bytes, after.device_bytes, timelines[1]});
            }
        }
        try self.checked(queues[1].close());
        self.line("NVIDIA memory shared CE: OK native-jobs=6 exact-bytes=61440 queues={d}/{d} first-retired-before-survivor=yes CE-semaphores=6 context-proof=driver-log",
            .{timelines[0], timelines[1]});
    }

    fn oom(self: *Probe) !void {
        self.stage = "oom-probe";
        // One finite request, beyond the measured GA106 internal RM heap.
        // No retry-until-exhaustion, budget override or firmware injection.
        // Other hardware may accept it; that is not an OOM qualification.
        const request_bytes: u64 = 64 * 1024 * 1024;
        if (self.native(request_bytes)) |reference| {
            try self.checked(self.memory.release(&reference.reference));
            return error.OomNotReached;
        } else |err| {
            if (err != error.NativeAllocation or self.code != a.gfx_buffer_error_oom) return err;
        }
        try self.identity();
        self.line("NVIDIA memory rejection: OK requested={d} result=oom epoch=unchanged", .{request_bytes});
    }
    fn virtualCreate(self: *Probe, input: a.GfxVirtualRequest) !a.GfxVirtualStatus {
        const draw = self.app.drawing() orelse return error.Api;
        var request = input;
        request.adapter_id = self.backend.binding.adapter_id;
        request.memory_generation = self.backend.memory_generation;
        request.deadline_ns = try self.deadline();
        var status: a.GfxVirtualStatus = .{};
        try self.checked(draw.gfxVirtualStart(&request, &status));
        const resource = status.resource;
        errdefer _ = draw.gfxVirtualClose(&resource, 1);
        try self.checked(draw.gfxVirtualWait(&resource, 0, self.sys.ticksFromMilliseconds(10000), &status));
        if (status.result != 1 or status.flags != 1 or status.kind != request.kind or status.address == 0 or
            status.byte_length != request.byte_length or !std.meta.eql(status.resource, resource) or
            !std.meta.eql(status.parent, request.parent)) return error.Virtual;
        return status;
    }
    fn virtualRetire(self: *Probe, resource: *a.GfxBufferHandle) !void {
        const draw = self.app.drawing() orelse return error.Api;
        try self.checked(draw.gfxVirtualClose(resource, 0));
        var status: a.GfxVirtualStatus = .{};
        try self.checked(draw.gfxVirtualWait(resource, 1, self.sys.ticksFromMilliseconds(10000), &status));
        if (status.flags & 2 == 0 or !std.meta.eql(status.resource, resource.*)) return error.Virtual;
        try self.checked(draw.gfxVirtualClose(resource, 1));
        resource.* = .{};
    }
    fn producerEnd(self: *Probe) !void {
        self.stage = "producer-spawn";
        var child_handle: a.ProgramProcessHandle = .{};
        try self.programChecked(self.sys.programSpawnWithConsoleHostHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\DISPLAYD.R4X",
            "/NVIDIAMEMCHILD", .console, .terminal_window, &child_handle));
        defer if (child_handle.instance_id != 0) {
            _ = self.sys.programHandleKill(&child_handle);
            var completion: a.ProgramProcessCompletion = .{};
            _ = self.sys.programHandleWait(&child_handle, self.sys.ticksFromMilliseconds(5000), &completion);
            _ = self.sys.programHandleReap(&child_handle, &completion);
        };
        var original: ?a.GfxBufferReference = null;
        const end = try self.deadline();
        while (original == null and try self.now() < end) {
            original = childReference(&self.sys, child_handle.instance_id);
            if (original == null) self.sys.sleepTicks(1);
        }
        if (original == null) return error.Child;
        self.stage = "producer-import";
        var upload: a.GfxBufferReference = .{};
        try self.checked(self.memory.import(&original.?.reference, &upload));
        defer if (upload.reference.id != 0) { _ = self.memory.release(&upload.reference); };
        if (!std.meta.eql(upload.buffer, original.?.buffer)) return error.Descriptor;
        var target = try self.native(child_bytes);
        defer if (target.reference.id != 0) { _ = self.memory.release(&target.reference); };
        var readback = try self.system(child_bytes + 31);
        defer if (readback.reference.id != 0) { _ = self.memory.release(&readback.reference); };
        // Retain an explicit partial GPU mapping while the original process
        // disappears. This also prevents expiry of the source registration.
        self.stage = "producer-virtual-range";
        var range = try self.virtualCreate(.{ .kind = 1, .byte_length = 65536, .alignment = 65536 });
        defer if (range.resource.id != 0) { self.virtualRetire(&range.resource) catch {}; };
        self.stage = "producer-GPU-partial-map";
        var binding = try self.virtualCreate(.{ .kind = 2, .parent = range.resource, .reference = upload.reference,
            .byte_offset = 4096, .virtual_offset = 4096, .byte_length = 8192 });
        defer if (binding.resource.id != 0) { self.virtualRetire(&binding.resource) catch {}; };
        if (binding.address != range.address + 4096) return error.Virtual;
        self.stage = "producer-partial-map";
        var map: a.GfxBufferMap = .{};
        try self.checked(self.memory.map(&upload.reference, 0, 4093, 82, &map));
        defer if (map.lease.id != 0) { _ = self.memory.unmap(&map.lease); };
        if (map.cpu_address == 0 or map.byte_length != 82) return error.Map;
        const partial: [*]const u8 = @ptrFromInt(map.cpu_address);
        for (partial[0..82], 0..) |byte, offset| if (byte != pattern(4093 + offset, child_pattern)) return error.Bytes;
        try self.checked(self.memory.unmap(&map.lease)); map.lease = .{};
        for (0..2) |round| {
            if (round == 1) {
                self.stage = "producer-kill-reap";
                const identity_before = child_handle;
                try self.programChecked(self.sys.programHandleKill(&child_handle));
                var completion: a.ProgramProcessCompletion = .{};
                try self.programChecked(self.sys.programHandleWait(&child_handle, self.sys.ticksFromMilliseconds(5000), &completion));
                if (completion.exit_code != -9 or !std.meta.eql(completion.handle, child_handle)) return error.Child;
                try self.programChecked(self.sys.programHandleReap(&child_handle, &completion));
                child_handle = .{};
                var unexpected: a.GfxBufferReference = .{};
                const stale = self.memory.import(&original.?.reference, &unexpected);
                if (stale == 1) { _ = self.memory.release(&unexpected.reference); return error.Child; }
                if (stale != a.gfx_buffer_error_stale) return error.Child;
                var held: a.GfxVirtualStatus = .{};
                const draw = self.app.drawing() orelse return error.Api;
                try self.checked(draw.gfxVirtualQuery(&binding.resource, &held));
                if (!std.meta.eql(held, binding)) return error.Virtual;
                self.line("NVIDIA memory producer: reaped={d}:{d} original-reference=stale partial-GPU-binding=unchanged",
                    .{identity_before.instance_id, identity_before.generation});
            }
            self.stage = if (round == 0) "producer-before-exit" else "producer-after-exit";
            try self.initialize(readback.reference, child_bytes + 31, null);
            try self.copy(upload.reference, target.reference, 0, 0, child_bytes);
            try self.copy(upload.reference, target.reference, 3, 5, child_bytes - 11);
            try self.copy(target.reference, readback.reference, 0, 7, child_bytes);
            try self.compare(readback.reference, child_bytes, child_bytes, child_pattern);
        }
        self.stage = "producer-retire";
        try self.virtualRetire(&binding.resource);
        try self.virtualRetire(&range.resource);
        try self.checked(self.memory.release(&target.reference)); target = .{};
        try self.checked(self.memory.release(&readback.reference)); readback = .{};
        try self.checked(self.memory.release(&upload.reference)); upload = .{};
        self.line("NVIDIA memory producer: OK logical={d} GPU-bytes=exact before-and-after-reap=yes child-mapping-retired-before-parent=yes", .{child_bytes});
    }
    fn snapshot(self: *Probe) !a.GfxBufferStats {
        var stats: a.GfxBufferStats = .{};
        const end = try self.deadline();
        var previous: ?a.GfxBufferStats = null;
        var stable_since: u64 = 0;
        while (true) {
            try self.checked(self.memory.stats(&stats));
            const current = try self.now();
            if (stats.allocating_bytes != 0 or stats.destroying_bytes != 0 or stats.retained_bytes != 0) {
                previous = null;
            } else if (previous != null and std.meta.eql(previous.?, stats)) {
                // Idle queue mappings remain live before their 250ms expiry;
                // pending=0 alone does not prove a settled warm-up baseline.
                // Require every counter unchanged beyond that expiry, rather
                // than accepting a later lower count as an artificial pass.
                if (current - stable_since >= 500 * std.time.ns_per_ms) {
                    self.line("NVIDIA memory settled: window=500ms objects={d} references={d} leases={d} RAM={d} device={d} mapped={d}",
                        .{stats.objects, stats.references, stats.leases, stats.system_bytes, stats.device_bytes, stats.device_mapped_bytes});
                    return stats;
                }
            } else {
                previous = stats;
                stable_since = current;
            }
            if (current >= end) return error.Retained;
            self.sys.sleepTicks(1);
        }
    }
    fn exercise(self: *Probe) !void {
        try self.checked(self.queue.open(.{ .adapter_id = self.backend.binding.adapter_id,
            .milestone = a.gfx_queue_milestone_device_execution, .device_generation = self.backend.binding.device_generation,
            .reset_generation = self.backend.binding.reset_generation }));
        defer _ = self.queue.close();
        try self.raw(8197);
        const before = try self.snapshot();
        const runtime = @import("resource_balance.zig").Runtime.capture(self.app) orelse return error.Runtime;
        try self.raw(large_bytes);
        // Fresh small buffers after the large object force another mapping
        // lifetime. Exact contents, not VA reuse alone, decide success.
        try self.raw(8197);
        try self.oom();
        // Exact GPU work after the acknowledged denial proves the existing
        // execution epoch remains usable; an error code alone cannot do so.
        try self.raw(8197);
        try self.producerEnd();
        for ([_]u32{ a.gfx_buffer_format_xrgb8888, a.gfx_buffer_format_argb8888,
            a.gfx_buffer_format_nv12, a.gfx_buffer_format_p010 }, 0..) |format, index| {
            try self.image(format, false, @intCast(7 + index * 2));
            try self.image(format, true, @intCast(8 + index * 2));
        }
        try self.explicitVa();
        self.stage = "balance";
        var after = try self.snapshot();
        const limit = (try self.now()) + 3 * std.time.ns_per_s;
        while (!std.meta.eql(before, after) and try self.now() < limit) {
            self.sys.sleepTicks(1);
            after = try self.snapshot();
        }
        const buffers_ok = @import("resource_balance.zig").buffers(&self.sys, before, after);
        const runtime_ok = runtime.balanced(self.app);
        if (!buffers_ok or !runtime_ok) return error.Balance;
        try self.checked(self.queue.close());
        self.line("NVIDIA memory: OK CE={d} native={d} images=8 exact-bytes={d} max-pages={d} steady-state=balanced present=none",
            .{self.jobs, self.native_jobs, self.exact_bytes, (large_bytes + 4095) / 4096});
    }
};

fn childReference(sys: *const r4os.r4sys.Context, id: u32) ?a.GfxBufferReference {
    var output: [2048]u8 = undefined;
    const count = sys.consoleOutput(id, &output);
    if (count <= 0 or count > output.len) return null;
    const text = output[0..@intCast(count)];
    const start = (std.mem.indexOf(u8, text, child_marker) orelse return null) + child_marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
    var tokens = std.mem.tokenizeAny(u8, text[start..end], " \r");
    var values: [4]u64 = undefined;
    for (&values) |*value| value.* = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    if (tokens.next() != null or values[0] == 0 or values[0] > std.math.maxInt(u32) or values[1] == 0 or
        values[2] == 0 or values[2] > std.math.maxInt(u32) or values[3] == 0) return null;
    return .{ .reference = .{ .id = @intCast(values[0]), .generation = values[1] },
        .buffer = .{ .id = @intCast(values[2]), .generation = values[3] } };
}

pub fn child(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const memory = draw.buffers();
    var reference: a.GfxBufferReference = .{};
    if (memory.create(&.{ .byte_length = child_bytes, .usage = 15 }, &reference) != 1) return 1;
    defer _ = memory.release(&reference.reference);
    var map: a.GfxBufferMap = .{};
    if (memory.map(&reference.reference, 1, 0, child_bytes, &map) != 1) return 1;
    defer if (map.lease.id != 0) { _ = memory.unmap(&map.lease); };
    if (map.byte_length != child_bytes or map.cpu_address == 0) return 1;
    const data: [*]u8 = @ptrFromInt(map.cpu_address);
    for (data[0..child_bytes], 0..) |*byte, offset| byte.* = pattern(offset, child_pattern);
    if (memory.unmap(&map.lease) != 1) return 1;
    map.lease = .{};
    var line: [160]u8 = undefined;
    sys.write(std.fmt.bufPrint(&line, child_marker ++ "{d} {d} {d} {d}\n", .{
        reference.reference.id, reference.reference.generation, reference.buffer.id, reference.buffer.generation }) catch return 1);
    // Finite safety bound if invoked alone. The parent qualifies hard kill
    // and owner cleanup, so this normal-return path never counts as success.
    sys.sleepTicks(sys.ticksFromMilliseconds(20000));
    return 1;
}

fn nativeBackend(app: *r4os.App, queues: r4os.gfx_queue.Context) !a.GfxBackendInfo {
    const api = try gfx.DeviceV1Client.init(app.startContext());
    const size = api.storage_size();
    if (size == 0 or size > std.math.maxInt(usize)) return error.Size;
    const allocator = app.system().allocator();
    const storage = try allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(size));
    @memset(storage, 0);
    var device: gfx.R4GfxDevice = undefined;
    if (api.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
        .storage_bytes = storage.len, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = 0 }, &device) != gfx.status_ok) {
        allocator.free(storage); return error.Open;
    }
    var info: gfx.R4GfxDeviceInfo = undefined;
    const rc = api.device_info(&device, &info);
    if (api.device_close(&device) != gfx.status_ok) return error.Retained;
    allocator.free(storage);
    if (rc != gfx.status_ok or info.backend != gfx.render_backend_nvidia) return error.NativeUnavailable;
    for (0..a.gfx_queue_backend_capacity) |index| {
        var backend: a.GfxBackendInfo = .{};
        if (queues.backendInfo(@intCast(index), &backend) == 1 and backend.binding.adapter_id == info.adapter_id and
            backend.binding.milestone == a.gfx_queue_milestone_device_execution and backend.memory_generation != 0 and
            backend.binding.device_generation == info.device_generation and backend.binding.reset_generation == info.reset_generation)
            return backend;
    }
    return error.NativeUnavailable;
}

pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const queues = draw.queues();
    const backend = nativeBackend(app, queues) catch |err| {
        sys.write("NVIDIA memory: FAILED stage=backend error="); sys.println(@errorName(err));
        return 1;
    };
    var probe: Probe = .{ .app = app, .sys = sys, .memory = draw.buffers(), .queues = queues,
        .queue = .{ .context = queues }, .backend = backend };
    probe.exercise() catch |err| {
        probe.line("NVIDIA memory: FAILED stage={s} error={s} code={d} jobs={d} native={d} exact-bytes={d}",
            .{probe.stage, @errorName(err), probe.code, probe.jobs, probe.native_jobs, probe.exact_bytes});
        return 1;
    };
    return 0;
}
