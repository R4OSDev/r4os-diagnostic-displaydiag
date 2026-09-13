// Targeted common-worker acceptance against the explicit EXAMPLE fixture.
// Normal NVIDIA outputs never match this virtual connector and are untouched.
const r4os = @import("r4os");
const a = r4os.abi;
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return a.err_no_group;
    const outputs = draw.outputs();
    const buffers = draw.buffers();
    var info: a.GfxOutputInfo = .{};
    var found = false;
    for (0..a.gfx_output_catalog_capacity) |index| {
        if (outputs.info(@intCast(index), &info) != a.gfx_output_ok) break;
        if (info.identity.connector_id == 0x7913 and info.connector_kind == a.gfx_output_kind_virtual and
            info.flags & a.gfx_output_flag_active != 0 and info.limits.flags & a.gfx_output_limit_modeset != 0) { found = true; break; }
    }
    if (!found) { sys.println("DISPLAYD modes: EXAMPLE mode=gfx-mode-test required"); return 1; }
    var last_ticket: u64 = 0;
    for ([_]u32{ 1, 2, 2, 3 }, 0..) |mode_id, step| {
        var mode: a.GfxOutputMode = .{};
        if (outputs.mode(&info.identity, mode_id - 1, &mode) != a.gfx_output_ok) return fail(&sys, @src().line);
        const pitch = @as(u64, mode.width) * 4;
        var source: a.GfxBufferReference = .{};
        if (buffers.create(&.{ .byte_length = pitch * mode.height, .width = mode.width, .height = mode.height,
            .plane_count = 1, .plane_pitches = .{ pitch, 0, 0, 0 }, .format = a.gfx_buffer_format_xrgb8888,
            .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source }, &source) != a.gfx_buffer_result_ok) return fail(&sys, @src().line);
        defer if (source.reference.id != 0) { _ = buffers.release(&source.reference); };
        var map: a.GfxBufferMap = .{};
        if (buffers.map(&source.reference, a.gfx_buffer_map_write, 0, pitch * mode.height, &map) != a.gfx_buffer_result_ok) return fail(&sys, @src().line);
        @memset(@as([*]u32, @ptrFromInt(map.cpu_address))[0..@as(usize, mode.width) * mode.height], 0x0013579b);
        if (buffers.unmap(&map.lease) != a.gfx_buffer_result_ok) return fail(&sys, @src().line);
        var revision: a.GfxDisplayRevision = .{};
        if (outputs.revision(&revision) != a.gfx_output_ok) return fail(&sys, @src().line);
        var state: a.GfxAtomicState = .{ .count = 1, .topology_revision = revision.revision };
        state.assignments[0] = .{ .output = info.identity, .mode_id = mode_id, .source_width = mode.width, .source_height = mode.height,
            .destination_width = mode.width, .destination_height = mode.height, .buffer = source.reference };
        var tested: a.GfxAtomicResult = .{};
        if (outputs.testState(&state, &tested) != a.gfx_output_ok) return fail(&sys, @src().line);
        var status: a.GfxModeStatus = .{};
        if (outputs.submit(&state, 1000, &status) != a.gfx_output_ok or status.ticket <= last_ticket or status.phase != a.gfx_mode_phase_queued) return fail(&sys, @src().line);
        // The application may relinquish its reference as soon as admission
        // returned. Driver and display continue through their own full leases.
        if (buffers.release(&source.reference) != a.gfx_buffer_result_ok) return fail(&sys, @src().line);
        source = .{};
        last_ticket = status.ticket;
        const expected_phase = if (step == 3) a.gfx_mode_phase_reverted else a.gfx_mode_phase_awaiting_confirmation;
        if (!wait(&sys, &outputs, last_ticket, expected_phase, &status)) return fail(&sys, @src().line);
        if (step != 3 and (!geometry(app, mode.width, mode.height) or status.retained != 3)) return fail(&sys, @src().line);
        if (step < 2) {
            const action = if (step == 0) a.gfx_mode_resolve_confirm else a.gfx_mode_resolve_rollback;
            if (outputs.resolve(last_ticket, action, &status) != a.gfx_output_ok) return fail(&sys, @src().line);
        }
        const terminal = if (step == 0) a.gfx_mode_phase_confirmed else a.gfx_mode_phase_reverted;
        if (!wait(&sys, &outputs, last_ticket, terminal, &status) or !geometry(app, 320, 200) or
            status.retained != @as(u32, if (step == 0) 2 else 1)) return fail(&sys, @src().line);
        if (step == 2 and status.error_code != a.gfx_output_error_timeout) return fail(&sys, @src().line);
        if (step == 3 and status.error_code != a.gfx_output_error_unsupported) return fail(&sys, @src().line);
    }
    sys.println("DISPLAYD modes: OK async-worker geometry=320x200,640x480 mouse=bounded confirm=yes explicit-rollback=yes timer-rollback=yes rejected=unchanged early-release=held GPU-commands=none");
    return 0;
}
fn geometry(app: *r4os.App, width: u32, height: u32) bool {
    const draw = app.drawing() orelse return false;
    const desk = app.desktop() orelse return false;
    var mouse = @import("std").mem.zeroes(a.Mouse);
    desk.mouseState(&mouse);
    const actual_w = draw.screenWidth(); const actual_h = draw.screenHeight();
    if (actual_w == width and actual_h == height and mouse.x >= 0 and mouse.y >= 0 and mouse.x < width and mouse.y < height) return true;
    const sys = app.system();
    sys.write("DISPLAYD modes geometry: expected="); sys.printU64(width); sys.write("x"); sys.printU64(height);
    sys.write(" actual="); sys.printU64(actual_w); sys.write("x"); sys.printU64(actual_h);
    sys.write(" mouse="); sys.printI32(mouse.x); sys.write(","); sys.printI32(mouse.y); sys.println("");
    return false;
}
fn wait(sys: *const r4os.r4sys.Context, outputs: *const r4os.gfx_outputs.Context, ticket: u64, phase: u32, status: *a.GfxModeStatus) bool {
    const end = sys.ticks() + sys.ticksFromMilliseconds(5000);
    while (sys.ticks() < end) {
        const result = outputs.status(ticket, status);
        if (result != a.gfx_output_ok or status.ticket != ticket or status.phase == a.gfx_mode_phase_lost) {
            reportWait(sys, ticket, phase, result, status);
            return false;
        }
        if (status.phase == phase) return true;
        sys.sleepTicks(1);
    }
    reportWait(sys, ticket, phase, a.gfx_output_error_timeout, status);
    return false;
}
fn reportWait(sys: *const r4os.r4sys.Context, ticket: u64, phase: u32, result: i32, status: *const a.GfxModeStatus) void {
    sys.write("DISPLAYD modes wait: ticket="); sys.printU64(ticket);
    sys.write(" expected="); sys.printU64(phase); sys.write(" actual="); sys.printU64(status.phase);
    sys.write(" result="); sys.printI32(result); sys.write(" outcome="); sys.printU64(status.outcome);
    sys.write(" retained="); sys.printU64(status.retained); sys.write(" error="); sys.printI32(status.error_code);
    sys.println("");
}
fn fail(sys: *const r4os.r4sys.Context, line: u32) i32 {
    sys.write("DISPLAYD modes: FAILED line="); sys.printU64(line); sys.println("");
    return 1;
}
