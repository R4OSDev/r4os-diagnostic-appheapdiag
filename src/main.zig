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
    if (!ctx.dev.hasFn("memory_summary")) return fail(&ctx, "APPHEAPD memory snapshot missing");
    if (argsEqual(app.args(), "/HOLD")) return holdMode(&ctx);
    if (app.args().len != 0) return 2;
    if (!testSdkAllocator(&ctx)) return 1;
    if (!testAllocatorChurn(&ctx)) return 1;

    const summary = ctx.dev.memorySummary() orelse return fail(&ctx, "APPHEAPD summary unavailable");
    if (summary.by_kind[r4os.abi.memory_kind_app_heap] != 0) return fail(&ctx, "APPHEAPD AppHeap V1 still visible");
    ctx.sys.println("APPHEAPD result: OK churn=bounded cleanup=trimmed");
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

fn testAllocatorChurn(ctx: *DiagApi) bool {
    const allocator = ctx.sys.allocator();
    const before = ctx.sys.allocatorStats();
    const small_cycles: u64 = 64;
    const small_len = 192 * 1024;
    var cycle: u64 = 0;
    while (cycle < small_cycles) : (cycle += 1) {
        const memory = allocator.alignedAlloc(u8, .fromByteUnits(64), small_len) catch return failBool(ctx, "APPHEAPD small churn allocation failed");
        memory[0] = @truncate(cycle + 0x31);
        memory[memory.len - 1] = @truncate(cycle + 0x71);
        if (memory[0] != @as(u8, @truncate(cycle + 0x31)) or memory[memory.len - 1] != @as(u8, @truncate(cycle + 0x71))) {
            allocator.free(memory);
            return failBool(ctx, "APPHEAPD small churn data failed");
        }
        allocator.free(memory);
    }
    const after_small = ctx.sys.allocatorStats();
    const small_commits = counterDelta(before.vm_commit_calls, after_small.vm_commit_calls);
    const small_decommits = counterDelta(before.vm_decommit_calls, after_small.vm_decommit_calls);
    if (small_commits > 2 or small_decommits != 0) return failBool(ctx, "APPHEAPD small churn VM traffic failed");

    const direct_cycles: u64 = 32;
    const direct_len = 1024 * 1024 + 128 * 1024;
    cycle = 0;
    while (cycle < direct_cycles) : (cycle += 1) {
        const memory = allocator.alignedAlloc(u8, .fromByteUnits(4096), direct_len) catch return failBool(ctx, "APPHEAPD direct churn allocation failed");
        if ((@intFromPtr(memory.ptr) & 4095) != 0) {
            allocator.free(memory);
            return failBool(ctx, "APPHEAPD direct churn alignment failed");
        }
        memory[0] = @truncate(cycle + 0x21);
        memory[memory.len - 1] = @truncate(cycle + 0x61);
        if (memory[0] != @as(u8, @truncate(cycle + 0x21)) or memory[memory.len - 1] != @as(u8, @truncate(cycle + 0x61))) {
            allocator.free(memory);
            return failBool(ctx, "APPHEAPD direct churn data failed");
        }
        allocator.free(memory);
    }
    const after_direct = ctx.sys.allocatorStats();
    const direct_reserves = counterDelta(after_small.vm_reserve_calls, after_direct.vm_reserve_calls);
    const direct_commits = counterDelta(after_small.vm_commit_calls, after_direct.vm_commit_calls);
    const direct_releases = counterDelta(after_small.vm_release_calls, after_direct.vm_release_calls);
    const direct_hits = counterDelta(after_small.direct_cache_hits, after_direct.direct_cache_hits);
    if (direct_reserves > 1 or direct_commits > 1 or direct_releases != 0 or direct_hits + direct_reserves < direct_cycles) {
        return failBool(ctx, "APPHEAPD direct churn VM traffic failed");
    }
    if (after_direct.active_allocations != before.active_allocations or after_direct.cached_bytes > 14 * 1024 * 1024) {
        return failBool(ctx, "APPHEAPD churn bounds failed");
    }

    ctx.sys.write("APPHEAPD allocator churn: OK small=");
    ctx.sys.printU64(small_cycles);
    ctx.sys.write(" direct=");
    ctx.sys.printU64(direct_cycles);
    ctx.sys.write(" vm=");
    ctx.sys.printU64(small_commits);
    ctx.sys.write("/");
    ctx.sys.printU64(small_decommits);
    ctx.sys.write("+");
    ctx.sys.printU64(direct_reserves);
    ctx.sys.write("/");
    ctx.sys.printU64(direct_commits);
    ctx.sys.write("/");
    ctx.sys.printU64(direct_releases);
    ctx.sys.write(" cache-hits=");
    ctx.sys.printU64(direct_hits);
    ctx.sys.write(" retained-kb=");
    ctx.sys.printU64(after_direct.committed_bytes / 1024);
    ctx.sys.write(" peak-kb=");
    ctx.sys.printU64(after_direct.peak_committed_bytes / 1024);
    ctx.sys.println("");

    ctx.sys.allocatorTrim();
    const trimmed = ctx.sys.allocatorStats();
    if (trimmed.active_allocations != before.active_allocations or trimmed.direct_cached != 0 or trimmed.cached_bytes != 0 or
        trimmed.committed_bytes > after_direct.committed_bytes)
    {
        return failBool(ctx, "APPHEAPD allocator trim failed");
    }
    return true;
}

fn counterDelta(before: u64, after: u64) u64 {
    return if (after >= before) after - before else 0;
}

fn touchPages(mem: []u8, seed: u8) void {
    var offset: usize = 0;
    while (offset < mem.len) : (offset += 4096) {
        mem[offset] = seed +% @as(u8, @truncate(offset >> 12));
    }
    mem[mem.len - 1] = seed ^ 0x5A;
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
