const r4os = @import("r4os");
const std = @import("std");

const DiagApi = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,
    resources: r4os.Resources,

    fn init(app: *r4os.App) ?DiagApi {
        return .{
            .sys = app.system(),
            .dev = app.devicesLowLevel() orelse return null,
            .resources = app.resources(),
        };
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    var ctx = DiagApi.init(app) orelse return r4os.abi.err_no_group;
    ctx.sys.println("APPHEAPD");

    if (!ctx.sys.hasFn("vm_reserve")) return fail(&ctx, "APPHEAPD R4SYS VM missing");
    if (!ctx.sys.base.hasDevFn("performance_summary")) return fail(&ctx, "APPHEAPD VM stats missing");
    if (!ctx.dev.hasFn("memory_summary")) return fail(&ctx, "APPHEAPD memory snapshot missing");
    if (argsEqual(app.args(), "/HOLD")) return holdMode(&ctx);
    if (argsEqual(app.args(), "/HOLDVM")) return holdVmMode(&ctx);
    if (!testR4sysVmApi(&ctx)) return 1;
    if (!stressVmLifecycle(&ctx)) return 1;
    if (!testSdkAllocator(&ctx)) return 1;

    const summary = ctx.dev.memorySummary() orelse return fail(&ctx, "APPHEAPD summary unavailable");
    if (summary.by_kind[r4os.abi.memory_kind_app_heap] != 0) return fail(&ctx, "APPHEAPD AppHeap V1 still visible");
    ctx.sys.write("APPHEAPD VM ranges: ");
    ctx.sys.printU64(summary.by_kind[r4os.abi.memory_kind_virtual_range]);
    ctx.sys.println("");
    ctx.sys.println("APPHEAPD result: OK");
    return 0;
}

fn holdMode(ctx: *DiagApi) i32 {
    const allocator = ctx.sys.allocator();
    const mem = allocator.alignedAlloc(u8, .fromByteUnits(4096), 2 * 1024 * 1024) catch return fail(ctx, "APPHEAPD hold allocation failed");
    defer allocator.free(mem);
    touchPages(mem, 0x48);
    ctx.sys.println("APPHEAPD hold: ready");
    while (!ctx.sys.programShouldClose()) {
        ctx.sys.sleepTicks(1);
    }
    ctx.sys.println("APPHEAPD hold: done");
    return 0;
}

fn holdVmMode(ctx: *DiagApi) i32 {
    var region = switch (ctx.resources.reserveVm(128 * 1024 * 1024, 4096, r4os.abi.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return fail(ctx, "APPHEAPD hold-vm reserve failed"),
    };
    var release_needed = true;
    defer {
        if (release_needed) _ = region.release();
    }

    if (region.commit(0, 64 * 1024 * 1024) != r4os.abi.vm_ok) return fail(ctx, "APPHEAPD hold-vm commit failed");
    const committed = switch (region.info()) {
        .value => |info| info,
        .failure => return fail(ctx, "APPHEAPD hold-vm query failed"),
    };
    const ptr: [*]u8 = @ptrFromInt(committed.base);
    const touched_pages = touchVmPages(ptr, 16 * 1024 * 1024, 0x4C);
    const touched = switch (region.info()) {
        .value => |info| info,
        .failure => return fail(ctx, "APPHEAPD hold-vm touched query failed"),
    };
    if (touched.resident_bytes < touched_pages * 4096 or touched.fault_count < touched_pages or touched.failed_faults != 0) {
        return fail(ctx, "APPHEAPD hold-vm stats failed");
    }
    ctx.sys.write("APPHEAPD hold-vm: ready resident=");
    ctx.sys.printU64(touched.resident_bytes);
    ctx.sys.println("");
    while (!ctx.sys.programShouldClose()) {
        ctx.sys.sleepTicks(1);
    }
    if (region.release() != r4os.abi.vm_ok) return fail(ctx, "APPHEAPD hold-vm release failed");
    release_needed = false;
    ctx.sys.println("APPHEAPD hold-vm: done");
    return 0;
}

fn testR4sysVmApi(ctx: *DiagApi) bool {
    var region = switch (ctx.resources.reserveVm(32 * 1024 * 1024, 4096, r4os.abi.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return failBool(ctx, "APPHEAPD VM reserve failed"),
    };
    var release_needed = true;
    defer {
        if (release_needed) _ = region.release();
    }

    if (region.last_info.kind != r4os.abi.memory_kind_virtual_range or region.last_info.window != r4os.abi.memory_window_r4x_vm) {
        return failBool(ctx, "APPHEAPD VM reserve kind failed");
    }
    var borrowed = region;
    borrowed.owned = false;
    if (borrowed.release() != r4os.abi.err_not_owned) return failBool(ctx, "APPHEAPD borrowed release accepted");
    if (region.commit(0, 8 * 1024 * 1024) != r4os.abi.vm_ok) return failBool(ctx, "APPHEAPD VM commit failed");
    const committed = switch (region.info()) {
        .value => |info| info,
        .failure => return failBool(ctx, "APPHEAPD VM query failed"),
    };
    if (committed.committed_bytes < 8 * 1024 * 1024) return failBool(ctx, "APPHEAPD VM committed bytes failed");
    const ptr: [*]u8 = @ptrFromInt(committed.base);
    if (!touchSparse(ptr, 8 * 1024 * 1024, 0x51)) return failBool(ctx, "APPHEAPD VM touch failed");
    const touched = switch (region.info()) {
        .value => |info| info,
        .failure => return failBool(ctx, "APPHEAPD VM touched query failed"),
    };
    if (touched.resident_bytes < 3 * 4096 or touched.fault_count < 3 or touched.failed_faults != 0) {
        return failBool(ctx, "APPHEAPD VM region stats failed");
    }
    if (region.decommit(0, 8 * 1024 * 1024) != r4os.abi.vm_ok) return failBool(ctx, "APPHEAPD VM decommit failed");
    if (region.release() != r4os.abi.vm_ok) return failBool(ctx, "APPHEAPD VM release failed");
    if (region.release() != r4os.abi.err_closed) return failBool(ctx, "APPHEAPD double release mismatch");
    release_needed = false;
    return true;
}

fn stressVmLifecycle(ctx: *DiagApi) bool {
    var index: u32 = 0;
    while (index < 80) : (index += 1) {
        var region = switch (ctx.resources.reserveVm(4096, 4096, r4os.abi.vm_region_flags_default)) {
            .region => |value| value,
            .failure => return failBool(ctx, "APPHEAPD VM stress reserve leaked slots"),
        };
        if (region.commit(0, 4096) != r4os.abi.vm_ok or region.decommit(0, 4096) != r4os.abi.vm_ok or region.release() != r4os.abi.vm_ok) {
            return failBool(ctx, "APPHEAPD VM stress lifecycle failed");
        }
    }
    return true;
}

fn testSdkAllocator(ctx: *DiagApi) bool {
    const before = ctx.dev.memorySummary() orelse return failBool(ctx, "APPHEAPD SDK summary before failed");
    const allocator = ctx.sys.allocator();

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    bytes.appendSlice(allocator, "R4OS") catch return failBool(ctx, "APPHEAPD ArrayList bytes failed");
    bytes.append(allocator, '-') catch return failBool(ctx, "APPHEAPD ArrayList append failed");
    bytes.appendSlice(allocator, "VMV2") catch return failBool(ctx, "APPHEAPD ArrayList growth failed");
    if (!std.mem.eql(u8, bytes.items, "R4OS-VMV2")) return failBool(ctx, "APPHEAPD ArrayList data failed");

    var numbers: std.ArrayList(u32) = .empty;
    defer numbers.deinit(allocator);
    var i: u32 = 0;
    while (i < 48) : (i += 1) numbers.append(allocator, i * 5 + 7) catch return failBool(ctx, "APPHEAPD ArrayList numbers failed");
    const large = allocator.alloc(u8, 2 * 1024 * 1024) catch return failBool(ctx, "APPHEAPD SDK large alloc failed");
    defer allocator.free(large);
    if ((@intFromPtr(large.ptr) & 4095) != 0) return failBool(ctx, "APPHEAPD SDK large alignment failed");
    touchPages(large, 0x62);

    const during = ctx.dev.memorySummary() orelse return failBool(ctx, "APPHEAPD SDK summary during failed");
    const stats = ctx.sys.allocatorStats();
    if (before.by_kind[r4os.abi.memory_kind_app_heap] != 0 or during.by_kind[r4os.abi.memory_kind_app_heap] != 0) {
        return failBool(ctx, "APPHEAPD SDK AppHeap visible");
    }
    if (during.by_kind[r4os.abi.memory_kind_virtual_range] <= before.by_kind[r4os.abi.memory_kind_virtual_range]) {
        return failBool(ctx, "APPHEAPD SDK VM range missing");
    }
    if (stats.small_regions == 0 or stats.active_allocations < 3 or stats.active_bytes < large.len) return failBool(ctx, "APPHEAPD SDK VM stats failed");
    return numbers.items.len == 48 and numbers.items[0] == 7 and numbers.items[47] == 242;
}

fn touchSparse(mem: [*]u8, len: u64, seed: u8) bool {
    if (len < 4096) return false;
    const first: usize = 0;
    const middle: usize = @intCast((len / 2) & ~@as(u64, 4095));
    const last: usize = @intCast(len - 1);
    mem[first] = seed;
    mem[middle] = seed +% 1;
    mem[last] = seed ^ 0xA5;
    return mem[first] == seed and mem[middle] == seed +% 1 and mem[last] == seed ^ 0xA5;
}

fn touchPages(mem: []u8, seed: u8) void {
    var offset: usize = 0;
    while (offset < mem.len) : (offset += 4096) {
        mem[offset] = seed +% @as(u8, @truncate(offset >> 12));
    }
    mem[mem.len - 1] = seed ^ 0x5A;
}

fn touchVmPages(mem: [*]u8, len: u64, seed: u8) u64 {
    var offset: u64 = 0;
    var pages: u64 = 0;
    while (offset < len) : (offset += 4096) {
        const index: usize = @intCast(offset);
        mem[index] = seed +% @as(u8, @truncate(offset >> 12));
        pages += 1;
    }
    return pages;
}

fn fail(ctx: *DiagApi, msg: []const u8) i32 {
    ctx.sys.println(msg);
    ctx.sys.println("APPHEAPD result: FAILED");
    return 1;
}

fn failBool(ctx: *DiagApi, msg: []const u8) bool {
    _ = fail(ctx, msg);
    return false;
}

fn argsEqual(args: []const u8, expected: []const u8) bool {
    if (args.len != expected.len) return false;
    for (args, expected) |actual, wanted| if (upperAscii(actual) != upperAscii(wanted)) return false;
    return true;
}

fn upperAscii(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
