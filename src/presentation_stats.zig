//! Read-only, coherent native metadata. CPU copy fences keep their own API.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;

pub fn run(app: *r4os.App, args: []const u8) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return a.err_no_group;
    const tail = std.mem.trim(u8, args[6..], " \t");
    const head: u32 = if (tail.len == 0) 0 else std.fmt.parseInt(u32, tail, 10) catch {
        sys.println("DISPLAYD /STATS [head-id]"); return a.gfx_output_error_invalid;
    };
    if (!draw.supportsDisplayPresentationStats()) {
        sys.println("DISPLAYD presentation: unavailable (R4DRAW slot required)"); return a.err_no_fn;
    }
    var value: a.DisplayPresentationStats = .{};
    const status = draw.displayPresentationStats(head, &value);
    if (status == a.gfx_output_error_unsupported) {
        sys.write("DISPLAYD presentation: unavailable head="); sys.printU64(head);
        sys.println(" (no native visible receipt; CPU fences unchanged)"); return 0;
    }
    if (status != a.gfx_output_ok or value.version != 1 or value.size < @sizeOf(a.DisplayPresentationStats) or value.head_id != head) {
        sys.write("DISPLAYD presentation: FAILED status="); sys.printI32(status); sys.println(""); return 1;
    }
    sys.write("DISPLAYD presentation: OK head="); sys.printU64(value.head_id);
    sys.write(" adapter="); sys.printU64(value.backend.adapter_id);
    sys.write(" generation="); sys.printU64(value.display_generation);
    sys.write(" device="); sys.printU64(value.backend.device_generation);
    sys.write(" reset="); sys.printU64(value.backend.reset_generation);
    sys.write(" lost="); sys.printU64(@intFromBool(value.flags & a.display_presentation_flag_lost != 0));
    sys.write(" sequence="); sys.printU64(value.sequence); sys.println("");
    sys.write("  buffers="); sys.printU64(value.buffer_count); sys.write(" pending="); sys.printU64(value.pending);
    sys.write(" acquired="); sys.printU64(value.acquired_count); sys.write(" rendered="); sys.printU64(value.rendered_count);
    sys.write(" submitted="); sys.printU64(value.submitted_count); sys.write(" visible="); sys.printU64(value.visible_count);
    sys.write(" released="); sys.printU64(value.released_count); sys.write(" rejected="); sys.printU64(value.rejected_count); sys.println("");
    if (value.visible_count == 0) {
        sys.println("  visible-receipt=none"); return 0;
    }
    sys.write("  visible-sequence="); sys.printU64(value.visible_sequence);
    sys.write(" source-queue="); sys.printU64(value.source_timeline); sys.write(":"); sys.printU64(value.source_point);
    sys.write(" render-point="); sys.printU64(value.render_point); sys.write(" window-point="); sys.printU64(value.window_point); sys.println("");
    sys.write("  CPU-ns submitted="); sys.printU64(value.submitted_ns); sys.write(" visible-observed="); sys.printU64(value.visible_ns);
    sys.write(" old-image-released="); sys.printU64(value.released_ns); sys.println("");
    sys.write("  GPU-raw timestamp="); sys.printU64(value.gpu_timestamp); sys.write(" head-IRQ sequence="); sys.printU64(value.irq_sequence);
    sys.write(" CPU-ns observed="); sys.printU64(value.irq_observed_ns); sys.println("");
    return 0;
}
