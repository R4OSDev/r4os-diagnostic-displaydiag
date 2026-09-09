const std = @import("std");

pub const max_samples = 64;
pub const Scene = enum { idle, small_damage, window_move, text, alpha_layers, full_image, scaling, producers };
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };
pub const Work = struct {
    rects: [8]Rect = undefined,
    count: usize = 0,
    render_writes: u64 = 0,
    render_reads: u64 = 0,
    composition_reads: u64 = 0,
    composition_writes: u64 = 0,

    pub fn pixels(self: Work) u64 {
        var result: u64 = 0;
        for (self.rects[0..self.count]) |r| result += @as(u64, r.w) * r.h;
        return result;
    }
};

// Deterministic CPU reference scenes. These are workload primitives, not
// measurements of Desktop.R4X or of concurrent program scheduling.
pub fn render(scene: Scene, source: []u32, width: u32, height: u32, frame: u32) Work {
    std.debug.assert(width >= 8 and height >= 8 and source.len == @as(usize, width) * height);
    var work = Work{};
    const full = Rect{ .x = 0, .y = 0, .w = width, .h = height };
    switch (scene) {
        .idle => return work,
        .small_damage => {
            work.rects[0] = .{ .x = 0, .y = 0, .w = @min(width, 16), .h = @min(height, 16) };
            work.count = 1;
        },
        .window_move => {
            const w = @min(width / 4, 128);
            const h = @min(height, 96);
            work.rects[0] = .{ .x = (frame % 2) * (width - w), .y = 0, .w = w, .h = h };
            work.rects[1] = .{ .x = ((frame + 1) % 2) * (width - w), .y = 0, .w = w, .h = h };
            work.count = 2;
        },
        .producers => {
            // Four independent regions, serialized into one generation.
            for (0..4) |i| work.rects[i] = .{ .x = @as(u32, @intCast(i)) * (width / 4), .y = 0, .w = width / 4, .h = height };
            work.count = 4;
        },
        else => {
            work.rects[0] = full;
            work.count = 1;
        },
    }
    for (work.rects[0..work.count], 0..) |r, producer| {
        for (r.y..r.y + r.h) |y| {
            for (r.x..r.x + r.w) |x| {
                const xx: u32 = @intCast(x);
                const yy: u32 = @intCast(y);
                const color: u32 = switch (scene) {
                    // A bounded generated 8x8 diagnostic glyph mask; no font cache/API claim.
                    .text => if (((xx / 8 + yy / 8 + frame) >> @intCast(yy % 5)) & 1 != 0 and xx % 8 < 6) 0x00dddddd else 0x00101010,
                    // Nearest-neighbour sampling of a procedural 64x64 image.
                    .scaling => (((xx * 64 / width) ^ (yy * 64 / height) ^ frame) & 255) * 0x00010101,
                    else => ((xx ^ yy ^ frame ^ @as(u32, @intCast(producer * 57))) & 255) * 0x00010101,
                };
                source[y * width + x] = color;
            }
        }
    }
    work.render_writes = work.pixels() * 4;
    return work;
}

pub fn compose(scene: Scene, source: []const u32, output: []u32, width: u32, work: *Work) void {
    for (work.rects[0..work.count]) |r| {
        for (r.y..r.y + r.h) |y| {
            const start = y * width + r.x;
            const end = start + r.w;
            if (scene == .alpha_layers) {
                for (source[start..end], output[start..end]) |pixel, *out| {
                    // Two 50% constant-color layers, then a single output store.
                    const first = ((pixel & 0x00fefefe) >> 1) + 0x00402010;
                    out.* = ((first & 0x00fefefe) >> 1) + 0x00102040;
                }
            } else @memcpy(output[start..end], source[start..end]);
        }
    }
    work.composition_reads = work.pixels() * 4;
    work.composition_writes = work.pixels() * 4;
}

pub const Samples = struct {
    values: [max_samples]u64 = .{0} ** max_samples,
    count: usize = 0,
    total: u64 = 0,
    pub fn add(self: *Samples, value: u64) void {
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = value;
        self.count += 1;
        self.total += value;
    }
    pub fn percentile(self: Samples, percent: u32) ?u64 {
        if (self.count == 0 or percent == 0 or percent > 100) return null;
        var sorted = self.values;
        std.mem.sort(u64, sorted[0..self.count], {}, std.sort.asc(u64));
        return sorted[(self.count * percent + 99) / 100 - 1];
    }
};

test "all scenes stay in small and unaligned viewports with exact byte models" {
    var source: [19 * 11]u32 = @splat(0);
    var output: [19 * 11]u32 = @splat(0xdeadbeef);
    inline for (std.meta.tags(Scene)) |scene| {
        var work = render(scene, &source, 19, 11, 3);
        var mask: [19 * 11]bool = @splat(false);
        for (work.rects[0..work.count]) |r| {
            try std.testing.expect(r.w > 0 and r.h > 0 and r.x + r.w <= 19 and r.y + r.h <= 11);
            for (r.y..r.y + r.h) |y| for (r.x..r.x + r.w) |x| {
                try std.testing.expect(!mask[y * 19 + x]);
                mask[y * 19 + x] = true;
            };
        }
        @memset(&output, 0xdeadbeef);
        compose(scene, &source, &output, 19, &work);
        for (output, mask) |pixel, touched| try std.testing.expect((pixel != 0xdeadbeef) == touched);
        try std.testing.expectEqual(work.pixels() * 4, work.render_writes);
        try std.testing.expectEqual(work.render_writes, work.composition_writes);
        try std.testing.expectEqual(work.composition_reads, work.composition_writes);
    }
}

test "nearest-rank percentiles preserve samples and expose empty sets" {
    var samples = Samples{};
    try std.testing.expect(samples.percentile(50) == null);
    for (0..max_samples) |i| samples.add(@intCast(max_samples - i));
    try std.testing.expectEqual(@as(?u64, 32), samples.percentile(50));
    try std.testing.expectEqual(@as(?u64, 61), samples.percentile(95));
    try std.testing.expectEqual(@as(?u64, 64), samples.percentile(99));
    try std.testing.expectEqual(@as(u64, 64), samples.values[0]);
}
