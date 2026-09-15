// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const c = @import("r4nak");
const worker = @import("r4nak_worker");
const fixture = @import("compiler_fixture.zig");

fn fail(sys: *const r4os.r4sys.Context, line: u32, status: i32) i32 {
    var message: [160]u8 = undefined;
    sys.println(std.fmt.bufPrint(&message, "DISPLAYD compiler: FAILED line={d} status={d}", .{ line, status }) catch "DISPLAYD compiler: FAILED");
    return 1;
}
fn compile(job: *worker.Worker, request: c.R4NakRequest) i32 {
    const status = job.start(request);
    if (status != 0) return status;
    for (0..20) |_| if (job.join(job.sys.ticksFromMilliseconds(1000))) |result| return result;
    job.cancel();
    // Even on a failed join, keep stack/input/output alive. The external
    // bounded SMP4 runner detects a stuck worker; no premature free here.
    while (true) if (job.join(job.sys.ticksFromMilliseconds(100))) |result| return result;
}
fn keyFor(binary: c.R4NakBinary) c.R4NakCacheKey {
    return .{ .version = 1, .size = @sizeOf(c.R4NakCacheKey), .vendor_id = 0x10de, .device_id = 0x2504, .chipset = 0x177, .sm = binary.sm, .stage = binary.stage, .driver_version = 124, .command_abi = 1, .resource_abi = 1, .constants_abi = 4, .format = 875713089, .device_generation = 1, .reset_generation = 1, .pipeline_layout = 1, .source_hash = binary.source_hash, .pipeline_hash = .{ .h0 = 123, .h1 = 456, .h2 = 789, .h3 = 1 } };
}
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    var job = worker.Worker.init(app) catch return fail(&sys, @src().line, c.status_unsupported);
    var words = fixture.words;
    var code: [4096]u8 = @splat(0);
    var log: [1024]u8 = @splat(0);
    var request: c.R4NakRequest = .{
        .version = 1,
        .size = @sizeOf(c.R4NakRequest),
        .words = @intFromPtr(&words),
        .word_count = words.len,
        .stage = 4,
        .sm = 86,
        .entry = @intFromPtr("main".ptr),
        .entry_length = 4,
        .budget_bytes = 8 * 1024 * 1024,
        .deadline_ns = 0,
        .code = @intFromPtr(&code),
        .code_capacity = code.len,
        .log = @intFromPtr(&log),
        .log_capacity = log.len,
    };
    var rc = compile(&job, request);
    if (rc != 0) {
        sys.write(log[0..@min(job.result.log_length, log.len)]);
        return fail(&sys, @src().line, rc);
    }
    if (job.live_bytes != 0 or job.result.code_bytes == 0 or job.result.code_bytes > code.len) return fail(&sys, @src().line, -100);
    const first = job.result;
    const first_code = code;
    rc = compile(&job, request);
    if (rc != 0 or job.live_bytes != 0 or job.result.code_bytes != first.code_bytes or
        !std.meta.eql(job.result.header, first.header) or !std.meta.eql(job.result.source_hash, first.source_hash) or
        !std.mem.eql(u8, first_code[0..first.code_bytes], code[0..job.result.code_bytes])) return fail(&sys, @src().line, rc);
    words[fixture.constant_word] = 0x3f000000; // caller supplies a different shader at runtime
    rc = compile(&job, request);
    if (rc != 0 or std.meta.eql(job.result.source_hash, first.source_hash) or
        (job.result.code_bytes == first.code_bytes and std.mem.eql(u8, first_code[0..first.code_bytes], code[0..first.code_bytes]))) return fail(&sys, @src().line, rc);
    words = fixture.words;
    request.budget_bytes = 64 * 1024;
    rc = compile(&job, request);
    if (rc != c.status_memory or job.result.status != rc or job.live_bytes != 0) return fail(&sys, @src().line, rc);
    request.budget_bytes = 8 * 1024 * 1024;
    request.deadline_ns = 1;
    rc = compile(&job, request);
    if (rc != c.status_cancelled or job.result.status != rc or job.live_bytes != 0) return fail(&sys, @src().line, rc);
    request.deadline_ns = 0;
    words[0] = 0;
    if (compile(&job, request) != c.status_invalid or job.live_bytes != 0) return fail(&sys, @src().line, -101);
    words = fixture.words;
    var aliased = request;
    aliased.code = request.words;
    aliased.code_capacity = @sizeOf(@TypeOf(words));
    if (compile(&job, aliased) != c.status_invalid or job.live_bytes != 0 or
        !std.mem.eql(u32, &words, &fixture.words)) return fail(&sys, @src().line, -107);
    for ([_]u32{ 75, 86, 89, 120 }) |sm| {
        request.sm = sm;
        rc = compile(&job, request);
        if (rc != 0 or job.live_bytes != 0 or job.result.sm != sm) return fail(&sys, @src().line, rc);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(code[0..job.result.code_bytes], &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        // Independent native host-port checkpoint for this self-authored
        // SPIR-V fixture. This validates emitted bytes, not GPU execution.
        const expected = if (sm == 120)
            "2869dbdab97fbe7a385daef86dad8bd327ee50f27a385f6dc65a45eac509c9b7"
        else
            "e54e1663744994c4b5388a0f328960b35f9613ac6b82d2914bd5c3d3a64f06e7";
        if (!std.mem.eql(u8, &actual, expected)) return fail(&sys, @src().line, -106);
        var target_message: [160]u8 = undefined;
        sys.println(std.fmt.bufPrint(&target_message, "DISPLAYD compiler target: SM{d} sha256={s}", .{ sm, actual }) catch return 1);
    }
    sys.println("DISPLAYD compiler runtime: OK SPIRV-NIR-NAK SM75-SM86-SM89-SM120 reproducible changed-source OOM-retire-retry deadline malformed alias");
    var cache: [8192]u8 = @splat(0);
    var written: u64 = 0;
    const key = keyFor(job.result);
    rc = job.client.cache_write(&key, &job.result, &code, job.result.code_bytes, &cache, cache.len, &written);
    if (rc != 0 or written > cache.len) return fail(&sys, @src().line, rc);
    var decoded: c.R4NakBinary = undefined;
    var decoded_code: [4096]u8 = @splat(0);
    rc = job.client.cache_read(&key, &cache, written, &decoded, &decoded_code, decoded_code.len);
    if (rc != 0 or !std.mem.eql(u8, code[0..job.result.code_bytes], decoded_code[0..decoded.code_bytes])) return fail(&sys, @src().line, rc);
    const saved_decoded = decoded;
    const saved_code = decoded_code;
    inline for (.{ "device_id", "chipset", "driver_version", "command_abi", "resource_abi", "format", "device_generation", "reset_generation", "pipeline_layout" }) |field| {
        var wrong = key;
        @field(wrong, field) += 1;
        if (job.client.cache_read(&wrong, &cache, written, &decoded, &decoded_code, decoded_code.len) != c.status_cache_miss) return fail(&sys, @src().line, -102);
    }
    for ([_]usize{ 12, 32, 150, @intCast(written - 1) }) |offset| {
        cache[offset] ^= 1;
        rc = job.client.cache_read(&key, &cache, written, &decoded, &decoded_code, decoded_code.len);
        cache[offset] ^= 1;
        if (rc != c.status_cache_miss) return fail(&sys, @src().line, rc);
    }
    if (job.client.cache_read(&key, &cache, written - 1, &decoded, &decoded_code, decoded_code.len) != c.status_cache_miss or
        !std.meta.eql(saved_decoded, decoded) or !std.mem.eql(u8, &saved_code, &decoded_code)) return fail(&sys, @src().line, -103);
    var path_buffer: [96]u8 = undefined;
    var stage_buffer: [96]u8 = undefined;
    var backup_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "C:\\TEMP\\NAK{X}.BIN", .{job.program.generation}) catch return 1;
    const stage = std.fmt.bufPrintZ(&stage_buffer, "C:\\TEMP\\NAK{X}.NEW", .{job.program.generation}) catch return 1;
    const backup = std.fmt.bufPrintZ(&backup_buffer, "C:\\TEMP\\NAK{X}.OLD", .{job.program.generation}) catch return 1;
    defer {
        _ = sys.fileDelete(path);
        _ = sys.fileDelete(stage);
        _ = sys.fileDelete(backup);
    }
    rc = worker.saveCache(&sys, &job.client, path, stage, backup, &key, &job.result, code[0..job.result.code_bytes]);
    if (rc != 0) return fail(&sys, @src().line, rc);
    rc = worker.loadCache(&sys, &job.client, path, &key, &decoded, &decoded_code);
    if (rc != 0 or !std.mem.eql(u8, code[0..job.result.code_bytes], decoded_code[0..decoded.code_bytes])) return fail(&sys, @src().line, rc);
    cache[written - 1] ^= 1;
    if (sys.fileWrite(path, cache[0..written]) != @as(i32, @intCast(written)) or
        worker.loadCache(&sys, &job.client, path, &key, &decoded, &decoded_code) != c.status_cache_miss) return fail(&sys, @src().line, -104);
    sys.println("DISPLAYD compiler cache: OK GPU-driver-ABI-format-generation integrity truncated atomic-file corrupted-file-discard");
    const formats = [_]u32{ 875713112, 875713089, 538982482, 808669784, 808669761, 1211384385, 942948929 };
    const bits = [_]u32{ 32, 32, 8, 32, 32, 64, 64 };
    for (formats, bits) |format, block_bits| {
        var info: c.R4NakFormat = undefined;
        if (job.client.format_info(format, &info) != 0 or info.block_bits != block_bits or
            info.block_width != 1 or info.block_height != 1 or info.format != format) return fail(&sys, @src().line, -105);
    }
    var message: [256]u8 = undefined;
    sys.println(std.fmt.bufPrint(&message, "DISPLAYD compiler: OK formats=7 peak-bytes={d} compile-ns={d} code-bytes={d} live-bytes={d} GPU-execution=no", .{ first.peak_bytes, first.elapsed_ns, first.code_bytes, job.live_bytes }) catch "DISPLAYD compiler: FAILED report");
    return 0;
}
