const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx_outputs");
const producer = @import("r4gfx_queue");
const a = r4os.abi;
const ok = a.gfx_output_ok;
const test_adapter: u32 = 0xffff0007;
var receiver: gfx.edid.Report = .{};
var raw: [a.gfx_output_max_edid_bytes]u8 = undefined;
fn check(sys: *const r4os.r4sys.Context, condition: bool, line: u32) bool {
    if (condition) return true;
    sys.write("DISPLAYD outputs FAILED line="); sys.printU64(line); sys.println("");
    return false;
}
fn find(ctx: *const r4os.gfx_outputs.Context, adapter: u32) ?a.GfxOutputInfo {
    for (0..a.gfx_output_catalog_capacity) |index| {
        var info: a.GfxOutputInfo = .{};
        if (ctx.info(@intCast(index), &info) == ok and info.identity.adapter_id == adapter) return info;
    }
    return null;
}
pub fn inventory(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return a.err_no_group;
    const ctx = draw.outputs();
    var before: a.GfxDisplayRevision = .{};
    if (ctx.revision(&before) != ok or before.present > a.gfx_output_catalog_capacity) return 1;
    sys.write("DISPLAYD receivers: revision="); sys.printU64(before.revision);
    sys.write(" count="); sys.printU64(before.present); sys.println("");
    for (0..before.present) |index| {
        var info: a.GfxOutputInfo = .{};
        if (ctx.info(@intCast(index), &info) != ok or info.topology_revision != before.revision) return catalogChanged(&sys);
        sys.write("  adapter="); sys.printU64(info.identity.adapter_id);
        sys.write(" port="); sys.printU64(info.identity.connector_id);
        sys.write(" device-generation="); sys.printU64(info.identity.device_generation);
        sys.write(" receiver-generation="); sys.printU64(info.identity.connection_generation);
        sys.write(" kind="); sys.write(switch (info.connector_kind) {
            a.gfx_output_kind_hdmi => "HDMI", a.gfx_output_kind_displayport => "DisplayPort",
            a.gfx_output_kind_edp => "eDP", a.gfx_output_kind_dvi => "DVI",
            a.gfx_output_kind_virtual => "virtual", a.gfx_output_kind_firmware => "firmware", else => "unknown",
        });
        sys.write(" flags="); sys.printU64(info.flags);
        sys.write(" source="); sys.write(if (info.flags & a.gfx_output_flag_receiver_only != 0) "receiver-only" else if (info.flags & a.gfx_output_flag_firmware_snapshot != 0) "firmware-snapshot" else "driver");
        sys.write(" modes="); sys.printU64(info.mode_count);
        sys.write(" edid-bytes="); sys.printU64(info.edid_bytes); sys.println("");
        var power: a.GfxOutputPower = .{};
        const power_rc = ctx.power(&info.identity, &power);
        if (power_rc == a.gfx_output_error_stale) return catalogChanged(&sys);
        if (power_rc == ok) {
            sys.write("    screen-power="); sys.write(switch (power.phase) {
                a.gfx_power_phase_on => "on", a.gfx_power_phase_stopping => "stopping",
                a.gfx_power_phase_off => "off", a.gfx_power_phase_waking => "waking", else => "unavailable",
            });
            sys.write(" capabilities="); sys.printU64(power.capabilities);
            sys.write(" sequence="); sys.printU64(power.sequence);
            sys.write(" request="); sys.printU64(power.request_sequence);
            sys.write(" reason="); sys.printU64(power.reason);
            sys.write(" control="); sys.printU64(power.control_receipt);
            sys.write(" core="); sys.printU64(power.core_point);
            sys.write(" window="); sys.printU64(power.window_point); sys.println("");
        } else if (power_rc == a.gfx_output_error_unsupported or power_rc == a.err_no_fn or power_rc == a.err_no_group)
            sys.println("    screen-power=unsupported")
        else return catalogChanged(&sys);
        var color: a.GfxOutputColorState = .{};
        const color_rc = ctx.color(&info.identity, &color);
        if (color_rc == a.gfx_output_error_stale) return catalogChanged(&sys);
        if (color_rc == ok) {
            if (color.revision != before.revision) return catalogChanged(&sys);
            sys.write("    source-color flags="); sys.printU64(color.flags);
            sys.write(" bpc="); sys.printU64(color.bpc);
            sys.write(" primaries="); sys.printU64(color.primaries);
            sys.write(" transfer="); sys.printU64(color.transfer);
            sys.write(" range="); sys.printU64(color.range);
            sys.write(" gamma-lut="); sys.printU64(color.gamma_entries);
            sys.write(" degamma-lut="); sys.printU64(color.degamma_entries);
            sys.write(" matrix-bits="); sys.printU64(color.ctm_fraction_bits);
            sys.write(" hdr-transfers="); sys.printU64(color.transfers & 12); sys.println("");
            if (color.size >= 192) {
                sys.write("    active-link="); sys.write(switch (color.link_kind) {
                    a.gfx_output_link_tmds => "TMDS", a.gfx_output_link_frl => "FRL",
                    a.gfx_output_link_dp_sst => "DP-SST", a.gfx_output_link_dp_mst => "DP-MST", else => "unknown",
                });
                sys.write(" lanes="); sys.printU64(color.link_lanes);
                sys.write(" lane-Mbit/s="); sys.printU64(color.link_rate_mbps);
                sys.write(" payload-bit/s="); sys.printU64(color.link_payload_bits_per_second);
                sys.write(" FEC="); sys.printU64(@intFromBool(color.link_flags & a.gfx_output_link_fec != 0));
                sys.write(" DSC-bpp-x16="); sys.printU64(color.compressed_bpp_x16); sys.println("");
                sys.write("    candidate-caps DSC-depths="); sys.printU64(color.dsc_depths);
                sys.write(" max-FRL-rate="); sys.printU64(color.max_frl_rate); sys.println(" (mode admission required)");
            }
        } else sys.println("    source-color unavailable");
        for (0..8) |head| {
            var target: a.GfxOutputTarget = .{};
            if (draw.displayOutputTarget(info.identity.adapter_id, @intCast(head), &target) != ok or
                target.connector_id != info.identity.connector_id or target.connection_generation != info.identity.connection_generation) continue;
            var refresh: a.GfxOutputRefresh = .{};
            if (draw.gfxOutputRefresh(&target, &refresh) != ok) { sys.println("    VRR status unavailable; fixed fallback"); continue; }
            const cap = refresh.capabilities; const state = refresh.status; const measured = refresh.measured;
            sys.write("    VRR capability flags="); sys.printU64(cap.flags);
            sys.write(" origin="); sys.printU64(cap.origin);
            sys.write(" min-mHz="); sys.printU64(cap.min_millihz);
            sys.write(" max-mHz="); sys.printU64(cap.max_millihz);
            sys.write(" nominal-mHz="); sys.printU64(cap.nominal_millihz); sys.println("");
            sys.write("    VRR state=");
            sys.write(if (state.phase <= 4) @tagName(@as(gfx.edid.vrr.State, @enumFromInt(state.phase))) else "lost");
            sys.write(" reason="); sys.write(if (state.reason <= 13) @tagName(@as(gfx.edid.vrr.Reason, @enumFromInt(state.reason))) else "unknown");
            sys.write(" policy="); sys.printU64(state.policy);
            sys.write(" request="); sys.printU64(state.request_sequence);
            sys.write(" core="); sys.printU64(state.core_point); sys.write(" receipt="); sys.printU64(state.receipt); sys.println("");
            sys.write("    observed refresh samples="); sys.printU64(measured.samples);
            sys.write(" gaps="); sys.printU64(measured.gaps);
            sys.write(" at-ns="); sys.printU64(measured.observed_ns);
            if (measured.samples != 0) {
                sys.write(" mean-mHz="); sys.printU64(measured.millihz);
                sys.write(" last/min/max-ns="); sys.printU64(measured.last_period_ns); sys.putc('/');
                sys.printU64(measured.min_period_ns); sys.putc('/'); sys.printU64(measured.max_period_ns);
            } else sys.write(" measured-rate=unknown");
            sys.println("");
        }
        if (info.edid_bytes == 0) { sys.println("    EDID unavailable; receiver power state unknown"); continue; }
        gfx.readReceiver(&ctx, &info, &raw, &receiver) catch |err| {
            if (err == error.Stale) return catalogChanged(&sys);
            sys.write("    EDID status="); sys.println(@errorName(err));
            continue;
        };
        sys.write("    EDID vendor="); sys.write(&receiver.manufacturer);
        sys.write(" name="); sys.write(std.mem.sliceTo(&receiver.name, 0));
        sys.write(" extensions="); sys.printU64(receiver.valid_extensions); sys.putc('/'); sys.printU64(receiver.declared_extensions);
        sys.write(" warnings="); sys.printU64(receiver.warnings);
        sys.write(" colors="); sys.printU64(receiver.colors);
        sys.write(" audio-formats="); sys.printU64(receiver.audio_count);
        sys.write(" basic-audio="); sys.printU64(@intFromBool(receiver.basic_audio)); sys.println("");
        sys.write("    receiver-color bpc="); sys.printU64(receiver.bits_per_color);
        sys.write(" hdmi-deep-color="); sys.printU64(receiver.hdmi_deep_color);
        sys.write(" rgb-range-selectable="); sys.printU64(@intFromBool(receiver.rgb_quantization_selectable));
        sys.write(" hdr-eotf="); sys.printU64(receiver.hdr_eotf);
        sys.write(" hdr-static="); sys.printU64(receiver.hdr_static);
        sys.write(" luminance-codes=");
        for (receiver.hdr_luminance, 0..) |value, i| { if (i != 0) sys.putc('/'); sys.printU64(value); }
        sys.println("");
    }
    var after: a.GfxDisplayRevision = .{};
    if (ctx.revision(&after) != ok or after.revision != before.revision) return catalogChanged(&sys);
    sys.println("DISPLAYD receivers: complete hardware-writes=none");
    return 0;
}
fn catalogChanged(sys: *const r4os.r4sys.Context) i32 {
    sys.println("DISPLAYD receivers: catalog changed; repeat the complete read");
    return 2;
}
pub fn run(app: *r4os.App, native: bool) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const ctx = draw.outputs();
    const buffers = draw.buffers();
    var before: a.GfxBufferStats = .{}; var after: a.GfxBufferStats = .{};
    if (buffers.stats(&before) != ok) return 1;
    var passed = firmware(app, &ctx);
    if (passed and native) passed = hotplug(app, &ctx);
    passed = buffers.stats(&after) == ok and passed;
    passed = check(&sys, @import("resource_balance.zig").buffers(&sys, before, after), @src().line) and passed;
    sys.println(if (passed) "DISPLAYD outputs result: OK resources=balanced hardware-writes=none" else "DISPLAYD outputs result: FAILED");
    return if (passed) 0 else 1;
}
fn firmware(app: *r4os.App, ctx: *const r4os.gfx_outputs.Context) bool {
    const sys = app.system();
    const dev = app.devicesLowLevel() orelse return false;
    const draw = app.drawing() orelse return false;
    const info = find(ctx, 0) orelse return check(&sys, false, @src().line);
    var mode: a.GfxOutputMode = .{};
    if (!check(&sys, info.mode_count == 1 and info.connector_kind == a.gfx_output_kind_firmware and
        info.limits.flags == 0 and info.limits.rotations == 1 and ctx.mode(&info.identity, 0, &mode) == ok and
        mode.width == draw.screenWidth() and mode.height == draw.screenHeight() and mode.pixel_clock_hz == 0 and mode.refresh_millihz == 0, @src().line)) return false;
    var absent: a.GfxEdidBlock = .{ .block_index = 55 };
    const sentinel = absent;
    if (!check(&sys, ctx.edid(&info.identity, info.edid_bytes / 128, &absent) == 0 and std.meta.eql(sentinel, absent), @src().line)) return false;
    if (info.edid_bytes > 0) {
        gfx.readReceiver(ctx, &info, &raw, &receiver) catch return check(&sys, false, @src().line);
        sys.write("DISPLAYD outputs EDID: OK bytes="); sys.printU64(info.edid_bytes);
        sys.write(" extensions="); sys.printU64(receiver.valid_extensions); sys.putc('/'); sys.printU64(receiver.declared_extensions);
        sys.write(" warnings="); sys.printU64(receiver.warnings); sys.println(" source=firmware-snapshot");
    } else sys.println("DISPLAYD outputs EDID: unavailable source=firmware-snapshot");
    var state = a.GfxAtomicState{ .topology_revision = info.topology_revision, .count = 1 };
    state.assignments[0] = .{ .output = info.identity, .mode_id = mode.mode_id,
        .source_width = mode.width, .source_height = mode.height, .destination_width = mode.width, .destination_height = mode.height };
    var result: a.GfxAtomicResult = .{};
    if (!check(&sys, ctx.testState(&state, &result) == ok and result.outcome == a.gfx_output_outcome_validated, @src().line)) return false;
    const old = dev.displayState() orelse return false;
    const accepted = state;
    const untouched = result;
    state.assignments[0].plane_id = 32;
    if (!check(&sys, ctx.commit(&state, &result) == a.gfx_output_error_routing and std.meta.eql(untouched, result), @src().line)) return false;
    state = accepted; state.assignments[0].destination_width += 1;
    if (!check(&sys, ctx.testState(&state, &result) == a.gfx_output_error_invalid and std.meta.eql(untouched, result), @src().line)) return false;
    state = accepted; state.topology_revision -|= 1;
    if (!check(&sys, ctx.commit(&state, &result) == a.gfx_output_error_stale and std.meta.eql(untouched, result), @src().line)) return false;
    state = accepted; state.assignments[0].ready_fence = .{ .slot = 0xffff_ffff, .timeline = 3, .point = 7 };
    if (!check(&sys, ctx.testState(&state, &result) == a.gfx_output_error_invalid and std.meta.eql(untouched, result), @src().line)) return false;
    // An actual valid BO is still not a legal replacement for Limine scanout.
    const buffers = draw.buffers();
    var reference: a.GfxBufferReference = .{};
    var descriptor = a.GfxBufferDescriptor{ .byte_length = 4096, .width = 8, .height = 8, .format = a.gfx_buffer_format_xrgb8888,
        .plane_count = 1, .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_cpu_write };
    descriptor.plane_pitches[0] = 32;
    if (!check(&sys, buffers.create(&descriptor, &reference) == ok, @src().line)) return false;
    defer _ = buffers.release(&reference.reference);
    state = accepted; state.assignments[0].buffer = reference.reference;
    if (!check(&sys, ctx.commit(&state, &result) == a.gfx_output_error_unsupported and std.meta.eql(untouched, result), @src().line)) return false;
    const after = dev.displayState() orelse return false;
    if (!check(&sys, std.meta.eql(old, after), @src().line)) return false;
    state = accepted;
    if (!check(&sys, ctx.commit(&state, &result) == ok and result.outcome == a.gfx_output_outcome_applied and
        result.commit_sequence == untouched.commit_sequence + 1 and result.topology_revision > accepted.topology_revision and result.retained == 0, @src().line)) return false;
    if (!check(&sys, ctx.testState(&accepted, &result) == a.gfx_output_error_stale, @src().line)) return false;
    sys.println("DISPLAYD outputs atomic: OK rejected-before-device-change old-output=preserved boot-retain=applied refresh=unknown");
    return true;
}
fn barrier(sys: *const r4os.r4sys.Context, queue: *producer.Queue, result: *a.GfxFenceStatus) bool {
    if (queue.barrier((sys.monotonicNanoseconds() orelse 0) + 5_000_000_000, 0, &.{}, result) != a.gfx_queue_ok) return false;
    return true;
}
fn finish(sys: *const r4os.r4sys.Context, queue: *producer.Queue, result: *a.GfxFenceStatus, expected: u32) bool {
    const fence = result.fence;
    defer _ = queue.context.release(&fence);
    return queue.context.wait(&fence, sys.ticksFromMilliseconds(3000), a.gfx_queue_wait_resources_released, result) == a.gfx_queue_ok and result.result == expected;
}
fn hotplug(app: *r4os.App, ctx: *const r4os.gfx_outputs.Context) bool {
    const sys = app.system();
    const draw = app.drawing() orelse return false;
    const desk = app.desktop() orelse return false;
    const before = find(ctx, test_adapter) orelse return check(&sys, false, @src().line);
    if (!check(&sys, before.connector_kind == a.gfx_output_kind_virtual and before.edid_bytes == 256 and before.limits.flags == 0, @src().line)) return false;
    gfx.readReceiver(ctx, &before, &raw, &receiver) catch return check(&sys, false, @src().line);
    if (!check(&sys, receiver.complete(), @src().line)) return false;
    const queues = draw.queues();
    var binding: a.GfxBackendBinding = .{};
    for (0..a.gfx_queue_backend_capacity) |index| {
        if (queues.backend(@intCast(index), &binding) == a.gfx_queue_ok and binding.adapter_id == test_adapter) break;
    }
    if (!check(&sys, binding.adapter_id == test_adapter, @src().line)) return false;
    var queue = producer.Queue{ .context = queues };
    if (!check(&sys, queue.open(.{ .adapter_id = binding.adapter_id, .device_generation = binding.device_generation, .reset_generation = binding.reset_generation, .milestone = binding.milestone }) == a.gfx_queue_ok, @src().line)) return false;
    defer _ = queue.close();
    var sequence: u64 = 0;
    _ = desk.desktopActivityWait(0, 0, &sequence);
    const last = sequence;
    var result: a.GfxFenceStatus = .{};
    if (!check(&sys, barrier(&sys, &queue, &result), @src().line)) return false;
    if (!check(&sys, desk.desktopActivityWait(last, sys.ticksFromMilliseconds(1500), &sequence) == 1 and sequence != last, @src().line)) return false;
    if (!check(&sys, finish(&sys, &queue, &result, a.gfx_queue_result_complete), @src().line)) return false;
    const disconnected = find(ctx, test_adapter) orelse return false;
    if (!check(&sys, disconnected.identity.connector_id == before.identity.connector_id and disconnected.identity.connection_generation > before.identity.connection_generation and
        disconnected.flags & a.gfx_output_flag_connected == 0 and disconnected.mode_count == 0 and disconnected.edid_bytes == 0, @src().line)) return false;
    var stale: a.GfxOutputMode = .{ .width = 79 };
    if (!check(&sys, ctx.mode(&before.identity, 0, &stale) == a.gfx_output_error_stale and stale.width == 79, @src().line)) return false;
    if (!check(&sys, barrier(&sys, &queue, &result) and finish(&sys, &queue, &result, a.gfx_queue_result_complete), @src().line)) return false;
    const changed = find(ctx, test_adapter) orelse return false;
    if (!check(&sys, changed.identity.connection_generation > disconnected.identity.connection_generation and changed.edid_bytes == 128 and changed.mode_count > 0, @src().line)) return false;
    gfx.readReceiver(ctx, &changed, &raw, &receiver) catch return check(&sys, false, @src().line);
    if (!check(&sys, !receiver.complete() and receiver.warnings & gfx.edid.Warning.missing != 0 and receiver.audio_count == 0, @src().line)) return false;
    if (!check(&sys, ctx.mode(&disconnected.identity, 0, &stale) == a.gfx_output_error_stale, @src().line)) return false;
    if (!check(&sys, barrier(&sys, &queue, &result) and finish(&sys, &queue, &result, a.gfx_queue_result_device_lost), @src().line)) return false;
    const deadline = sys.ticks() + sys.ticksFromMilliseconds(1000);
    var reset = find(ctx, test_adapter) orelse return false;
    while (reset.edid_bytes == 0 and sys.ticks() < deadline) {
        sys.sleepTicks(1);
        reset = find(ctx, test_adapter) orelse return false;
    }
    if (!check(&sys, reset.identity.connection_generation > changed.identity.connection_generation and reset.edid_bytes == 256 and
        ctx.mode(&changed.identity, 0, &stale) == a.gfx_output_error_stale, @src().line)) return false;
    sys.println("DISPLAYD outputs hotplug: OK desktop-wait=woken disconnect=empty replug=new-generation reset=invalidated stale=untouched");
    return true;
}
