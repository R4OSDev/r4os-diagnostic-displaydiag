// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! CPU-only compilation through the loaded R4ACO.R4L and real R4SYS workers.
const std = @import("std");
const r4os = @import("r4os");
const c = @import("r4aco");
const worker = @import("r4aco_worker");
const shaders = @import("r4aco_shaders");

fn fail(sys: *const r4os.r4sys.Context, line: u32, status: i32) i32 {
    var message: [160]u8 = undefined;
    sys.println(std.fmt.bufPrint(&message, "DISPLAYD AMDCOMPILER: FAILED line={d} status={d}", .{ line, status }) catch "DISPLAYD AMDCOMPILER: FAILED");
    return 1;
}
fn compile(job: *worker.Worker, request: c.R4AcoRequest) i32 {
    const status = job.start(request);
    if (status != 0) return status;
    for (0..20) |_| if (job.join(job.sys.ticksFromMilliseconds(1000))) |result| return result;
    job.cancel();
    // Keep all storage alive until the actual worker has retired. The outer
    // bounded SMP4 runner reports a stuck worker without freeing live inputs.
    while (true) if (job.join(job.sys.ticksFromMilliseconds(100))) |result| return result;
}
fn key(binary: c.R4AcoBinary) c.R4AcoCacheKey {
    return .{ .version = 1, .size = @sizeOf(c.R4AcoCacheKey), .vendor_id = 0x1002, .device_id = 0x15d8, .chip_revision = 0x41, .gfx_profile = 902, .stage = binary.stage, .resource_abi = 1, .command_abi = 1, .driver_version = 1, .format = 875713112, .reserved = 0, .device_generation = 1, .reset_generation = 1, .pipeline_layout = 1, .source_hash = binary.source_hash, .pipeline_hash = .{ .h0 = 1, .h1 = 2, .h2 = 3, .h3 = 4 } };
}
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    var job = worker.Worker.init(app) catch return fail(&sys, @src().line, c.status_unsupported);
    var code: [4096]u8 = @splat(0);
    var log: [2048]u8 = @splat(0);
    var request: c.R4AcoRequest = .{ .version = 1, .size = @sizeOf(c.R4AcoRequest), .stage = 5, .device_id = 0x15d8, .chip_revision = 0x41, .flags = 0, .word_count = 0, .entry_length = 4, .words = 0, .entry = @intFromPtr("main".ptr), .budget_bytes = 64 * 1024 * 1024, .deadline_ns = 0, .code = @intFromPtr(&code), .code_capacity = code.len, .log_capacity = log.len, .log = @intFromPtr(&log) };
    const Case = struct { name: []const u8, stage: u32, words: []const u32 };
    const cases = [_]Case{
        .{ .name = "fullscreen", .stage = 0, .words = &shaders.fullscreen },
        .{ .name = "color", .stage = 4, .words = &shaders.color },
        .{ .name = "copy", .stage = 5, .words = &shaders.copy },
        .{ .name = "fill", .stage = 5, .words = &shaders.fill },
        .{ .name = "shared", .stage = 5, .words = &shaders.shared },
    };
    for (cases) |item| {
        request.words = @intFromPtr(item.words.ptr);
        request.word_count = @intCast(item.words.len);
        request.stage = item.stage;
        const status = compile(&job, request);
        if (status != 0) {
            sys.write(log[0..@min(job.result.log_length, log.len)]);
            return fail(&sys, @src().line, status);
        }
        if (job.live_bytes != 0 or job.result.code_bytes > code.len or job.result.exec_bytes < 4 or job.result.exec_bytes > job.result.code_bytes or
            std.mem.readInt(u32, code[job.result.exec_bytes - 4 ..][0..4], .little) != 0xbf810000) return fail(&sys, @src().line, -100);
        if (std.mem.eql(u8, item.name, "shared") and (job.result.lds_bytes != 512 or job.result.workgroup_x != 128)) return fail(&sys, @src().line, -101);
        if (job.result.inputs_read != 0 or job.result.outputs_written != @as(u64, if (item.stage == 0) 1 else if (item.stage == 4) 16 else 0)) return fail(&sys, @src().line, -105);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(code[0..job.result.code_bytes], &digest, .{});
        var message: [256]u8 = undefined;
        sys.println(std.fmt.bufPrint(&message, "DISPLAYD AMDCOMPILER shader: {s} exec={d} code={d} sgpr={d} vgpr={d} lds={d} sha256={s}", .{ item.name, job.result.exec_bytes, job.result.code_bytes, job.result.sgprs, job.result.vgprs, job.result.lds_bytes, std.fmt.bytesToHex(digest, .lower) }) catch return 1);
    }
    request.words = @intFromPtr(&shaders.copy);
    request.word_count = shaders.copy.len;
    request.stage = 5;
    var status = compile(&job, request);
    if (status != 0) return fail(&sys, @src().line, status);
    const original = job.result;
    const original_code = code;
    request.budget_bytes = 256 * 1024;
    status = compile(&job, request);
    if (status != c.status_memory or job.live_bytes != 0 or job.result.status != status) return fail(&sys, @src().line, status);
    request.budget_bytes = 64 * 1024 * 1024;
    request.deadline_ns = 1;
    status = compile(&job, request);
    if (status != c.status_cancelled or job.live_bytes != 0 or job.result.status != status) return fail(&sys, @src().line, status);
    request.deadline_ns = 0;
    var aliased = request;
    aliased.code = aliased.words;
    aliased.code_capacity = shaders.copy.len * 4;
    if (compile(&job, aliased) != c.status_invalid or job.live_bytes != 0) return fail(&sys, @src().line, -102);
    status = compile(&job, request);
    if (status != 0 or job.live_bytes != 0 or job.result.code_bytes != original.code_bytes or
        !std.mem.eql(u8, original_code[0..original.code_bytes], code[0..job.result.code_bytes])) return fail(&sys, @src().line, status);
    sys.println("DISPLAYD AMDCOMPILER runtime: OK SPIRV-NIR-ACO GFX9 graphics copy fill shared OOM-retire-retry deadline alias reproducible");
    var bytes: [8192]u8 = undefined;
    var written: u64 = 0;
    const identity = key(job.result);
    status = job.client.cache_write(&identity, &job.result, &code, job.result.code_bytes, &bytes, bytes.len, &written);
    if (status != 0 or written > bytes.len) return fail(&sys, @src().line, status);
    var output: c.R4AcoBinary = undefined;
    var restored: [4096]u8 = undefined;
    status = job.client.cache_read(&identity, &bytes, written, &output, &restored, restored.len);
    if (status != 0 or output.code_bytes != job.result.code_bytes or !std.mem.eql(u8, code[0..output.code_bytes], restored[0..output.code_bytes])) return fail(&sys, @src().line, status);
    const saved = output;
    inline for (.{ "device_id", "chip_revision", "driver_version", "command_abi", "resource_abi", "format", "device_generation", "reset_generation", "pipeline_layout" }) |field| {
        var wrong = identity;
        @field(wrong, field) += 1;
        if (job.client.cache_read(&wrong, &bytes, written, &output, &restored, restored.len) == 0 or !std.meta.eql(saved, output)) return fail(&sys, @src().line, -103);
    }
    for ([_]usize{ 12, 32, 150, @intCast(written - 1) }) |offset| {
        bytes[offset] ^= 1;
        status = job.client.cache_read(&identity, &bytes, written, &output, &restored, restored.len);
        bytes[offset] ^= 1;
        if (status != c.status_cache_miss or !std.meta.eql(saved, output)) return fail(&sys, @src().line, status);
    }
    var path_buffer: [96]u8 = undefined;
    var stage_buffer: [96]u8 = undefined;
    var backup_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "C:\\TEMP\\ACO{X}.BIN", .{job.program.generation}) catch return 1;
    const stage = std.fmt.bufPrintZ(&stage_buffer, "C:\\TEMP\\ACO{X}.NEW", .{job.program.generation}) catch return 1;
    const backup = std.fmt.bufPrintZ(&backup_buffer, "C:\\TEMP\\ACO{X}.OLD", .{job.program.generation}) catch return 1;
    defer {
        _ = sys.fileDelete(path);
        _ = sys.fileDelete(stage);
        _ = sys.fileDelete(backup);
    }
    status = worker.saveCache(&sys, &job.client, path, stage, backup, &identity, &job.result, code[0..job.result.code_bytes]);
    if (status != 0) return fail(&sys, @src().line, status);
    status = worker.loadCache(&sys, &job.client, path, &identity, &output, &restored);
    if (status != 0 or !std.mem.eql(u8, code[0..output.code_bytes], restored[0..output.code_bytes])) return fail(&sys, @src().line, status);
    bytes[written - 1] ^= 1;
    if (sys.fileWrite(path, bytes[0..written]) != @as(i32, @intCast(written)) or worker.loadCache(&sys, &job.client, path, &identity, &output, &restored) != c.status_cache_miss) return fail(&sys, @src().line, -104);
    sys.println("DISPLAYD AMDCOMPILER cache: OK compiler-ASIC-ABI-pipeline-epoch integrity atomic-file corrupted-file-discard");
    sys.println("DISPLAYD AMDCOMPILER: OK CPU-only loaded R4ACO no GPU execution");
    return 0;
}
