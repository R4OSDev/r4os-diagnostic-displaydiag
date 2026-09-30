// Copyright (c) 2024 Valve Corp. and Collabora, Ltd.
// Copyright 2026 R4. SPDX-License-Identifier: MIT
// Inverse TuringColor2D coordinates derived from Mesa26.2.2 nil/copy.rs
// and tiling.rs. See Licenses/NVIDIA-GOB-MIT.txt for provenance and license.
// This independent oracle does not use NVIDIA.R4D's image-plan helpers.

pub const Coordinate = struct { x: u64, y: u64 };

pub fn coordinate(offset: u64, pitch: u64, block_height_log2: u6) !Coordinate {
    if (pitch == 0 or pitch & 63 != 0 or block_height_log2 > 5) return error.Layout;
    const tile_height: u64 = @as(u64, 8) << block_height_log2;
    const tile_bytes = pitch * tile_height;
    const column_bytes: u64 = @as(u64, 512) << block_height_log2;
    const within_tile = offset % tile_bytes;
    const within_column = within_tile % column_bytes;
    const gob = within_column & 511;
    return .{
        .x = within_tile / column_bytes * 64 + (gob & 15) +
            ((gob >> 6) & 1) * 16 + ((gob >> 8) & 1) * 32,
        .y = offset / tile_bytes * tile_height + within_column / 512 * 8 +
            ((gob >> 4) & 3) + ((gob >> 7) & 1) * 4,
    };
}

test "inverse matches original Turing 16-byte line table across GOB and tile boundaries" {
    const testing = @import("std").testing;
    // Fixed first256-byte half from Mesa's for_each_gob_line, not generated
    // by an algebraic inverse of coordinate(). The second half starts x32.
    const lines = [_][2]u64{
        .{0,0}, .{0,1}, .{0,2}, .{0,3},
        .{16,0}, .{16,1}, .{16,2}, .{16,3},
        .{0,4}, .{0,5}, .{0,6}, .{0,7},
        .{16,4}, .{16,5}, .{16,6}, .{16,7},
    };
    for ([_]u64{64,192,320,576}) |pitch| {
        for ([_]u6{0,1,2}) |height_log2| {
            const gobs: u64 = @as(u64, 1) << height_log2;
            for ([_]u64{0,1,7}) |tile_row| {
                for (0..@intCast(pitch / 64)) |column| for (0..@intCast(gobs)) |gob_row| {
                    const base = tile_row * pitch * (8 * gobs) + column * (512 * gobs) + gob_row * 512;
                    for (0..2) |half| for (lines, 0..) |xy, line| for (0..16) |byte| {
                        const result = try coordinate(base + half * 256 + line * 16 + byte, pitch, height_log2);
                        try testing.expectEqual(column * 64 + half * 32 + xy[0] + byte, result.x);
                        try testing.expectEqual(tile_row * (8 * gobs) + gob_row * 8 + xy[1], result.y);
                    };
                };
            }
        }
    }
    try testing.expectError(error.Layout, coordinate(0, 0, 0));
    try testing.expectError(error.Layout, coordinate(0, 63, 0));
    try testing.expectError(error.Layout, coordinate(0, 64, 6));
}
