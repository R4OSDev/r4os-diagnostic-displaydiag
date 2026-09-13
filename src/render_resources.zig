//! Small DEVICE_V1 consumer within the existing /BUFFERS diagnostic.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");

pub fn run(app: *r4os.App) bool {
    const client = gfx.DeviceV1Client.init(app.startContext()) catch return false;
    const sys = app.system();
    const allocator = sys.allocator();
    const bytes = client.storage_size();
    if (bytes == 0 or bytes > std.math.maxInt(usize)) return false;
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(bytes)) catch return false;
    @memset(storage, 0);
    var device: gfx.R4GfxDevice = undefined;
    if (client.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
        .storage_bytes = storage.len, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0, .flags = 0 }, &device) != gfx.status_ok)
    { allocator.free(storage); return false; }
    const passed = exercise(&sys, &client, &device);
    const closed = client.device_close(&device) == gfx.status_ok;
    if (closed) allocator.free(storage); // A retained receipt must outlive a failed close.
    return passed and closed;
}
fn description(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1; value.size = @sizeOf(gfx.R4GfxResourceDesc); value.kind = kind;
    return value;
}
fn exercise(sys: *const r4os.r4sys.Context, client: *const gfx.DeviceV1Client, device: *const gfx.R4GfxDevice) bool {
    var source: gfx.R4GfxResource = undefined;
    var target: gfx.R4GfxResource = undefined;
    var readback: gfx.R4GfxResource = undefined;
    var fill: gfx.R4GfxResource = undefined;
    var blit: gfx.R4GfxResource = undefined;
    var sampler: gfx.R4GfxResource = undefined;
    var image = description(gfx.resource_image);
    image.flags = gfx.image_target;
    image.image = .{ .cpu_address = 0, .byte_length = 64, .pitch = 16, .width = 4, .height = 4, .format = gfx.format_xrgb8888, .reserved = 0 };
    if (client.resource_create(device, &image, &source) != gfx.status_ok or client.resource_create(device, &image, &target) != gfx.status_ok) return false;
    var pixels: [16]u32 = @splat(0);
    image.source_kind = gfx.source_borrow_cpu; image.source_generation = 1; image.image.cpu_address = @intFromPtr(&pixels);
    if (client.resource_create(device, &image, &readback) != gfx.status_ok) return false;
    var pipeline = description(gfx.resource_pipeline); pipeline.operation = gfx.render_operation_fill;
    if (client.resource_create(device, &pipeline, &fill) != gfx.status_ok) return false;
    pipeline.operation = gfx.render_operation_blit;
    if (client.resource_create(device, &pipeline, &blit) != gfx.status_ok) return false;
    const nearest = description(gfx.resource_sampler);
    if (client.resource_create(device, &nearest, &sampler) != gfx.status_ok) return false;
    var command = std.mem.zeroes(gfx.R4GfxDraw);
    command.target = source; command.pipeline = fill; command.color = 0x2468ac;
    command.target_rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
    const batch: gfx.R4GfxRenderBatch = .{ .commands = @intFromPtr(&command), .command_count = 1, .flags = 0, .pixel_budget = 16 };
    var stats: gfx.R4GfxRenderStats = undefined;
    if (client.render(device, &batch, &stats) != gfx.status_ok or stats.cpu.write_bytes != 64) return false;
    const deadline = (sys.monotonicNanoseconds() orelse return false) + 3_000_000_000;
    var job: gfx.R4GfxJob = undefined;
    if (client.copy_submit(device, &.{ .source = source, .target = target, .source_offset = 0, .target_offset = 0,
        .byte_length = 64, .deadline_ns = deadline }, &job) != gfx.status_ok) return false;
    var receipt: gfx.R4GfxJobInfo = undefined;
    while (true) {
        if (client.job_info(device, &job, &receipt) != gfx.status_ok) return false;
        if (receipt.phase == r4os.abi.gfx_queue_phase_terminal and receipt.flags == 0) break;
        if ((sys.monotonicNanoseconds() orelse return false) >= deadline) return false;
        sys.sleepTicks(1);
    }
    if (receipt.result != r4os.abi.gfx_queue_result_complete or client.job_release(device, &job) != gfx.status_ok) return false;
    command.target = readback; command.source = target; command.pipeline = blit; command.sampler = sampler;
    command.source_rect = command.target_rect; command.color = 0; command.opacity = 255;
    if (client.render(device, &batch, &stats) != gfx.status_ok) return false;
    for (pixels) |pixel| if (pixel != 0x2468ac) return false;
    var state: gfx.R4GfxDeviceInfo = undefined;
    if (client.device_info(device, &state) != gfx.status_ok or state.upload_bytes != 0 or
        state.gpu_copy_bytes != @as(u64, if (receipt.backend == gfx.render_backend_nvidia) 64 else 0)) return false;
    sys.write("DISPLAYD resources: OK DEVICE_V1 backend="); sys.printU64(state.backend);
    sys.write(" copy-bytes=64 completed=1 pixels=16 cpu-read="); sys.printU64(state.cpu_read_bytes);
    sys.write(" cpu-write="); sys.printU64(state.cpu_write_bytes); sys.println(" upload=0");
    return true;
}
