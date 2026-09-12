const std = @import("std");
const r4os = @import("r4os");
const producer = @import("r4gfx_queue");
const a = r4os.abi;
const ok = a.gfx_queue_ok;
const test_adapter = 0xFFFF0006;

fn fail(sys: *const r4os.r4sys.Context, line: u32) bool {
    sys.write("DISPLAYD queues FAILED line=");
    sys.printU64(line);
    sys.println("");
    return false;
}
fn deadline(sys: *const r4os.r4sys.Context) u64 {
    return (sys.monotonicNanoseconds() orelse 0) + 10_000_000_000;
}
fn bound(context: *const r4os.gfx_queue.Context, adapter: u32) ?a.GfxBackendBinding {
    for (0..a.gfx_queue_backend_capacity) |i| {
        var info: a.GfxBackendBinding = .{};
        if (context.backend(@intCast(i), &info) == ok and info.adapter_id == adapter) return info;
    }
    return null;
}
fn config(binding: a.GfxBackendBinding) a.GfxQueueConfig {
    return .{ .adapter_id = binding.adapter_id, .milestone = binding.milestone, .device_generation = binding.device_generation, .reset_generation = binding.reset_generation };
}
pub fn run(app: *r4os.App, native: bool) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const buffers = draw.buffers();
    const queues = draw.queues();
    var before: a.GfxBufferStats = .{};
    var after: a.GfxBufferStats = .{};
    if (buffers.stats(&before) != ok) return 1;
    var passed = software(&sys, &buffers, &queues);
    if (native and passed) passed = driver(&sys, &buffers, &queues);
    if (native and passed) passed = killedProducer(&sys, &queues, &buffers, before.retained_bytes);
    passed = buffers.stats(&after) == ok and passed;
    passed = passed and before.objects == after.objects and before.references == after.references and before.leases == after.leases and before.committed_bytes == after.committed_bytes;
    sys.println(if (passed) "DISPLAYD queues result: OK resources=balanced" else "DISPLAYD queues result: FAILED");
    return if (passed) 0 else 1;
}

const child_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\DISPLAYD.R4X";
const child_marker = "GFX-QUEUE-CHILD ";
pub fn child(app: *r4os.App) i32 {
    const sys = app.system();
    const draw = app.drawing() orelse return 1;
    const buffers = draw.buffers();
    const context = draw.queues();
    const binding = bound(&context, test_adapter) orelse return 1;
    var queue = producer.Queue{ .context = context };
    if (queue.open(config(binding)) != ok) return 1;
    // This fixture deliberately leaves all caller handles to process cleanup.
    var refs: [2]a.GfxBufferReference = .{a.GfxBufferReference{}} ** 2;
    for (&refs) |*ref| if (buffers.create(&.{ .byte_length = 4096, .usage = 15 }, ref) != ok) return 1;
    var status: a.GfxFenceStatus = .{};
    if (queue.copy(.{ .source = refs[0].reference, .target = refs[1].reference, .bytes = 4096, .deadline_ns = deadline(&sys) }, &status) != ok) return 1;
    for (&waits) |*waiter| {
        waiter.* = .{ .context = context, .fence = status.fence, .timeout = sys.ticksFromMilliseconds(5000) };
        var thread: a.ProgramJoinHandle = .{};
        if (sys.threadCreateHandle(waitThread, @intFromPtr(waiter), 128 * 1024, 0, &thread) != a.thread_ok) return 1;
    }
    const f = status.fence;
    var line: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&line, child_marker ++ "{d} {d} {d} {d} {d} {d}\n", .{ f.slot, f.adapter_id, f.timeline, f.point, f.device_generation, f.reset_generation }) catch return 1;
    sys.write(message);
    _ = context.wait(&status.fence, sys.ticksFromMilliseconds(5000), a.gfx_queue_wait_resources_released, &status);
    return 1; // The parent must kill all three blocked tasks before this.
}
fn readChildFence(sys: *const r4os.r4sys.Context, id: u32) ?a.GfxFence {
    var output: [2048]u8 = undefined;
    const count = sys.consoleOutput(id, &output);
    if (count <= 0 or count > output.len) return null;
    const text = output[0..@intCast(count)];
    const start = (std.mem.indexOf(u8, text, child_marker) orelse return null) + child_marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
    var tokens = std.mem.tokenizeAny(u8, text[start..end], " \r");
    var values: [6]u64 = undefined;
    for (&values) |*value| value.* = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    if (tokens.next() != null or values[0] > std.math.maxInt(u32) or values[1] > std.math.maxInt(u32)) return null;
    return .{ .slot = @intCast(values[0]), .adapter_id = @intCast(values[1]), .timeline = values[2], .point = values[3], .device_generation = values[4], .reset_generation = values[5] };
}
fn childBlocked(sys: *const r4os.r4sys.Context, child_handle: a.ProgramProcessHandle) bool {
    var cursor: a.ProgramInventoryCursor = .{};
    var summary: a.ProgramInventorySummary = .{};
    if (sys.programInventoryBegin(&cursor, &summary) != a.program_handle_ok) return false;
    var tasks: [32]a.ProgramTaskSnapshot = undefined;
    var blocked: usize = 0;
    // Bounded complete inventory; an epoch restart never counts as success.
    for (0..32) |_| {
        var page: a.ProgramInventoryPageInfo = .{};
        if (sys.programInventoryTasks(&cursor, &tasks, &page) != a.program_handle_ok or
            page.status == a.program_inventory_status_restart or page.returned > tasks.len) return false;
        for (tasks[0..page.returned]) |entry| {
            // ProgramTaskSnapshot uses Task.State: blocked=3. The child has
            // only its main task and the two finite graphics-event waiters.
            if (entry.owner_instance_id == child_handle.instance_id and entry.instance_generation == child_handle.generation and
                entry.state == 3 and entry.wake_tick != 0) blocked += 1;
        }
        if (page.status == a.program_inventory_status_complete and page.has_more == 0) return blocked == 3;
    }
    return false;
}
fn killedProducer(sys: *const r4os.r4sys.Context, context: *const r4os.gfx_queue.Context, buffers: *const r4os.gfx_buffers.Context, retained_before: u64) bool {
    var handle: a.ProgramProcessHandle = .{};
    if (sys.programSpawnWithConsoleHostHandle(child_path, "/QUEUECHILD", .console, .terminal_window, &handle) != a.program_handle_ok) return fail(sys, @src().line);
    defer if (handle.instance_id != 0) {
        _ = sys.programHandleKill(&handle);
        var completion: a.ProgramProcessCompletion = .{};
        _ = sys.programHandleWait(&handle, sys.ticksFromMilliseconds(5000), &completion);
        _ = sys.programHandleReap(&handle, &completion);
    };
    const start = sys.ticks();
    var fence: ?a.GfxFence = null;
    while (sys.ticks() - start < sys.ticksFromMilliseconds(2000)) {
        fence = readChildFence(sys, handle.instance_id);
        if (fence != null and childBlocked(sys, handle)) break;
        sys.sleepTicks(1);
    }
    if (fence == null or !childBlocked(sys, handle)) return fail(sys, @src().line);
    var status: a.GfxFenceStatus = .{};
    if (context.query(&fence.?, &status) != ok or status.flags != 3) return fail(sys, @src().line);
    // Keep one external waiter until physical completion. The producer's
    // three wait records must be removed by the task-generation reaper.
    waits[0] = .{ .context = context.*, .fence = fence.?, .timeout = sys.ticksFromMilliseconds(5000) };
    var thread: a.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(waitThread, @intFromPtr(&waits[0]), 128 * 1024, 0, &thread) != a.thread_ok) return fail(sys, @src().line);
    const enrolled = sys.ticks();
    while (@atomicLoad(u32, &waits[0].entered, .acquire) == 0) {
        if (sys.ticks() - enrolled >= sys.ticksFromMilliseconds(1000)) return fail(sys, @src().line);
        sys.sleepTicks(1);
    }
    if (sys.programHandleKill(&handle) != a.program_handle_ok) return fail(sys, @src().line);
    var completion: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&handle, sys.ticksFromMilliseconds(1000), &completion) != a.program_handle_ok or completion.exit_code != -9 or
        sys.programHandleReap(&handle, &completion) != a.program_handle_ok) return fail(sys, @src().line);
    handle = .{};
    if (context.query(&fence.?, &status) != ok or status.result != a.gfx_queue_result_cancelled or status.flags != 3) return fail(sys, @src().line);
    sys.println("DISPLAYD queues kill: producer=reaped before-IRQ");
    var code: i32 = -1;
    if (sys.threadHandleJoin(&thread, sys.ticksFromMilliseconds(5000), &code) != a.thread_ok or code != 0) return fail(sys, @src().line);
    const retired = sys.ticks();
    while (sys.ticks() - retired < sys.ticksFromMilliseconds(1000)) {
        const rc = context.query(&fence.?, &status);
        if (rc == a.gfx_queue_error_stale) {
            // Queue retirement and the ordinary mapping worker are separate
            // completions. Require the driver's post-exit handoff and final
            // release before accepting the common BO accounting baseline.
            const memory_marker = "EXAMPLE.R4D gfx-queue retained: OK producer=closed work=ordinary same-BO=2 extents=exact maps=4";
            while (!@import("buffers.zig").logContains(sys, memory_marker)) {
                if (sys.ticks() - retired >= sys.ticksFromMilliseconds(1000)) return fail(sys, @src().line);
                sys.sleepTicks(1);
            }
            sys.println(memory_marker);
            // The second mapping cleanup may still be running; resources
            // released by queue retirement alone are not sufficient proof.
            var stats: a.GfxBufferStats = .{};
            while (true) {
                if (buffers.stats(&stats) != ok) return fail(sys, @src().line);
                if (stats.retained_bytes == retained_before) break;
                if (sys.ticks() - retired >= sys.ticksFromMilliseconds(1000)) return fail(sys, @src().line);
                sys.sleepTicks(1);
            }
            sys.println("DISPLAYD queues kill: OK blocked-tasks=3 producer=reaped DMA=retained-until-IRQ fence=retired");
            return true;
        }
        if (rc != ok) return fail(sys, @src().line);
        sys.sleepTicks(1);
    }
    return fail(sys, @src().line);
}
fn software(sys: *const r4os.r4sys.Context, buffers: *const r4os.gfx_buffers.Context, context: *const r4os.gfx_queue.Context) bool {
    const binding = bound(context, 0) orelse return fail(sys, @src().line);
    if (binding.milestone != a.gfx_queue_milestone_cpu_stores) return fail(sys, @src().line);
    var upload = producer.Queue{ .context = context.* };
    var render = producer.Queue{ .context = context.* };
    if (upload.open(config(binding)) != ok or render.open(config(binding)) != ok) return fail(sys, @src().line);
    defer _ = upload.close();
    defer _ = render.close();
    const bytes = 8 * 1024 * 1024;
    var refs: [3]a.GfxBufferReference = .{a.GfxBufferReference{}} ** 3;
    defer for (&refs) |*ref| if (ref.reference.id != 0) {
        _ = buffers.release(&ref.reference);
    };
    for (&refs) |*ref| if (buffers.create(&.{ .byte_length = bytes, .usage = 15 }, ref) != ok) return fail(sys, @src().line);
    var map: a.GfxBufferMap = .{};
    if (buffers.map(&refs[0].reference, 1, 0, bytes, &map) != ok) return fail(sys, @src().line);
    @memset(@as([*]u8, @ptrFromInt(map.cpu_address))[0..bytes], 0xA7);
    if (buffers.unmap(&map.lease) != ok) return fail(sys, @src().line);
    var first: a.GfxFenceStatus = .{};
    var second: a.GfxFenceStatus = .{};
    if (upload.copy(.{ .source = refs[0].reference, .target = refs[1].reference, .source_offset = 3, .target_offset = 5, .bytes = bytes - 33, .deadline_ns = deadline(sys) }, &first) != ok) return fail(sys, @src().line);
    if (render.copy(.{ .source = refs[1].reference, .target = refs[2].reference, .source_offset = 5, .target_offset = 9, .bytes = bytes - 33, .deadline_ns = deadline(sys), .dependencies = &.{first.fence} }, &second) != ok) return fail(sys, @src().line);
    for (refs[0..2]) |ref| if (buffers.release(&ref.reference) != ok) return fail(sys, @src().line);
    refs[0].reference = .{};
    refs[1].reference = .{};
    if (context.wait(&second.fence, sys.ticksFromMilliseconds(5000), a.gfx_queue_wait_resources_released, &second) != ok or second.result != a.gfx_queue_result_complete or second.flags != 0 or second.milestone != a.gfx_queue_milestone_cpu_stores) return fail(sys, @src().line);
    if (buffers.map(&refs[2].reference, 0, 0, bytes, &map) != ok) return fail(sys, @src().line);
    const result: [*]const u8 = @ptrFromInt(map.cpu_address);
    const identical = std.mem.allEqual(u8, result[0..9], 0) and std.mem.allEqual(u8, result[9 .. bytes - 24], 0xA7) and std.mem.allEqual(u8, result[bytes - 24 .. bytes], 0);
    if (buffers.unmap(&map.lease) != ok or !identical) return fail(sys, @src().line);
    if (context.release(&first.fence) != ok or context.release(&second.fence) != ok) return fail(sys, @src().line);
    sys.println("DISPLAYD queues software: OK copy=8388575 dependencies=ordered producer-references=released padding=preserved");
    return true;
}

const Wait = struct { context: r4os.gfx_queue.Context = undefined, fence: a.GfxFence = .{}, timeout: u64 = 0, entered: u32 = 0 };
var waits: [2]Wait = .{Wait{}} ** 2;
fn waitThread(raw: u64) callconv(.c) i32 {
    const value: *Wait = @ptrFromInt(raw);
    @atomicStore(u32, &value.entered, 1, .release);
    var result: a.GfxFenceStatus = .{};
    if (value.context.wait(&value.fence, value.timeout, a.gfx_queue_wait_resources_released, &result) != ok or result.flags != 0 or result.result != a.gfx_queue_result_cancelled) return 1;
    return 0;
}
const InputProgress = struct { sys: r4os.r4sys.Context = undefined, context: r4os.gfx_queue.Context = undefined, fence: a.GfxFence = .{}, seen: u32 = 0, ticks: u64 = 0 };
var input_progress = InputProgress{};
fn inputThread(_: u64) callconv(.c) i32 {
    const value = &input_progress;
    const start = value.sys.ticks();
    while (value.sys.ticks() - start < value.sys.ticksFromMilliseconds(5000)) {
        var status: a.GfxFenceStatus = .{};
        if (value.context.query(&value.fence, &status) != ok or (status.flags & a.gfx_queue_flag_device_active) == 0) break;
        const key = value.sys.readKey();
        if (key == 'g' or key == 'G') {
            @atomicStore(u32, &value.seen, 1, .release);
            value.sys.println("DISPLAYD queue-input: OK while-device-active");
        }
        value.ticks += 1;
        value.sys.sleepTicks(1);
    }
    return 0;
}
fn driver(sys: *const r4os.r4sys.Context, buffers: *const r4os.gfx_buffers.Context, context: *const r4os.gfx_queue.Context) bool {
    const binding = bound(context, test_adapter) orelse return fail(sys, @src().line);
    var queue = producer.Queue{ .context = context.* };
    if (queue.open(config(binding)) != ok) return fail(sys, @src().line);
    defer _ = queue.close();
    var refs: [2]a.GfxBufferReference = .{a.GfxBufferReference{}} ** 2;
    defer for (refs) |ref| if (ref.reference.id != 0) {
        _ = buffers.release(&ref.reference);
    };
    for (&refs) |*ref| if (buffers.create(&.{ .byte_length = 4096, .usage = 15 }, ref) != ok) return fail(sys, @src().line);
    var status: a.GfxFenceStatus = .{};
    if (queue.copy(.{ .source = refs[0].reference, .target = refs[1].reference, .source_offset = 3, .target_offset = 5, .bytes = 4079, .deadline_ns = deadline(sys) }, &status) != ok) return fail(sys, @src().line);
    const start = sys.ticks();
    while ((status.flags & a.gfx_queue_flag_device_active) == 0 and sys.ticks() - start < sys.ticksFromMilliseconds(1000)) {
        sys.sleepTicks(1);
        if (context.query(&status.fence, &status) != ok) return fail(sys, @src().line);
    }
    if ((status.flags & a.gfx_queue_flag_device_active) == 0 or context.cancel(&status.fence) != ok) return fail(sys, @src().line);
    if (context.wait(&status.fence, 0, a.gfx_queue_wait_completion, &status) != ok or status.result != a.gfx_queue_result_cancelled or status.flags != 3) return fail(sys, @src().line);
    const completed_ns = status.completed_ns;
    var denied: a.GfxBufferMap = .{};
    if (buffers.map(&refs[1].reference, 1, 0, 4096, &denied) != a.gfx_buffer_error_busy) return fail(sys, @src().line);
    for (&refs) |*ref| {
        if (buffers.release(&ref.reference) != ok) return fail(sys, @src().line);
        ref.reference = .{};
    }
    var timeout = status;
    if (context.wait(&status.fence, sys.ticksFromMilliseconds(20), a.gfx_queue_wait_resources_released, &timeout) != a.gfx_queue_error_wait_timeout or !std.meta.eql(timeout, status)) return fail(sys, @src().line);
    var threads: [3]a.ProgramJoinHandle = .{a.ProgramJoinHandle{}} ** 3;
    for (&waits, 0..) |*waiter, i| {
        waiter.* = .{ .context = context.*, .fence = status.fence, .timeout = sys.ticksFromMilliseconds(5000) };
        if (sys.threadCreateHandle(waitThread, @intFromPtr(waiter), 128 * 1024, 0, &threads[i]) != a.thread_ok) return fail(sys, @src().line);
    }
    input_progress = .{ .sys = sys.*, .context = context.*, .fence = status.fence };
    if (sys.threadCreateHandle(inputThread, 0, 128 * 1024, 0, &threads[2]) != a.thread_ok) return fail(sys, @src().line);
    sys.println("[GFX07906] waiting-for-IRQ input-key=g");
    if (context.wait(&status.fence, sys.ticksFromMilliseconds(5000), a.gfx_queue_wait_resources_released, &status) != ok or status.flags != 0 or status.result != a.gfx_queue_result_cancelled or status.completed_ns != completed_ns) return fail(sys, @src().line);
    for (threads) |thread| {
        var code: i32 = -1;
        if (sys.threadHandleJoin(&thread, sys.ticksFromMilliseconds(1000), &code) != a.thread_ok or code != 0) return fail(sys, @src().line);
    }
    if (input_progress.ticks == 0 or input_progress.seen != 1 or waits[0].entered != 1 or waits[1].entered != 1) return fail(sys, @src().line);
    if (context.release(&status.fence) != ok) return fail(sys, @src().line);
    sys.println("DISPLAYD queues IRQ: OK cancellation=sticky waiters=3 reuse=after-quiescence");
    var reset: a.GfxFenceStatus = .{};
    if (queue.barrier(deadline(sys), 0, &.{}, &reset) != ok) return fail(sys, @src().line);
    if (context.wait(&reset.fence, sys.ticksFromMilliseconds(2000), a.gfx_queue_wait_resources_released, &reset) != ok or reset.result != a.gfx_queue_result_device_lost) return fail(sys, @src().line);
    const updated = bound(context, test_adapter) orelse return fail(sys, @src().line);
    if (updated.device_generation != binding.device_generation or updated.reset_generation != binding.reset_generation + 1) return fail(sys, @src().line);
    var old = producer.Queue{ .context = context.* };
    if (old.open(config(binding)) != a.gfx_queue_error_stale) return fail(sys, @src().line);
    if (context.release(&reset.fence) != ok or queue.close() != ok or queue.open(config(updated)) != ok) return fail(sys, @src().line);
    if (queue.barrier(deadline(sys), 0, &.{}, &reset) != ok or context.wait(&reset.fence, sys.ticksFromMilliseconds(2000), a.gfx_queue_wait_resources_released, &reset) != ok or reset.result != a.gfx_queue_result_complete) return fail(sys, @src().line);
    if (context.release(&reset.fence) != ok) return fail(sys, @src().line);
    sys.println("DISPLAYD queues reset: OK device-lost=distinct generations=exact");
    for ([_][]const u8{
        "EXAMPLE.R4D gfx-queue prefix: OK bytes=56 canary=preserved",
        "EXAMPLE.R4D gfx-queue retained: OK work=ordinary same-BO=2 extents=exact maps=4",
        "EXAMPLE.R4D gfx-queue mapping release: OK IRQ=observed DMA-GPU-reference=balanced",
        "EXAMPLE.R4D gfx-queue IRQ: OK late=exact duplicate=rejected unproven=retained",
        "EXAMPLE.R4D gfx-queue reset: OK lost=published old-generation=retained quiescence=required",
    }) |marker| {
        if (!@import("buffers.zig").logContains(sys, marker)) return fail(sys, @src().line);
        sys.println(marker);
    }
    return true;
}
