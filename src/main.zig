const r4os = @import("r4os");

const App = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,
    draw: r4os.r4draw.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .dev = r4_app.devicesLowLevel() orelse return null,
            .draw = r4_app.drawing() orelse return null,
        };
    }

    fn run(self: *App) i32 {
        self.sys.println("DISPLAYD");
        var ok = true;
        ok = self.checkApi() and ok;
        ok = self.checkSummary() and ok;
        ok = self.checkPresentSmoke() and ok;
        ok = self.checkDamagePresent() and ok;
        ok = self.checkBenchmarkSmoke() and ok;

        self.sys.write("DISPLAYD result: ");
        self.sys.println(if (ok) "OK" else "FAILED");
        return if (ok) 0 else 1;
    }

    fn checkApi(self: *App) bool {
        const ok = self.dev.hasFn("display_summary") and
            self.draw.supportsDisplayPresentRegions() and
            self.draw.screenWidth() > 0 and self.draw.screenHeight() > 0;
        self.printCheck("DISPLAYD api display-summary", ok);
        if (!ok) return false;
        self.sys.write("  R4SYS runtime version=");
        self.sys.printU64(self.sys.tableAbiVersion());
        self.sys.write(" size=");
        self.sys.printU64(self.sys.tableSize());
        self.sys.println("");
        return true;
    }

    fn checkSummary(self: *App) bool {
        const summary = self.dev.displaySummary() orelse return self.failBool("DISPLAYD summary unavailable");
        const name = fixedName(&summary.backend_name);
        const ok = (summary.flags & r4os.abi.display_summary_flag_registered) != 0 and
            summary.backend_kind != r4os.abi.display_summary_backend_none and
            summary.width > 0 and
            summary.height > 0 and
            summary.pitch > 0 and
            summary.bpp >= 24 and
            summary.width == self.draw.screenWidth() and
            summary.height == self.draw.screenHeight() and
            name.len > 0;
        self.sys.write("DISPLAYD summary: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" backend=");
        self.sys.write(name);
        self.sys.write(" mode=");
        self.sys.printU64(@as(u64, summary.width));
        self.sys.write("x");
        self.sys.printU64(@as(u64, summary.height));
        self.sys.write("x");
        self.sys.printU64(@as(u64, summary.bpp));
        self.sys.write(" pitch=");
        self.sys.printU64(@as(u64, summary.pitch));
        self.sys.write(" presents=");
        self.sys.printU64(summary.present_count);
        self.sys.write(" ticks=");
        self.sys.printU64(summary.present_last_ticks);
        self.sys.write("/");
        self.sys.printU64(summary.present_max_ticks);
        self.sys.write(" cache=");
        self.sys.write(cacheName(summary.cache_policy));
        self.sys.println("");
        return ok;
    }

    fn checkDamagePresent(self: *App) bool {
        var capabilities: r4os.abi.DisplayPresentCapabilities = .{};
        if (self.draw.displayPresentCapabilities(&capabilities) != 0) {
            return self.failBool("DISPLAYD damage capabilities unavailable");
        }
        const required_caps = r4os.abi.display_present_cap_cpu_fallback |
            r4os.abi.display_present_cap_exact_regions |
            r4os.abi.display_present_cap_sync_fence |
            r4os.abi.display_present_cap_accelerated_blit |
            r4os.abi.display_present_cap_external_backend;
        const backend_name = fixedName24(&capabilities.backend_name);
        const fallback_name = fixedName24(&capabilities.fallback_name);
        if (capabilities.backend_kind != r4os.abi.display_present_backend_external_blit or
            capabilities.max_regions < 2 or
            (capabilities.flags & required_caps) != required_caps or
            !equal(backend_name, "DISPBLIT") or
            !equal(fallback_name, "bootfb-cpu"))
        {
            return self.failBool("DISPLAYD damage capabilities failed");
        }

        const width = self.draw.screenWidth();
        const height = self.draw.screenHeight();
        if (width < 8 or height < 8) return self.failBool("DISPLAYD damage geometry too small");
        const pixel_count_u64 = @as(u64, width) * height;
        if (pixel_count_u64 == 0 or pixel_count_u64 > ~@as(u32, 0) or pixel_count_u64 > ~@as(usize, 0)) {
            return self.failBool("DISPLAYD damage source too large");
        }
        const allocator = self.sys.allocator();
        const pixels = allocator.alloc(u32, @intCast(pixel_count_u64)) catch {
            return self.failBool("DISPLAYD damage source allocation failed");
        };
        defer allocator.free(pixels);

        const regions = [_]r4os.abi.DisplayDamageRect{
            .{ .x = 1, .y = 1, .w = 2, .h = 2 },
            .{ .x = @intCast(width - 3), .y = @intCast(height - 3), .w = 2, .h = 2 },
        };
        fillRegion(pixels, width, regions[0], 0x00_12_34_56);
        fillRegion(pixels, width, regions[1], 0x00_65_43_21);

        const source_generation: u64 = 0xD15A_0001;
        const input_tick = self.sys.ticks();
        self.sys.sleepTicks(1);
        const before = self.dev.displaySummary() orelse return self.failBool("DISPLAYD damage summary before unavailable");
        const request = r4os.abi.DisplayPresentRequest{
            .flags = r4os.abi.display_present_request_flag_input_tick_valid,
            .source_width = width,
            .source_height = height,
            .source_stride_pixels = width,
            .source_generation = source_generation,
            .input_tick = input_tick,
        };
        var result: r4os.abi.DisplayPresentResult = .{};
        const present_rc = self.draw.displayPresentRegions(&request, pixels, regions[0..], &result);
        var completion: r4os.abi.DisplayPresentCompletion = .{};
        const completion_rc = if (result.fence == 0)
            r4os.abi.display_present_error_invalid
        else
            self.draw.displayPresentCompletion(result.fence, &completion);
        const after = self.dev.displaySummary() orelse return self.failBool("DISPLAYD damage summary after unavailable");

        const too_many = [_]r4os.abi.DisplayDamageRect{regions[0]} ** 9;
        var invalid_result: r4os.abi.DisplayPresentResult = .{};
        const invalid_rc = self.draw.displayPresentRegions(&request, pixels, too_many[0..], &invalid_result);
        const invalid_after = self.dev.displaySummary() orelse return self.failBool("DISPLAYD damage invalid summary unavailable");
        const expected_flags = r4os.abi.display_present_result_success |
            r4os.abi.display_present_result_completed |
            r4os.abi.display_present_result_accelerated;
        const ok = present_rc == 0 and
            (result.flags & expected_flags) == expected_flags and
            (result.flags & r4os.abi.display_present_result_fallback) == 0 and
            result.source_generation == source_generation and
            result.present_generation != 0 and result.fence == result.completed_fence and
            result.region_count == 2 and result.pixel_count == 8 and
            result.fallback_regions == 0 and result.backend_error == 0 and
            result.elapsed_ticks > 0 and equal(fixedName24(&result.backend_name), "DISPBLIT") and
            completion_rc == 0 and
            (completion.flags & r4os.abi.display_present_completion_complete) != 0 and
            completion.fence == result.fence and completion.completed_fence >= result.fence and
            after.present_count == before.present_count + 1 and
            after.last_present_pixels == 8 and after.last_present_bytes == 32 and
            invalid_rc == r4os.abi.display_present_error_invalid and
            invalid_after.present_count == after.present_count;

        self.sys.write("DISPLAYD damage-present: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" regions=");
        self.sys.printU64(result.region_count);
        self.sys.write(" pixels=");
        self.sys.printU64(result.pixel_count);
        self.sys.write(" fence=");
        self.sys.printU64(result.fence);
        self.sys.write(" backend=");
        self.sys.write(fixedName24(&result.backend_name));
        self.sys.write(" fallback=");
        self.sys.printU64(result.fallback_regions);
        self.sys.write(" inputTicks=");
        self.sys.printU64(result.elapsed_ticks);
        self.sys.println("");
        return ok;
    }

    fn checkPresentSmoke(self: *App) bool {
        const before = self.draw.displayRevision();
        const pixel: [1]u32 = .{0x00_40_80_c0};
        const begin_rc = self.draw.displayBeginFrameRect(0, 0, 1, 1);
        const blit_rc = self.draw.displayBlitXrgb32(0, 0, 1, 1, pixel[0..]);
        const present_rc = self.draw.displayPresent();
        const after = self.draw.displayRevision();
        const summary = self.dev.displaySummary() orelse return self.failBool("DISPLAYD present summary unavailable");
        const ok = begin_rc > 0 and blit_rc >= 0 and present_rc > 0 and after >= before and
            (summary.flags & r4os.abi.display_summary_flag_registered) != 0 and
            summary.present_max_ticks >= summary.present_last_ticks and
            summary.present_total_ticks >= summary.present_last_ticks;
        self.sys.write("DISPLAYD present-smoke: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" rev=");
        self.sys.printU64(@as(u64, before));
        self.sys.write("->");
        self.sys.printU64(@as(u64, after));
        self.sys.write(" kernel-presents=");
        self.sys.printU64(summary.present_count);
        self.sys.write(" last=");
        self.sys.write(reasonName(summary.last_present_reason));
        self.sys.write(" ticks=");
        self.sys.printU64(summary.present_last_ticks);
        self.sys.write("/");
        self.sys.printU64(summary.present_max_ticks);
        self.sys.println("");
        return ok;
    }

    fn checkBenchmarkSmoke(self: *App) bool {
        const loops: u32 = 16;
        const start = self.sys.ticks();
        var i: u32 = 0;
        var ok = true;
        while (i < loops) : (i += 1) {
            ok = self.draw.displayBeginFrameRect(0, 0, 1, 1) > 0 and ok;
            ok = self.draw.displayPresent() > 0 and ok;
        }
        const end = self.sys.ticks();
        self.sys.write("DISPLAYD benchmark: ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" loops=");
        self.sys.printU64(@as(u64, loops));
        self.sys.write(" ticks=");
        self.sys.printU64(end - start);
        const summary = self.dev.displaySummary() orelse return false;
        self.sys.write(" presentTicks=");
        self.sys.printU64(summary.present_last_ticks);
        self.sys.write("/");
        self.sys.printU64(summary.present_max_ticks);
        self.sys.write(" total=");
        self.sys.printU64(summary.present_total_ticks);
        self.sys.println("");
        return ok;
    }

    fn printCheck(self: *App, label: []const u8, ok: bool) void {
        self.sys.write(label);
        self.sys.write(": ");
        self.sys.println(if (ok) "OK" else "FAILED");
    }

    fn failBool(self: *App, msg: []const u8) bool {
        self.sys.println(msg);
        return false;
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    return app.run();
}

fn fixedName(value: *const [32]u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn fixedName24(value: *const [24]u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn fillRegion(pixels: []u32, stride: u32, rect: r4os.abi.DisplayDamageRect, color: u32) void {
    var y: u32 = 0;
    while (y < rect.h) : (y += 1) {
        var x: u32 = 0;
        while (x < rect.w) : (x += 1) {
            const offset = (@as(usize, @intCast(rect.y)) + y) * stride + @as(usize, @intCast(rect.x)) + x;
            pixels[offset] = color ^ (x << 8) ^ y;
        }
    }
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) if (a[index] != b[index]) return false;
    return true;
}

fn cacheName(value: u8) []const u8 {
    return switch (value) {
        r4os.abi.display_summary_cache_bootloader_default => "bootloader",
        r4os.abi.display_summary_cache_pat_write_combining => "pat-wc",
        r4os.abi.display_summary_cache_write_combining_unsupported => "wc-unsupported",
        r4os.abi.display_summary_cache_write_combining_failed => "wc-failed",
        else => "unknown",
    };
}

fn reasonName(value: u8) []const u8 {
    return switch (value) {
        r4os.abi.display_summary_reason_fill => "fill",
        r4os.abi.display_summary_reason_rect => "rect",
        r4os.abi.display_summary_reason_packed32_present => "packed32",
        r4os.abi.display_summary_reason_xrgb32_present => "xrgb32",
        else => "none",
    };
}
