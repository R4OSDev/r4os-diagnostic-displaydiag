//! Small DEVICE_V1 consumer within the existing /BUFFERS diagnostic.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");
const nv = @import("r4nv");

pub fn run(app: *r4os.App) bool {
    if (!shaderCache(app)) return false;
    const sys = app.system();
    const client = gfx.DeviceV1Client.init(app.startContext()) catch |err| {
        sys.write("DISPLAYD resources: unavailable reason="); sys.println(@errorName(err));
        return false;
    };
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
fn shaderCache(app: *r4os.App) bool {
    const sys = app.system();
    const client = nv.ShaderV1Client.init(app.startContext()) catch {
        sys.println("DISPLAYD shaders: unavailable");
        return true;
    };
    // Synthetic identity exercises the R4L boundary on any machine. It is
    // never supplied to a renderer and does not advertise NVIDIA capability.
    var key: nv.R4NvShaderKey = .{ .version = 1, .size = @sizeOf(nv.R4NvShaderKey), .vendor_id = 0x10de, .device_id = 0x2484,
        .graphics_class = nv.shader_graphics_class_ampere_b, .shader_model = nv.shader_model_sm86,
        .rm_release = nv.rm_release, .command_abi = nv.command_abi, .shader_abi = nv.shader_abi, .resource_abi = nv.shader_resource_abi,
        .input_format = gfx.format_argb8888, .output_format = gfx.format_xrgb8888, .driver_build = 0x100000002,
        .device_uuid = .{ .word0 = 1, .word1 = 2, .word2 = 3, .word3 = 4 },
        .pipeline_state = .{ .word0 = 5, .word1 = 6, .word2 = 7, .word3 = 8 } };
    var storage: [nv.shader_cache_max_bytes + 1]u8 = undefined;
    const bytes = storage[1..];
    var written: u32 = 0;
    var info: nv.R4NvShaderInfo = undefined;
    var view: nv.R4NvShaderView = std.mem.zeroes(nv.R4NvShaderView);
    const profile = nv.shader_profile_texture_fragment;
    if (client.shader_info(profile, &info) != nv.status_ok or info.stage != 4 or info.shader_model != 86 or info.header_bytes != 128 or
        client.shader_cache_write(profile, &key, bytes.ptr, bytes.len, &written) != nv.status_ok or written > bytes.len or
        written != nv.shader_cache_header_bytes + info.code_bytes) return false;
    key.driver_build += 1;
    if (client.shader_cache_read(&key, bytes.ptr, written, &view) != nv.status_cache_miss or view.code_address != 0) return false;
    key.driver_build -= 1;
    bytes[written - 1] ^= 1;
    if (client.shader_cache_read(&key, bytes.ptr, written, &view) != nv.status_cache_miss or view.code_address != 0) return false;
    bytes[written - 1] ^= 1;
    if (client.shader_cache_read(&key, bytes.ptr, written, &view) != nv.status_ok or view.info.profile != profile or
        view.info.code_bytes != info.code_bytes or view.header_address != @intFromPtr(bytes.ptr) + 224 or
        view.code_address != @intFromPtr(bytes.ptr) + nv.shader_cache_header_bytes) return false;
    sys.write("DISPLAYD shaders: OK SHADER_V1 software-cache code-bytes="); sys.printU64(info.code_bytes);
    sys.println(" stale=miss corrupt=miss");
    return true;
}
fn description(kind: u32) gfx.R4GfxResourceDesc {
    var value = std.mem.zeroes(gfx.R4GfxResourceDesc);
    value.version = 1; value.size = @sizeOf(gfx.R4GfxResourceDesc); value.kind = kind;
    return value;
}
fn exercise(sys: *const r4os.r4sys.Context, client: *const gfx.DeviceV1Client, device: *const gfx.R4GfxDevice) bool {
    var source: gfx.R4GfxResource = undefined;
    var target: gfx.R4GfxResource = undefined;
    var staging: gfx.R4GfxResource = undefined;
    var readback: gfx.R4GfxResource = undefined;
    var fill: gfx.R4GfxResource = undefined;
    var blit: gfx.R4GfxResource = undefined;
    var sampler: gfx.R4GfxResource = undefined;
    var image = description(gfx.resource_image);
    image.flags = gfx.image_target;
    image.image = .{ .cpu_address = 0, .byte_length = 64, .pitch = 16, .width = 4, .height = 4, .format = gfx.format_xrgb8888, .reserved = 0 };
    if (client.resource_create(device, &image, &source) != gfx.status_ok) return false;
    image.image.pitch = 24; image.image.byte_length = 96;
    if (client.resource_create(device, &image, &target) != gfx.status_ok) return false;
    image.image.pitch = 32; image.image.byte_length = 128;
    if (client.resource_create(device, &image, &staging) != gfx.status_ok) return false;
    var pixels: [16]u32 = @splat(0);
    image.image.pitch = 16; image.image.byte_length = 64;
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
    command.color = 0;
    command.target = target;
    if (client.render(device, &batch, &stats) != gfx.status_ok) return false;
    command.target = staging;
    if (client.render(device, &batch, &stats) != gfx.status_ok) return false;
    const deadline = (sys.monotonicNanoseconds() orelse return false) + 3_000_000_000;
    var job: gfx.R4GfxJob = undefined;
    if (client.copy_submit_ex(device, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx),
        .copy = .{ .source = source, .target = target, .source_offset = 20, .target_offset = 8, .byte_length = 8, .deadline_ns = deadline },
        .row_count = 3, .dependency_count = 0, .source_pitch = 16, .target_pitch = 24, .dependencies = 0 }, &job) != gfx.status_ok) return false;
    var upstream: gfx.R4GfxCopyFence = undefined;
    if (client.job_fence(device, &job, &upstream) != gfx.status_ok) return false;
    var dependent: gfx.R4GfxJob = undefined;
    if (client.copy_submit_ex(device, &.{ .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx),
        .copy = .{ .source = target, .target = staging, .source_offset = 8, .target_offset = 32, .byte_length = 8, .deadline_ns = deadline },
        .row_count = 3, .dependency_count = 1, .source_pitch = 24, .target_pitch = 32, .dependencies = @intFromPtr(&upstream) }, &dependent) != gfx.status_ok) return false;
    // Both jobs have been admitted. Only the final result is awaited; the
    // canonical queue retains the upstream fence and orders memory access.
    var receipt: gfx.R4GfxJobInfo = undefined;
    while (true) {
        if (client.job_info(device, &dependent, &receipt) != gfx.status_ok) return false;
        if (receipt.phase == r4os.abi.gfx_queue_phase_terminal and receipt.flags == 0) break;
        if ((sys.monotonicNanoseconds() orelse return false) >= deadline) return false;
        sys.sleepTicks(1);
    }
    if (receipt.result != r4os.abi.gfx_queue_result_complete or client.job_release(device, &dependent) != gfx.status_ok) return false;
    var first: gfx.R4GfxJobInfo = undefined;
    if (client.job_info(device, &job, &first) != gfx.status_ok or first.result != r4os.abi.gfx_queue_result_complete or
        first.flags != 0 or client.job_release(device, &job) != gfx.status_ok) return false;
    command.target = readback; command.source = staging; command.pipeline = blit; command.sampler = sampler;
    command.source_rect = command.target_rect; command.color = 0; command.opacity = 255;
    if (client.render(device, &batch, &stats) != gfx.status_ok) return false;
    for (pixels, 0..) |pixel, i| if (pixel != @as(u32, if (i / 4 >= 1 and i % 4 < 2) 0x2468ac else 0)) return false;
    var state: gfx.R4GfxDeviceInfo = undefined;
    if (client.device_info(device, &state) != gfx.status_ok or state.upload_bytes != 0 or
        state.gpu_copy_bytes != @as(u64, if (receipt.backend == gfx.render_backend_nvidia) 48 else 0)) return false;
    sys.write("DISPLAYD resources: OK DEVICE_V1 backend="); sys.printU64(state.backend);
    sys.write(" copy-bytes=48 completed=2 dependencies=1 pitches=16/24/32 pixels=16 cpu-read="); sys.printU64(state.cpu_read_bytes);
    sys.write(" cpu-write="); sys.printU64(state.cpu_write_bytes); sys.println(" upload=0");
    return true;
}
