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
        ok = self.checkBenchmarkSmoke() and ok;

        self.sys.write("DISPLAYD result: ");
        self.sys.println(if (ok) "OK" else "FAILED");
        return if (ok) 0 else 1;
    }

    fn checkApi(self: *App) bool {
        const ok = self.dev.hasFn("display_summary") and self.draw.screenWidth() > 0 and self.draw.screenHeight() > 0;
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
