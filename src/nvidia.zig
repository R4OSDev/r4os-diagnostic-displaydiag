const std = @import("std");
const r4os = @import("r4os");

// Replays the driver's bounded boot records. This diagnostic never performs
// a second PCI scan, maps registers or promotes a PCI name into chip evidence.
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    var chunk: [2048]u8 = undefined;
    var line: [600]u8 = undefined;
    var used: usize = 0;
    var offset: u32 = 0;
    var found = false;
    var truncated = false;
    while (offset < 65536) {
        const count = sys.bootLogRead(offset, &chunk);
        if (count <= 0) break;
        for (chunk[0..@intCast(count)]) |byte| {
            if (byte == '\n') {
                if (!truncated and std.mem.indexOf(u8, line[0..used], "NVIDIA ") != null) {
                    sys.println(std.mem.trimEnd(u8, line[0..used], "\r"));
                    found = true;
                }
                used = 0;
                truncated = false;
            } else if (used < line.len) {
                line[used] = byte;
                used += 1;
            } else truncated = true;
        }
        offset += @intCast(count);
    }
    if (!found) {
        sys.println("DISPLAYD nvidia: unavailable (no complete driver records in boot log)");
        return 1;
    }
    sys.println("DISPLAYD nvidia: records=available source=boot-log hardware-acceptance=separate");
    return 0;
}
