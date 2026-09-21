// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Exercise the loaded C++ render bridge and embedded ACO programs on the CPU.
//! Addresses are encoder inputs only; this probe never submits GPU work.
const std = @import("std");
const r4os = @import("r4os");
const c = @import("r4amd");
fn ok(rc: i32) !void {
    if (rc != c.status_ok) return error.Provider;
}
fn packets(words: []const u32) !void {
    var at: usize = 0;
    while (at < words.len) {
        if (words[at] >> 30 != 3) return error.PacketType;
        const count = ((words[at] >> 16) & 0x3fff) + 2;
        if (count > words.len - at) return error.PacketLength;
        at += count;
    }
}
fn exercise(app: *r4os.App, client: c.RenderV1Client, images: c.ImageV1Client, scratch: []u8) !void {
    const sys = app.system();
    var code: [8192]u8 = undefined;
    var shaders: [6]c.R4AmdShader = undefined;
    for (&shaders, 0..) |*shader, i| {
        try ok(client.shader(@intCast(i), &code, code.len, shader));
        if (shader.code_address != 0 or shader.code_bytes > code.len or shader.exec_bytes < 4 or shader.exec_bytes > shader.code_bytes or
            shader.resource_abi != @as(u32, if (i < 3) 1 else 2) or shader.stage != @as(u32, if (i < 2) 0 else 4) or
            std.mem.readInt(u32, code[shader.exec_bytes - 4 ..][0..4], .little) != 0xbf810000) return error.Shader;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(code[0..shader.code_bytes], &hash, .{});
        var line: [192]u8 = undefined;
        sys.println(try std.fmt.bufPrint(&line, "DISPLAYD AMDRENDER shader: profile={d} code={d} sha256={s}", .{ i, shader.code_bytes, std.fmt.bytesToHex(hash, .lower) }));
        shader.code_address = 0x8080000000 + i * 65536;
    }
    var request = std.mem.zeroes(c.R4AmdImageRequest);
    request.version = 1; request.size = @sizeOf(c.R4AmdImageRequest);
    request.gb_addr_config = 0x24000042; request.chip_revision = 0x41; request.device_id = 0x15d8; request.gc_version = c.gc_9_1_0;
    request.resource_type = 1; request.format = 875713089; request.width = 256; request.height = 128;
    request.depth = 1; request.mip_count = 1; request.samples = 1; request.usage = 3;
    var layout: c.R4AmdImageLayout = undefined;
    var mips: [15]c.R4AmdMip = undefined;
    try ok(images.calculate(&request, scratch.ptr, @intCast(scratch.len), &layout, &mips, 15));
    var view = std.mem.zeroes(c.R4AmdImageView);
    view.version = 1; view.size = @sizeOf(c.R4AmdImageView); view.address = 0x123400000000; view.byte_length = layout.byte_length;
    var target: c.R4AmdImageDescriptors = undefined;
    try ok(images.descriptors(&request, &view, scratch.ptr, @intCast(scratch.len), &target));
    var state = std.mem.zeroes(c.R4AmdPipeline);
    state.version = 1; state.size = @sizeOf(c.R4AmdPipeline); state.gb_addr_config = request.gb_addr_config;
    state.write_mask = 15; state.rop = 0xcc; state.polygon = 2; state.primitive = 3;
    state.depth_clip = 1; state.depth_compare = 7; state.depth_max = @bitCast(@as(f32, 1)); state.line_width = state.depth_max;
    state.src_rgb = 1; state.src_alpha = 1; state.dst_rgb = 5; state.dst_alpha = 5; state.blend_enable = 1;
    var depth = std.mem.zeroes(c.R4AmdDepth);
    depth.version = 1; depth.size = @sizeOf(c.R4AmdDepth);
    var words: [386]u32 = @splat(0xdeadbeef);
    var written: u32 = 0;
    try ok(client.encode_pipeline(&shaders[0], &shaders[3], &state, &target, &depth, words[1..].ptr, 384, &written));
    if (written < 32 or written > 384 or words[0] != 0xdeadbeef or words[385] != 0xdeadbeef) return error.PipelineBounds;
    try packets(words[1..][0..written]);
    const saved = words; const count = written;
    state.line_width = 0x7fc00000;
    if (client.encode_pipeline(&shaders[0], &shaders[3], &state, &target, &depth, words[1..].ptr, 384, &written) != c.status_invalid or
        !std.mem.eql(u32, &words, &saved) or count != written) return error.Rejection;
    var draw = std.mem.zeroes(c.R4AmdDraw);
    draw.version = 1; draw.size = @sizeOf(c.R4AmdDraw); draw.descriptors = 0x8080100000; draw.push_constants = 0x8080100200;
    draw.count = 3; draw.instances = 2; draw.viewport_width = @bitCast(@as(f32, 256)); draw.viewport_height = @bitCast(@as(f32, 128));
    draw.depth_max = @bitCast(@as(f32, 1)); draw.scissor_end_x = 256; draw.scissor_end_y = 128;
    try ok(client.encode_draw(&draw, &words, 80, &written));
    try packets(words[0..written]);
    if (words[written - 3] != 0xc0012d00 or words[written - 2] != 3) return error.AutoDraw;
    draw.index_type = 2; draw.index_address = 0x8080110000; draw.index_bytes = 64; draw.first_index = 2;
    try ok(client.encode_draw(&draw, &words, 80, &written));
    try packets(words[0..written]);
    if (words[written - 6] != 0xc0042700 or words[written - 5] != 14) return error.IndexDraw;
    const indexed = words; const indexed_count = written;
    draw.count = 15;
    if (client.encode_draw(&draw, &words, 80, &written) != c.status_invalid or
        !std.mem.eql(u32, &words, &indexed) or written != indexed_count) return error.IndexBounds;
    if (client.encode_draw(&draw, &words, 80, &words[0]) != c.status_invalid or !std.mem.eql(u32, &words, &indexed)) return error.Alias;
}
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const client = c.RenderV1Client.init(app.startContext()) catch {
        sys.println("DISPLAYD AMDRENDER: FAILED optional R4AMD RENDER_V1 unavailable"); return 1;
    };
    const images = c.ImageV1Client.init(app.startContext()) catch {
        sys.println("DISPLAYD AMDRENDER: FAILED optional R4AMD IMAGE_V1 unavailable"); return 1;
    };
    const allocator = sys.allocator();
    const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), c.image_workspace_bytes) catch return 1;
    defer allocator.free(scratch);
    exercise(app, client, images, scratch) catch |err| {
        sys.write("DISPLAYD AMDRENDER: FAILED "); sys.println(@errorName(err)); return 1;
    };
    sys.println("DISPLAYD AMDRENDER: OK CPU-only loaded R4AMD six ACO shaders AddrLib pipeline indexed draw rejection alias; no GPU execution");
    return 0;
}
