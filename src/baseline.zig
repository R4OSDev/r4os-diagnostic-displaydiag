const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const scenes = @import("scenes.zig");

const Options = struct {
    present: bool = false,
    trace: bool = false,
    samples: u32 = 32,
    save: []const u8 = "",
};

const Report = struct {
    bytes: [32768]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn write(self: *Report, data: []const u8) void {
        if (data.len > self.bytes.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }
    fn line(self: *Report, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch {
            self.overflow = true;
            return;
        };
        self.write(text);
        self.write("\r\n");
    }
    fn times(self: *Report, label: []const u8, samples: scenes.Samples) void {
        if (samples.count == 0) {
            self.line("  {s}=unavailable samples=0", .{label});
            return;
        }
        self.line("  {s}_wall_ns samples={d} total={d} p50={d} p95={d} p99={d}", .{
            label, samples.count, samples.total, samples.percentile(50).?, samples.percentile(95).?, samples.percentile(99).?,
        });
    }
};

const Clock = struct {
    sys: *const r4os.r4sys.Context,
    generation: u32,
    source: u32,
    fn now(self: Clock) ?u64 {
        var info: abi.MonotonicClockInfo = .{};
        if (self.sys.monotonicClock(&info) <= 0 or
            info.flags & abi.monotonic_clock_flag_valid == 0 or
            info.frequency_hz != abi.monotonic_clock_frequency_hz or
            info.generation != self.generation or info.source != self.source) return null;
        return info.instant_ns;
    }
    fn elapsed(self: Clock, start: u64) ?u64 {
        const end = self.now() orelse return null;
        return if (end >= start) end - start else null;
    }
};

pub fn requested(args: []const u8) bool {
    return args.len != 0;
}

pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const dev = app.devicesLowLevel() orelse return abi.err_no_group;
    const draw = app.drawing() orelse return abi.err_no_group;
    const options = parse(std.mem.span(sys.argsRaw())) orelse {
        sys.println("DISPLAYD /BASELINE [/PRESENT] [/TRACE] [/SAMPLES=1..64] [/SAVE=C:\\TEMP\\REPORT.TXT]");
        sys.println("No arguments: compatibility smoke. BASELINE: RAM scenes; PRESENT also writes diagnostic images to the screen.");
        return 2;
    };
    const allocator = sys.allocator();
    const report = allocator.create(Report) catch return 1;
    defer allocator.destroy(report);
    report.* = .{};
    if (options.trace) sys.println("DISPLAYD baseline phase: report-ready");
    const ok = collect(sys, dev, draw, options, report) and !report.overflow;
    report.line("DISPLAYD baseline result: {s}", .{if (ok) "OK" else "FAILED"});
    if (options.save.len != 0) {
        var path: [256:0]u8 = @splat(0);
        @memcpy(path[0..options.save.len], options.save);
        const written = sys.fileWrite(&path, report.bytes[0..report.len]);
        if (written != @as(i32, @intCast(report.len)) or report.overflow) {
            sys.println("DISPLAYD baseline save: FAILED");
            return 1;
        }
        sys.write("DISPLAYD baseline saved: ");
        sys.println(options.save);
    } else sys.write(report.bytes[0..report.len]);
    return if (ok) 0 else 1;
}

fn parse(args: []const u8) ?Options {
    var options = Options{};
    var baseline = false;
    var tokens = std.mem.tokenizeAny(u8, args, " \t");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "/BASELINE")) baseline = true else if (std.ascii.eqlIgnoreCase(token, "/TRACE")) options.trace = true else if (std.ascii.eqlIgnoreCase(token, "/PRESENT")) options.present = true else if (token.len > 9 and std.ascii.eqlIgnoreCase(token[0..9], "/SAMPLES=")) {
            options.samples = std.fmt.parseInt(u32, token[9..], 10) catch return null;
            if (options.samples == 0 or options.samples > scenes.max_samples) return null;
        } else if (token.len > 6 and std.ascii.eqlIgnoreCase(token[0..6], "/SAVE=")) {
            options.save = token[6..];
            if (options.save.len >= 256) return null;
        } else return null;
    }
    return if (baseline) options else null;
}

fn collect(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context, draw: r4os.r4draw.Context, options: Options, report: *Report) bool {
    report.line("DISPLAYD baseline schema=2", .{});
    report.line("scope=synthetic-cpu-scenes present={s} samples_per_scene={d}", .{ if (options.present) "yes" else "no", options.samples });
    report.line("timings=monotonic-wall-including-preemption percentiles=nearest-rank warmup=1 limits=64MB-per-buffer,15s-total-measurement-budget", .{});
    report.line("cpu-frequency=unavailable gpu-clock=unavailable sink-power=external-observation-required", .{});
    report.line("cpu-time=scheduler-run-ticks coarse; CPU phase wall spans are not CPU execution time", .{});
    var release: [512]u8 = undefined;
    if (options.trace) sys.println("DISPLAYD baseline phase: release-and-hardware");
    const read = sys.fileRead("C:\\R4OS\\CONFIG\\VERSION.R4S", &release);
    if (read > 0) {
        report.write("release-file:\r\n");
        report.write(release[0..@min(@as(usize, @intCast(read)), release.len)]);
        report.write("\r\n");
    }
    if (dev.kernelVersion()) |version| report.line("kernel={d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    if (dev.hardwareSummary()) |hardware| report.line("logical-cpus={d} pci-devices={d} pcie-devices={d}", .{ hardware.cpu_logical_processors, hardware.legacy_pci_devices, hardware.pcie_devices });
    if (options.trace) sys.println("DISPLAYD baseline phase: inventory-and-boot-snapshot");
    hardwareReport(dev, report);
    if (r4os.graphics_status.Snapshot.read(&dev)) |status| {
        var line: [256]u8 = undefined;
        for (0..7) |index| report.line("{s}", .{status.line(&line, index)});
    }
    const before = dev.displaySummary() orelse return false;
    report.line("display-owner={s} mode={d}x{d}x{d} pitch={d} cache-policy={d}", .{ fixed(&before.backend_name), before.width, before.height, before.bpp, before.pitch, before.cache_policy });
    var caps: abi.DisplayPresentCapabilities = .{};
    if (draw.displayPresentCapabilities(&caps) != 0) return false;
    report.line("present-backend={s} fallback={s} kind={d} caps=0x{x} max-regions={d}", .{ fixed(&caps.backend_name), fixed(&caps.fallback_name), caps.backend_kind, caps.flags, caps.max_regions });
    const software = caps.backend_kind == abi.display_present_backend_bootfb_cpu or caps.backend_kind == abi.display_present_backend_external_blit;
    const native = caps.backend_kind == abi.display_present_backend_native_cpu;
    report.line("gpu-timestamps=unavailable visible-present=unavailable scanout-completion=unavailable", .{});
    report.line("upload=unavailable-separately synchronous-submit-includes-validation-copy-and-completion-wait", .{});
    report.line("completion={s} queue-wait={s}", .{ if (software) "CPU-store-fence" else if (native) "device-execution" else "unknown", if (software) "not-applicable" else "included-in-submit-wall" });
    report.line("caller-inflight-limit=1 caller-outstanding-after-return=0 native-bridge-capacity={d} global-device-queue-depth=unavailable", .{@as(u32, if (native) 1 else 0)});
    report.line("traffic=calculated-logical-bytes; DRAM/PCIe transactions, cache-misses, RFO, scanout-reads=unavailable", .{});
    var clock_info: abi.MonotonicClockInfo = .{};
    if (sys.monotonicClock(&clock_info) <= 0 or clock_info.flags & abi.monotonic_clock_flag_valid == 0 or clock_info.frequency_hz != abi.monotonic_clock_frequency_hz) {
        report.line("clock=unavailable; baseline not measured", .{});
        return false;
    }
    report.line("clock-source={d} generation={d} resolution-ns={d} source-hz={d} event-hz={d} flags=0x{x}", .{ clock_info.source, clock_info.generation, clock_info.resolution_ns, clock_info.source_frequency_hz, clock_info.event_effective_hz, clock_info.flags });
    const clock = Clock{ .sys = &sys, .generation = clock_info.generation, .source = clock_info.source };
    const started = clock.now() orelse return false;
    const width = before.width;
    const height = before.height;
    const pixel_count = @as(u64, width) * height;
    if (width < 8 or height < 8 or pixel_count > 16 * 1024 * 1024 or (options.present and ((!software and !native) or caps.max_regions < 4 or caps.flags & abi.display_present_cap_sync_fence == 0))) {
        report.line("baseline unsupported geometry/backend; no allocations or presents", .{});
        return false;
    }
    const allocator = sys.allocator();
    if (options.trace) sys.println("DISPLAYD baseline phase: scene-buffers");
    const source = allocator.alloc(u32, @intCast(pixel_count)) catch return false;
    defer allocator.free(source);
    const output = allocator.alloc(u32, @intCast(pixel_count)) catch return false;
    defer allocator.free(output);
    @memset(source, 0);
    @memset(output, 0);
    if (options.trace) sys.println("DISPLAYD baseline phase: performance-summary");
    const perf = dev.performanceSummary();
    const task_index: ?u32 = if (perf) |p| p.current_task_index else null;
    var measured_bytes: u64 = 0;
    var measured_frames: u64 = 0;
    for (std.meta.tags(scenes.Scene)) |scene| {
        if (options.trace) {
            sys.write("DISPLAYD baseline phase: ");
            sys.println(@tagName(scene));
        }
        if (!measureScene(sys, dev, draw, clock, options, report, task_index, scene, source, output, width, height, (before.bpp + 7) / 8, started, &measured_bytes, &measured_frames)) return false;
    }
    const elapsed = clock.elapsed(started) orelse return false;
    const after = dev.displaySummary() orelse return false;
    if (before.backend_kind != after.backend_kind or !std.mem.eql(u8, &before.backend_name, &after.backend_name) or
        before.width != after.width or before.height != after.height or before.pitch != after.pitch)
    {
        report.line("measurement-invalid=backend-or-mode-changed", .{});
        return false;
    }
    report.line("duration-ns={d} successful-measured-presents={d} returned-pixels-times-bpp={d}", .{ elapsed, measured_frames, measured_bytes });
    report.line("global-present-delta={d} global-byte-delta={d} scope=includes-other-producers-and-warmup", .{ after.present_count -| before.present_count, after.present_bytes_total -| before.present_bytes_total });
    report.line("resources=two-bounded-buffers-freed-on-every-return output-I/O=outside-measured-spans", .{});
    return true;
}

fn measureScene(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context, draw: r4os.r4draw.Context, clock: Clock, options: Options, report: *Report, task_index: ?u32, scene: scenes.Scene, source: []u32, output: []u32, width: u32, height: u32, destination_bytes_per_pixel: u16, started: u64, measured_bytes: *u64, measured_frames: *u64) bool {
    var render = scenes.Samples{};
    var composition = scenes.Samples{};
    var submit = scenes.Samples{};
    var rejected: u32 = 0;
    var fallback: u32 = 0;
    var render_bytes: u64 = 0;
    var composition_bytes: u64 = 0;
    var logical_fb_bytes: u64 = 0;
    var checksum: u32 = 0;
    const task_before = if (task_index) |index| dev.performanceTask(index) else null;
    // Frame zero warms the exact same RAM/submit path but is not a sample.
    var frame: u32 = 0;
    while (frame <= options.samples) : (frame += 1) {
        if (sys.programShouldClose() or (clock.elapsed(started) orelse return false) >= 15_000_000_000) {
            report.line("scene={s} interrupted=close-or-budget", .{@tagName(scene)});
            return false;
        }
        if (scene == .idle) {
            sys.sleepTicks(sys.ticksFromMilliseconds(5));
            continue;
        }
        const r0 = clock.now() orelse return false;
        var work = scenes.render(scene, source, width, height, frame);
        std.mem.doNotOptimizeAway(source.ptr);
        const rt = clock.elapsed(r0) orelse return false;
        const c0 = clock.now() orelse return false;
        scenes.compose(scene, source, output, width, &work);
        std.mem.doNotOptimizeAway(output.ptr);
        const ct = clock.elapsed(c0) orelse return false;
        // Consume changing output outside timed spans even without PRESENT.
        const r = work.rects[work.count - 1];
        checksum +%= output[@as(usize, r.y + r.h - 1) * width + r.x + r.w - 1];
        if (frame != 0) {
            render.add(rt);
            composition.add(ct);
            render_bytes += work.render_reads + work.render_writes;
            composition_bytes += work.composition_reads + work.composition_writes;
        }
        if (!options.present) continue;
        var damage: [8]abi.DisplayDamageRect = undefined;
        for (work.rects[0..work.count], 0..) |rect, i| damage[i] = .{ .x = @intCast(rect.x), .y = @intCast(rect.y), .w = rect.w, .h = rect.h };
        const request = abi.DisplayPresentRequest{ .source_width = width, .source_height = height, .source_stride_pixels = width, .source_generation = 0xD179_0000 + @as(u64, @intFromEnum(scene)) * 256 + frame };
        var result: abi.DisplayPresentResult = .{};
        const s0 = clock.now() orelse return false;
        const rc = draw.displayPresentRegions(&request, output, damage[0..work.count], &result);
        const st = clock.elapsed(s0) orelse return false;
        if (rc != 0) {
            // No retries hide nonblocking admission failures or distort latency.
            if (frame != 0) rejected += 1;
            continue;
        }
        if (result.flags & abi.display_present_result_completed == 0 or result.fence == 0 or result.fence != result.completed_fence or result.pixel_count != work.pixels()) return false;
        if (frame != 0) {
            submit.add(st);
            measured_frames.* += 1;
            const bytes = result.pixel_count * destination_bytes_per_pixel;
            measured_bytes.* += bytes;
            logical_fb_bytes += bytes;
            if (result.flags & abi.display_present_result_fallback != 0) fallback += 1;
        }
    }
    const task_after = if (task_index) |index| dev.performanceTask(index) else null;
    report.line("scene={s} checksum=0x{x} submit-rejected={d} fallback-frames={d}", .{ @tagName(scene), checksum, rejected, fallback });
    if (scene == .producers) report.line("  producers=4-disjoint-regions serialized-in-one-generation; concurrent-desktop-producers=unmeasured", .{});
    if (scene == .idle) report.line("  idle=caller-does-no-render-or-present; other-desktop-work-may-continue", .{});
    report.times("cpu-render", render);
    report.times("cpu-composition", composition);
    report.times("synchronous-submit", submit);
    report.line("  modeled-render-RAM-bytes={d} modeled-composition-RAM-bytes={d} returned-framebuffer-bytes={d}", .{ render_bytes, composition_bytes, logical_fb_bytes });
    if (submit.total > 0) report.line("  effective-logical-framebuffer-bytes-per-second={d} scope=successful-submit-wall-spans", .{@as(u64, @intCast(@as(u128, logical_fb_bytes) * 1_000_000_000 / submit.total))});
    if (task_before) |a| {
        if (task_after) |b| {
            if (a.id == b.id and b.run_ticks >= a.run_ticks) report.line("  scheduler-run-ticks={d} includes-warmup-and-instrumentation", .{b.run_ticks - a.run_ticks});
        }
    } else report.line("  scheduler-run-ticks=unavailable", .{});
    // The ordinary bootfb CPU path is itself marked as fallback. Its bytes
    // remain valid samples; rejected submissions never count as a full run.
    return !options.present or scene == .idle or (submit.count == options.samples and rejected == 0);
}

fn hardwareReport(dev: r4os.r4dev.Context, report: *Report) void {
    var inventory: abi.DeviceInventorySummary = .{};
    if (dev.deviceInventorySummary(&inventory) > 0) {
        var index: u32 = 0;
        while (index < @min(inventory.total, 128)) : (index += 1) {
            var record: abi.DeviceInventoryRecord = .{};
            if (dev.deviceInventoryRecord(index, &record) <= 0) break;
            // Class codes are bus-specific: USB HID class 3 is not PCI display.
            if (record.flags & 1 != 0 and record.class_code == 3 and record.vendor_id != 0) report.line("pci-display={x:0>2}:{x:0>2}.{d} id={x:0>4}:{x:0>4} driver={s} status={s}", .{ record.bus_no, record.device_no, record.function_no, record.vendor_id, record.device_id, fixed(&record.driver), fixed(&record.status) });
        }
    }
    report.line("subsystem-id=unavailable pci-revision=unavailable chip-id=unavailable vbios=unavailable BAR-sizes=unavailable irq-capabilities=unavailable", .{});
    report.line("reason=not-cached-by-R4DEV; no-foreign-PCI-config-or-GPU-register-access; owner-probe-required", .{});
    if (dev.bootInfoSummary()) |boot| {
        report.line("bootloader={s} framebuffer=0x{x} EDID-address=0x{x} EDID-bytes={d} EDID-source=boot-snapshot-not-live-DDC", .{ fixed(&boot.bootloader_name), boot.framebuffer_address, boot.edid_address, boot.edid_size });
        if (boot.edid_address != 0 and boot.edid_size >= 128 and boot.edid_size <= 32768) {
            const base: *const [128]u8 = @ptrFromInt(boot.edid_address);
            var sum: u8 = 0;
            for (base) |byte| sum +%= byte;
            report.line("EDID-base-checksum={s} extensions-advertised={d} live-connector-state=unavailable", .{ if (sum == 0) "OK" else "INVALID", base[126] });
            for (0..8) |row| report.line("EDID-{d:0>3}={x}", .{ row * 16, base[row * 16 ..][0..16] });
        }
    }
}

fn fixed(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}
