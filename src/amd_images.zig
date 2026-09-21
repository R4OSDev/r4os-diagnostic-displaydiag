// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! CPU-only reference probe for the loaded R4AMD.R4L, including relocations,
//! C++ vtables and real Addr2 callbacks. No live device/BO/MMIO is used.
const std = @import("std");
const r4os = @import("r4os");
const c = @import("r4amd");
fn check(rc: i32) !void {
    if (rc != c.status_ok) return error.Provider;
}
fn exercise(client: c.ImageV1Client, scratch: []u8) !void {
    var r: c.R4AmdImageRequest = .{ .version = 1, .size = @sizeOf(c.R4AmdImageRequest), .gb_addr_config = 0x24000042, .chip_revision = 0x41, .device_id = 0x15d8, .gc_version = c.gc_9_1_0, .resource_type = 1, .format = 875713112, .width = 257, .height = 129, .depth = 1, .mip_count = 1, .samples = 1, .usage = 3, .swizzle = 0, .pipe_xor = 0, .pitch = 0, .reserved = 0, .modifier = 0 };
    var layout: c.R4AmdImageLayout = undefined;
    var mips: [15]c.R4AmdMip = undefined;
    try check(client.calculate(&r, scratch.ptr, @intCast(scratch.len), &layout, &mips, 15));
    if (layout.pitch != 1280 or layout.byte_length != 165120 or layout.alignment != 256) return error.Linear;
    var address: c.R4AmdImageAddress = undefined;
    try check(client.address(&r, &.{ .version = 1, .size = @sizeOf(c.R4AmdCoordinate), .x = 17, .y = 19, .slice = 0, .sample = 0, .mip = 0, .reserved = 0 }, scratch.ptr, @intCast(scratch.len), &address));
    if (address.offset != 1280 * 19 + 17 * 4 or address.bit_position != 0) return error.Address;
    r.swizzle = 26;
    r.modifier = 0x0200000000401a01;
    r.mip_count = 9;
    try check(client.calculate(&r, scratch.ptr, @intCast(scratch.len), &layout, &mips, 15));
    if (layout.pitch != 1536 or layout.byte_length != 786432 or layout.alignment != 65536 or layout.first_mip_tail != 3) return error.Tiled;
    var metadata: c.R4AmdMetadata = undefined;
    try check(client.metadata(&r, scratch.ptr, @intCast(scratch.len), &metadata));
    if (metadata.kind != 1 or metadata.flags != 0 or metadata.byte_length == 0) return error.Metadata;
    var desc: c.R4AmdImageDescriptors = undefined;
    try check(client.descriptors(&r, &.{ .version = 1, .size = @sizeOf(c.R4AmdImageView), .address = 0x100000000, .byte_length = layout.byte_length, .offset = 0, .first_layer = 0, .last_layer = 0, .first_mip = 0, .last_mip = 8, .sampler = 1, .min_lod = 0, .max_lod = 2048, .lod_bias = 0, .wrap_u = 2, .wrap_v = 2, .wrap_w = 2, .compare = 7, .aniso = 0, .border = 0, .flags = 0, .reserved = 0 }, scratch.ptr, @intCast(scratch.len), &desc));
    if (desc.texture0 != 0x1000000 or desc.texture6 != 0 or desc.texture7 != 0 or desc.color13 != 0) return error.Descriptors;
    const before = layout;
    r.modifier |= 1 << 13;
    if (client.calculate(&r, scratch.ptr, @intCast(scratch.len), &layout, &mips, 15) != c.status_unsupported or !std.meta.eql(before, layout)) return error.Rejection;
    r.modifier = 0x0200000000401a01;
    if (client.calculate(&r, scratch.ptr, 16, &layout, &mips, 15) != c.status_oom or !std.meta.eql(before, layout)) return error.Allocation;
}
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const client = c.ImageV1Client.init(app.startContext()) catch {
        sys.println("DISPLAYD AMDIMAGE: FAILED optional R4AMD IMAGE_V1 unavailable");
        return 1;
    };
    const allocator = sys.allocator();
    const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), c.image_workspace_bytes) catch {
        sys.println("DISPLAYD AMDIMAGE: FAILED workspace allocation");
        return 1;
    };
    defer allocator.free(scratch);
    exercise(client, scratch) catch |err| {
        sys.write("DISPLAYD AMDIMAGE: FAILED ");
        sys.println(@errorName(err));
        return 1;
    };
    sys.println("DISPLAYD AMDIMAGE: OK CPU-only AddrLib linear tiled mips metadata descriptors rejection; no GPU execution");
    return 0;
}
