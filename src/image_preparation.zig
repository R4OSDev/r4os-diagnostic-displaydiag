//! Bounded preparation consumer in the existing /BUFFERS diagnostic.
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx");

pub fn run(sys: *const r4os.r4sys.Context, client: *const gfx.DeviceV1Client, device: *const gfx.R4GfxDevice,
    source: gfx.R4GfxResource, readback: gfx.R4GfxResource, blit: gfx.R4GfxResource, sampler: gfx.R4GfxResource, pixels: []u32) bool
{
    const deadline = (sys.monotonicNanoseconds() orelse return false)+3_000_000_000;
    var ready: [1]gfx.R4GfxCopyFence = undefined;
    var prepared: gfx.R4GfxPreparedImage = undefined;
    var request: gfx.R4GfxImagePrepareRequest = .{ .version = 1, .size = @sizeOf(gfx.R4GfxImagePrepareRequest),
        .source = source, .uses = gfx.prepare_use_texture, .preference = gfx.prepare_layout_compatible, .flags = gfx.prepare_force_copy,
        .deadline_ns = deadline, .byte_budget = 65536, .dependency_count = 0, .dependencies = 0,
        .ready_dependencies = @intFromPtr(&ready), .ready_capacity = 1, .reserved = 0 };
    if (client.image_prepare(device,&request,&prepared) != gfx.status_ok or prepared.flags&gfx.prepared_copy_pending == 0 or
        prepared.job.slot == 0 or prepared.dependency_count != 1) return false;
    request.source = prepared.image; request.flags = 0; request.byte_budget = 0;
    request.dependencies = @intFromPtr(&ready); request.dependency_count = 1;
    const original_fence = ready[0];
    var reused: gfx.R4GfxPreparedImage = undefined;
    if (client.image_prepare(device,&request,&reused) != gfx.status_ok or reused.flags&gfx.prepared_reused == 0 or
        reused.job.slot != 0 or reused.dependency_count != 1 or !std.meta.eql(prepared.image,reused.image) or
        !std.meta.eql(original_fence,ready[0])) return false;
    var source_info: gfx.R4GfxResourceInfo = undefined;
    if (client.resource_info(device,&reused.image,&source_info) != gfx.status_ok) return false;
    var desc = std.mem.zeroes(gfx.R4GfxResourceDesc);
    desc.version = 1; desc.size = @sizeOf(gfx.R4GfxResourceDesc); desc.kind = gfx.resource_image; desc.flags = gfx.image_target;
    desc.source_kind = gfx.source_create_system;
    desc.image = .{ .cpu_address = 0, .byte_length = 96, .pitch = 24, .width = 4, .height = 4, .format = gfx.format_xrgb8888, .reserved = 0 };
    var restored: gfx.R4GfxResource = undefined;
    if (client.resource_create(device,&desc,&restored) != gfx.status_ok) return false;
    var downstream: gfx.R4GfxJob = undefined;
    if (client.copy_submit_ex(device,&.{ .version = 1, .size = @sizeOf(gfx.R4GfxCopyRequestEx),
        .copy = .{ .source = reused.image, .target = restored, .source_offset = 0, .target_offset = 0, .byte_length = 16, .deadline_ns = deadline },
        .row_count = 4, .source_pitch = source_info.image.pitch, .target_pitch = 24, .dependency_count = 1, .dependencies = @intFromPtr(&ready) },&downstream) != gfx.status_ok) return false;
    // Only queue-owned references remain for the prepared image. The
    // downstream copy waits for its preparation; no CPU-side fence wait.
    if (client.resource_release(device,&prepared.image) != gfx.status_ok or client.resource_release(device,&reused.image) != gfx.status_ok) return false;
    if (!finish(sys,client,device,&downstream,deadline) or !finish(sys,client,device,&prepared.job,deadline)) return false;
    var command = std.mem.zeroes(gfx.R4GfxDraw);
    command.target = readback; command.source = restored; command.pipeline = blit; command.sampler = sampler; command.opacity = 255;
    command.target_rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 }; command.source_rect = command.target_rect;
    var stats: gfx.R4GfxRenderStats = undefined;
    if (client.render(device,&.{ .commands = @intFromPtr(&command), .command_count = 1, .flags = 0, .pixel_budget = 16 },&stats) != gfx.status_ok) return false;
    for (pixels) |pixel| if (pixel != 0x2468ac) return false;
    if (client.resource_release(device,&restored) != gfx.status_ok) return false;
    sys.write("DISPLAYD image-prepare: OK backend="); sys.write(if (prepared.flags&gfx.prepared_software != 0) "software" else "nvidia");
    sys.println(" bounded-copy reuse=retained dependencies=1 copies=2 pixels=16 scaling=none");
    return true;
}
fn finish(sys: *const r4os.r4sys.Context, client: *const gfx.DeviceV1Client, device: *const gfx.R4GfxDevice, job: *const gfx.R4GfxJob, deadline: u64) bool {
    var info: gfx.R4GfxJobInfo = undefined;
    while (true) {
        if (client.job_info(device,job,&info) != gfx.status_ok) return false;
        if (info.phase == r4os.abi.gfx_queue_phase_terminal and info.flags == 0) break;
        if ((sys.monotonicNanoseconds() orelse return false) >= deadline) return false;
        sys.sleepTicks(1);
    }
    return info.result == r4os.abi.gfx_queue_result_complete and client.job_release(device,job) == gfx.status_ok;
}
