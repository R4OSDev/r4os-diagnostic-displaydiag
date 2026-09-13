//! Actual R4L/kernel/R4D transport against the explicit synthetic EXAMPLE
//! provider. Failed receipts are intentional; this does not verify GPU pixels.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const a = r4os.abi;
pub fn run(app: *r4os.App) bool {
    const sys = app.system();
    const client = gfx.DeviceV1Client.init(app.startContext()) catch return false;
    const allocator = sys.allocator();
    const size = client.storage_size();
    if (size == 0 or size > std.math.maxInt(usize)) return false;
    const storage = allocator.alignedAlloc(u8, .fromByteUnits(gfx.device_storage_alignment), @intCast(size)) catch return false;
    @memset(storage, 0);
    var device: gfx.R4GfxDevice = undefined;
    if (client.device_open(&.{ .version = 1, .size = @sizeOf(gfx.R4GfxDeviceConfig), .storage_address = @intFromPtr(storage.ptr),
        .storage_bytes = storage.len, .start_context = @intFromPtr(app.startContext()), .preferred_adapter = 0xffff, .flags = 0 }, &device) != gfx.status_ok)
    { allocator.free(storage); return false; }
    const passed = exercise(&sys, &client, &device);
    const closed = client.device_close(&device) == gfx.status_ok;
    if (closed) allocator.free(storage);
    sys.println(if (passed and closed) "DISPLAYD native-render: OK DEVICE_V1 fill sample retained-BOs failed-receipts=2 cpu-pixels=0 synthetic-no-GPU" else "DISPLAYD native-render: FAILED");
    return passed and closed;
}
fn description(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1; value.size = @sizeOf(gfx.R4GfxResourceDesc); value.kind = kind;
    return value;
}
fn exercise(sys: *const r4os.r4sys.Context, client: *const gfx.DeviceV1Client, device: *const gfx.R4GfxDevice) bool {
    var stage: enum { backend, pipelines, allocation, submit, release, receipt, accounting, driver } = .backend;
    var passed = false;
    defer if (!passed) { sys.write("DISPLAYD native-render failed-stage="); sys.println(@tagName(stage)); };
    var info: gfx.R4GfxDeviceInfo = undefined;
    if (client.device_info(device, &info) != gfx.status_ok or info.adapter_id != 0xffff or info.gpu_operations & gfx.device_gpu_render == 0) return false;
    stage = .pipelines;
    var pipeline = description(gfx.resource_pipeline);
    pipeline.operation = gfx.render_operation_fill;
    var fill: gfx.R4GfxResource = undefined;
    var over: gfx.R4GfxResource = undefined;
    var sampler: gfx.R4GfxResource = undefined;
    if (client.resource_create(device, &pipeline, &fill) != gfx.status_ok) return false;
    pipeline.operation = gfx.render_operation_over;
    if (client.resource_create(device, &pipeline, &over) != gfx.status_ok) return false;
    var sampling = description(gfx.resource_sampler); sampling.sampler = gfx.render_sampler_bilinear;
    if (client.resource_create(device, &sampling, &sampler) != gfx.status_ok) return false;
    for (0..2) |index| {
        stage = .allocation;
        const deadline = (sys.monotonicNanoseconds() orelse return false) + 3_000_000_000;
        const allocation: gfx.R4GfxNativeImage = .{ .version = 1, .size = @sizeOf(gfx.R4GfxNativeImage), .deadline_ns = deadline,
            .width = 5, .height = 3, .format = gfx.format_xrgb8888, .layout = 0 };
        var image = description(gfx.resource_image);
        image.flags = gfx.image_target; image.source_kind = gfx.source_create_native; image.source_address = @intFromPtr(&allocation);
        var target: gfx.R4GfxResource = undefined;
        var source = std.mem.zeroes(gfx.R4GfxResource);
        if (!check(sys, "target", client.resource_create(device, &image, &target))) return false;
        if (index == 1 and client.resource_create(device, &image, &source) != gfx.status_ok) return false;
        var request = std.mem.zeroes(gfx.R4GfxRenderRequest);
        request.version = 1; request.size = @sizeOf(gfx.R4GfxRenderRequest); request.deadline_ns = deadline;
        request.target = target; request.source = source; request.pipeline = if (index == 0) fill else over;
        request.target_rect = .{ .x = -1, .y = 0, .width = 5, .height = 3 };
        request.scissor = .{ .x = 0, .y = 1, .width = 3, .height = 2 }; request.opacity = 127;
        if (index == 0) request.color = 0x80402010 else {
            request.sampler = sampler; request.transfer = gfx.render_transfer_srgb_decode;
            request.source_rect = .{ .x = 0, .y = 0, .width = 5, .height = 3 };
        }
        var job: gfx.R4GfxJob = undefined;
        stage = .submit;
        if (!check(sys, "submit", client.render_submit(device, &request, &job))) return false;
        request.color ^= 1; request.scissor.x = 123;
        stage = .release;
        if (client.resource_release(device, &target) != gfx.status_ok or
            (index == 1 and client.resource_release(device, &source) != gfx.status_ok)) return false;
        var receipt: gfx.R4GfxJobInfo = undefined;
        stage = .receipt;
        while (true) {
            if (client.job_info(device, &job, &receipt) != gfx.status_ok) return false;
            if (receipt.phase == a.gfx_queue_phase_terminal and receipt.flags == 0) break;
            if ((sys.monotonicNanoseconds() orelse return false) >= deadline) return false;
            sys.sleepTicks(1);
        }
        if (receipt.result != a.gfx_queue_result_failed or client.job_release(device, &job) != gfx.status_ok) return false;
    }
    // This explicit fixture collects retired synthetic backing in its native
    // allocation worker. A rejected allocation wakes that existing worker,
    // just as in native_allocation.zig; it must not create another image.
    stage = .allocation;
    const rejected: gfx.R4GfxNativeImage = .{ .version = 1, .size = @sizeOf(gfx.R4GfxNativeImage),
        .deadline_ns = (sys.monotonicNanoseconds() orelse return false) + 3_000_000_000,
        .width = 5, .height = 3, .format = gfx.format_r8, .layout = 0 };
    var invalid = description(gfx.resource_image);
    invalid.source_kind = gfx.source_create_native; invalid.source_address = @intFromPtr(&rejected);
    var unchanged = std.mem.zeroes(gfx.R4GfxResource);
    unchanged.slot = 79;
    const original = unchanged;
    if (client.resource_create(device, &invalid, &unchanged) != gfx.status_unsupported or !std.meta.eql(unchanged, original)) return false;
    stage = .accounting;
    if (client.device_info(device, &info) != gfx.status_ok or info.cpu_read_bytes != 0 or info.cpu_write_bytes != 0 or
        info.upload_bytes != 0 or info.gpu_copy_bytes != 0) return false;
    stage = .driver;
    passed = @import("buffers.zig").logContains(sys, "EXAMPLE.R4D gfx-render: OK immutable-state held-BOs short-take=denied receipt=failed no-GPU") and
        !@import("buffers.zig").logContains(sys, "EXAMPLE.R4D gfx-render: FAILED");
    return passed;
}
fn check(sys: *const r4os.r4sys.Context, label: []const u8, result: i32) bool {
    if (result == gfx.status_ok) return true;
    sys.write("DISPLAYD native-render "); sys.write(label); sys.write(" result="); sys.printI32(result); sys.println("");
    return false;
}
