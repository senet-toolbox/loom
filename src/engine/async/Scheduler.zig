// This is the Coroutine struct
const std = @import("std");
const Atomic = std.atomic.Value;
const base = @import("base.zig");
const Fiber = @import("Fiber.zig");
const StackConstruct = @import("Stack.zig");
const Signature = @import("Signature.zig");
const Status = Fiber.Status;
const utils = @import("utils.zig");
const Stack = @import("types.zig").Stack;
// const ThreadRipper = @import("pool/ThreadRipper.zig");
// const GateKeeper = ThreadRipper.GateKeeper;
pub const Channel = @import("Channel.zig");
const print = std.debug.print;
const mem = std.mem;

pub const stack_alignment = base.stack_alignment;
pub const SchedulerStatus = enum {
    Inactive,
    Active,
    Running,
    AllDone,
};

var createdThreadPool: bool = false;

/// This is the Scheduler, you can create fibers (coroutines) and manage them here.
const Scheduler = @This();
allocator: mem.Allocator,
default_stack_size: usize = 1024 * 4,
status: SchedulerStatus = .Inactive,
// atm_pool: ThreadRipper = undefined,
// gate_keeper: GateKeeper = undefined,

pub fn init(target: *Scheduler, allocator: mem.Allocator) !void {
    target.* = .{
        .allocator = allocator,
    };
}

pub fn deinit(scheduler: *Scheduler) void {
    scheduler.atm_pool.deinit();
}

/// InitPool creates a new thread atm_pool
/// takes and opts config for allocator
pub fn initPool(scheduler: *Scheduler) !void {
    // var tr: ThreadRipper = undefined;
    // tr.init(tp_opts) catch |err| {
    //     std.log.err("Initialization of Pool Error: {any}\n", .{err});
    //     return err;
    // };
    scheduler.atm_pool = undefined;
    createdThreadPool = true;
}

/// Init GateKeeper uses threadpool allocator under the hood
/// # Parameters:
/// - `sclr`: *Scheduler, A scheduler
/// example usage:
/// ```zig
/// var gk = try sclr.initGK();
/// ```
/// for more info see [the docs](url)
pub fn initGK(scheduler: *Scheduler) !void {
    utils.assert_cm(
        createdThreadPool,
        "Cannot Create GateKeeper, while thread atm_pool is null",
    );
    scheduler.gate_keeper.init(&scheduler.atm_pool.arena) catch |err| {
        std.log.err("Initialization of GateKeeper Error: {any}\n", .{err});
        return err;
    };
}

/// Creates a Stack
/// # Parameters:
/// - `sclr`: *Scheduler, A scheduler
/// - `size`: ?usize,
/// example usage:
/// ```zig
/// const stack = try sclr.stackAlloc(1024);
/// ```
/// for more info see [the docs](url)
pub fn stackAlloc(sclr: *Scheduler, size: ?usize) !Stack {
    return sclr.allocator.alignedAlloc(
        u8,
        stack_alignment,
        size orelse sclr.default_stack_size,
    ) catch |err| {
        std.log.err("Stack Alloc error: {any}\n", .{err});
        return err;
    };
}

/// Frees a stack
/// # Parameters:
/// - `sclr`: *Scheduler, A scheduler
/// - `stack`: Stack,
/// Example usage:
/// ```zig
///    freeStack(stack);
/// ```
/// For more info see [the docs](url)
pub fn freeStack(sclr: *Scheduler, stack: Stack) void {
    sclr.allocator.free(stack);
}

// ========================================================================
/// Creates a *Fiber
/// # Parameters:
/// - `func`: anytype, but must be a function, like *const fn () void, must return void
/// - `args`: anytype,
/// - `stack`: []align(stack_alignment) u8,
/// Example usage:
/// ```zig
/// const fiber = try createFiber(fiber_func, .{}, stack);
/// ```
/// For more info see [the docs](url)
pub fn createFiber(func: anytype, args: anytype, stack: Stack) !*Fiber {
    utils.assert_cm(@typeInfo(@TypeOf(func)) == .@"fn", "Fibers must take a function as input");
    var fiber: *Fiber = undefined;
    fiber = try Fiber.init(func, args, stack);
    return fiber;
}

/// Resets a completed fiber so it can be run again.
///
/// This function re-initializes the fiber's stack frame and resets its
/// status. It assumes the fiber's `func` will be called by the `Fiber.run`
/// trampoline, similar to the `initFromStack` function.
///
/// # Parameters:
/// - `target`: The completed fiber (must be in `.Done` state).
/// - `stack`: The *original* stack slice associated with this fiber.
/// - `func`: The function the fiber should run (e.g., `handleCTX`).
/// - `storage`: Optional pointer to be stored in the fiber.
pub fn resetFiber(
    target: *Fiber,
    stack: Stack,
    func: *const fn () anyerror!void,
    // storage: ?*anyopaque, // <-- REMOVE THIS ARG
) !void {
    utils.assert_cm(
        target.f_status == Status.Done,
        "Can only reset a fiber that is already completed",
    );

    const base_frame = base.Frame.init(&(Fiber.run), stack) catch |err| {
        std.log.err("Could not re-init Frame, stack invalid {any}\n", .{err});
        return err;
    };

    // --- THIS IS THE FIX ---
    // We must preserve the .id and .storage pointers.
    // .storage points to InnerStorage, which is *still on the stack*
    // and holds the arguments. We are just resetting the *state*.
    const original_id = target.id;
    const original_storage = target.storage;

    target.* = Fiber{
        .id = original_id,
        .storage = original_storage, // <-- PRESERVE THIS
        .f_status = .Start,
        .f_frame = base_frame,
        .func = func,
        .caller = null,
        .err = null, // Clear any previous error
    };
}

/// Creates a Group of Fibers
/// *Caller is responsible for calling free on the allocated slice of Fibers*
/// # Parameters:
/// - `scheduler`: Scehduler,
/// - `slice_funcs`: anytype, but must be a function, like *const fn () void, must return void
/// - `slice_args`: anytype,
/// - `stacks`: [][]align(stack_alignment) u8,
/// Example usage:
/// ```zig
///    var stacks = [_]Stack{ stack1, stack2 };
///    var funcs = .{ groupFunc1, groupFunc2 };
///    const fibers = try scheduler.spawnFibers(
///        &funcs,
///        .{ .{inner_fiber}, .{&x} },
///        &stacks,
///    );
/// ```
/// For more info see [the docs](url)
pub fn spawnFibers(
    scheduler: Scheduler,
    slice_funcs: anytype,
    slice_args: anytype,
    stacks: []Stack,
) ![]*Fiber {
    utils.assert_cm(
        slice_args.len > 1 and slice_funcs.len > 1 and stacks.len > 1,
        "Funcs and List Args ",
    );
    utils.assert_cm(
        slice_args.len == slice_funcs.len and slice_args.len == stacks.len,
        "Spawning Fibers must have and equal number of args, funcs, and stacks",
    );
    utils.assert_cm(
        slice_funcs.len == stacks.len,
        "Spawning Fibers must have and equal number of args, funcs, stacks",
    );

    var fibers = try scheduler.allocator.alloc(*Fiber, slice_funcs.len);
    inline for (slice_funcs, 0..) |f, i| {
        fibers[i] = try createFiber(f, slice_args[i], stacks[i]);
    }

    return fibers;
}

/// Runs Group of Fibers
/// # Parameters:
/// - `scheduler`: Scehduler,
/// - `fibers`: []*Fiber,
/// Example usage:
/// ```zig
///    scheduler.runFibers(fibers)
/// ```
/// For more info see [the docs](url)
pub fn runFibers(_: *Scheduler, fibers: []*Fiber) void {
    var current_fiber: *Fiber = undefined;
    while (maker_state.status() != .AllDone) {
        for (fibers) |f| {
            current_fiber = f;
            if (current_fiber.status != .Done) {
                xresume(current_fiber);
            }
        }
    }
}

// ========================================================================
/// Initalizes a fiber from the stack
/// This function is used internally for the stack allocation for generators
/// do not use the function unless explicilty implementing and custom iterator or generator
/// Please follow the Signature Struct guidelines
/// # Parameters:
/// - `func`: *const fn () anyerror!void,
/// - `stack`: *StackConstruct,
/// - `storage`: ?*anyopaque,
/// Example usage:
/// ```zig
///    initFromStack(sample_fn, &stack, storage)
/// ```
/// For more info see [the docs](url)
pub fn initFromStack(func: *const fn () anyerror!void, stack: *StackConstruct, storage: ?*anyopaque) !*Fiber {
    // Here we push the fiber onto the stack
    const fiber = stack.push(Fiber) catch |err| {
        std.log.err("Stack Fiber push error {any}\n", .{err});
        return err;
    };
    // Here we create a new frame
    const base_frame = base.Frame.init(&(Fiber.run), stack.remaining()) catch |err| {
        std.log.err("Could not init Frame, stack overflow {any}\n", .{err});
        return err;
    };
    fiber.* = Fiber{
        .func = func,
        .f_frame = base_frame,
        .storage = storage,
        .id = maker_state.newFiberId(),
    };
    return fiber;
}

/// Resume function resumes the target coroutine from the localmaker
/// # Parameters:
/// Example usage:
/// ```zig
///    current_fiber.xresume();
/// ```
/// For more info see [the docs](url)
pub fn xresume(target: *Fiber) void {
    maker_state.switchIn(target);
}

/// activate function activates the target coroutine from the localmaker
/// # Parameters:
/// Example usage:
/// ```zig
///    fiber.activate();
/// ```
/// For more info see [the docs](url)
pub fn activate(fiber: *Fiber) void {
    maker_state.switchIn(fiber);
}

/// suspend, suspends the target coroutine;
/// # Parameters:
/// Example usage:
/// ```zig
///    xsuspend();
/// ```
/// For more info see [the docs](url)
pub fn xsuspend() void {
    const callee = maker_state.callee orelse return;
    const caller = callee.caller orelse return;
    // when calling suspend we want to return to the parent
    // right now caller is the parent
    // so we pass the parent but since maker.callee is active the current_fiber will now be the switch
    maker_state.switchOut(caller);
}

/// cancel the current running fiber
/// # Parameters:
/// Example usage:
/// ```zig
///    current_fiber.xcancel();
/// ```
/// For more info see [the docs](url)
pub fn xcancel(target: *Fiber) void {
    maker_state.switchOut(target.caller);
}
// ========================================================================================
// Maker is the local thread
// We set the threadlocal to the maker
// we first call our coroutine with resume, this takes the fiber we want to run as argument
// we then set target fiber caller to the current_fiber
// we do this so that when we switch back and we have a callee stored we can the parent again
// cc = childCoro
// rc = rootCoro
// rc calls resume with cc xresume(cc)
// then we set caller of cc to rc this way we can keep track of our caller
// then we set the callee to cc since this is the running coroutine in the future
// next we call switchTo with rc as the caller and cc as the callee
// then we run the cc func
// within the cc func we call xsuspend
// xsuspend checks if there is a callee in rc which there is
// we then call switchTo with the cc.caller which remember is the rc atm
// we do this since currently cc is running
// then we check the current which is now the callee or cc
// we passed rc as the target to switch to
// and thus we switch from cc to rc now
pub threadlocal var maker_state: Maker = .{};
pub const Maker = struct {
    fiber: Fiber = .{
        .f_status = .Start,
        .func = undefined,
        .f_frame = undefined,
        .id = 0,
    },
    /// The callee is the fiber that is currently running
    callee: ?*Fiber = null,
    fiber_count: Atomic(usize) = Atomic(usize).init(1),

    pub fn status(maker: *@This()) SchedulerStatus {
        if (maker.fiber_count.load(.seq_cst) == 0) {
            return SchedulerStatus.AllDone;
        }
        return SchedulerStatus.Running;
    }

    // We need to check when other courotines have been created then we need to decrement the fiber_count
    pub fn newFiberId(maker: *@This()) usize {
        return maker.fiber_count.fetchAdd(1, .seq_cst);
    }

    pub fn switchIn(maker: *@This(), target: *Fiber) void {
        utils.assert_cm(target.f_status != Status.Done, "Cannot resume an already completed coroutine");
        maker.switchTo(target, true);
    }

    // Switch out switches out the current running callee back to themaker
    pub fn switchOut(maker: *@This(), target: *Fiber) void {
        maker.switchTo(target, false);
    }

    // SwitchIn (xresume)
    // maker -> starts running
    // call switchIn(fiber)
    // grab current -> maker.fiber since callee is null
    // set current -> suspended
    // set the caller of the target fiber to current_fiber
    // set targt.Status to Active
    // set the callee to target
    // switch Stacks from current fiber to target
    // frame is the stack frame run(*Frame, *Frame);
    //
    // SwitchOut (xsuspend)
    // current_fiber = maker.callee
    // opposite of above
    fn switchTo(maker: *@This(), target: *Fiber, set_caller: bool) void {
        // Here we grab the current running coroutine
        const current_fiber = maker.current();
        // std.debug.print("Current Fiber {any}, Target fiber {any}\n", .{ current_fiber.id, target.id });
        if (current_fiber == target) {
            std.debug.print("Cannot switch to same fiber\n", .{});
            return;
        }
        if (current_fiber.f_status != .Done) current_fiber.f_status = .Suspended;
        // we set the target.caller to the current runningfiber
        if (set_caller) target.caller = current_fiber;
        target.f_status = .Active;
        // then we set the callee to the target
        maker.callee = target;
        // then we call the current_fiber to switch to the target
        // std.debug.print("Calling switchTo {any}\n", .{target.id});
        current_fiber.f_frame.switchTo(&target.f_frame);
    }

    fn current(maker: *@This()) *Fiber {
        if (maker.callee) |callee| {
            // std.debug.print("Returning maker callee {any}\n", .{callee.id});
            return callee;
        } else {
            // std.debug.print("Returning callee {any}\n", .{maker.fiber.id});
            return &maker.fiber;
        }
    }

    /// Returns the storage of the currently running coroutine
    pub fn currentStorage(self: *@This(), comptime T: type) *T {
        return self.callee.?.getStorage(T);
    }
};

fn counterFunc() !void {
    while (true) {
        std.debug.print("Counter Func {any}\n", .{counter});
        counter += 1;
        xsuspend();
    }
    // x.* += 3;
    // xsuspend();
    // x.* += 5;
}

var counter: usize = 0;

var payload: []u8 = undefined;
fn handle(pos: *usize) !void {
    while (pos.* < payload.len) {
        // Calculate how much we can fit in the buffer
        const remaining = payload.len - pos.*;
        const buffer_capacity = 4096;
        const chunk_size = @min(remaining, buffer_capacity);

        pos.* += chunk_size;
        xsuspend();
    }
    std.debug.print("Counter Func {any}\n", .{counter});
    counter += 1;
}

pub fn makePayload(size: usize) ![]u8 {
    const allocator = std.heap.page_allocator;
    const buf = try allocator.alloc(u8, size);
    @memset(buf, 'x');
    return buf;
}

test "simple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var scheduler: Scheduler = undefined;
    try scheduler.init(allocator);
    payload = try allocator.alloc(u8, (10000000));
    @memcpy(payload[0..(10000000)], try makePayload(10000000));

    // Start the callee coroutine

    var fibers: []*Fiber = allocator.alloc(*Fiber, 10) catch unreachable;
    var stacks: []Stack = allocator.alloc(Stack, 10) catch unreachable;

    for (0..10) |i| {
        const stack = try scheduler.stackAlloc(null);
        const pos = allocator.create(usize) catch unreachable;
        pos.* = 0;
        const current_fiber = try createFiber(handle, .{pos}, stack);
        fibers[i] = current_fiber;
        stacks[i] = stack;
    }

    while (counter < 10) {
        for (fibers[0..10]) |f| {
            if (f.status() != .Done) {
                xresume(f);
            }
        }
    }

    // try std.testing.expectEqual(counter, 1);
    // // Child yields back here
    // xresume(&current_fiber);
    // try std.testing.expectEqual(counter, 4);
    // xresume(&current_fiber);
    // try std.testing.expectEqual(counter, 9);
    //
    // try std.testing.expectEqual(current_fiber.status(), .Done);
}
//
// fn iterFn(counter: *usize) void {
//     while (true) {
//         counter.* += 1;
//         _ = Iter.xyield(counter);
//     }
// }
// const Iter = Signature.fromFunc(iterFn, .{ .YieldT = *usize, .InjectT = *usize });
//
// test "iterator" {
//     const allocator = std.testing.allocator;
//     var scheduler: Scheduler = undefined;
//     try scheduler.init(allocator);
//     const stack = try scheduler.stackAlloc(null);
//     defer allocator.free(stack);
//
//     var counter: usize = 0;
//     var fiber = try Iter.init(.{&counter}, stack);
//     var yielded: *usize = undefined;
//     yielded = Iter.xnext(fiber, &counter);
//     try std.testing.expectEqual(yielded.*, 1);
//     yielded = Iter.xnext(fiber, &counter);
//     try std.testing.expectEqual(yielded.*, 2);
//     yielded = Iter.xnext(fiber, &counter);
//     try std.testing.expectEqual(yielded.*, 3);
//     _ = Iter.xnextEnd(fiber, &counter);
//     try std.testing.expectEqual(fiber.status(), .Done);
// }
//
// fn innerFiber() !void {
//     print("Calling Inner fiber\n", .{});
// }
//
// fn groupFunc1(inner_fiber: *Fiber) !void {
//     print("Calling groupFunc1\n", .{});
//     xresume(inner_fiber);
//     xsuspend();
//     print("Calling Again groupFunc1\n", .{});
// }
//
// fn groupFunc2(_: *usize) !void {
//     print("Calling groupFunc2\n", .{});
//     xsuspend();
//     print("Calling Again groupFunc2\n", .{});
// }
//
// const type_func = *const fn () void;
// test "spawn group of fibers with inner fiber" {
//     const allocator = std.testing.allocator;
//     var scheduler: Scheduler = undefined;
//     try scheduler.init(allocator);
//     const inner_stack = try scheduler.stackAlloc(null);
//     defer allocator.free(inner_stack);
//     const inner_fiber = try createFiber(innerFiber, .{}, inner_stack);
//
//     const stack1 = try scheduler.stackAlloc(null);
//     defer allocator.free(stack1);
//     const stack2 = try scheduler.stackAlloc(null);
//     defer allocator.free(stack2);
//
//     var x: usize = 0;
//     var stacks = [_]Stack{ stack1, stack2 };
//     // This is for looping through functions no need to call the type
//     var funcs = .{ groupFunc1, groupFunc2 };
//     const fibers = try scheduler.spawnFibers(
//         &funcs,
//         .{ .{inner_fiber}, .{&x} },
//         &stacks,
//     );
//     defer allocator.free(fibers);
//
//     scheduler.runFibers(fibers);
// }
//
// fn threadFunc() !void {
//     print("Running thread func\n", .{});
// }
//
// test "spawning threads" {
//     const allocator = std.testing.allocator;
//     var scheduler: Scheduler = undefined;
//     try scheduler.init(allocator);
//     const opts = ThreadRipper.Options{
//         .max_threads = @intCast(std.Thread.getCpuCount() catch 6),
//         .arena = allocator,
//     };
//     try scheduler.initPool(opts);
//     try scheduler.initGK();
//     defer scheduler.gate_keeper.deinit();
//     for (0..10) |_| {
//         try scheduler.atm_pool.fork(&scheduler.gate_keeper, threadFunc, .{});
//     }
//     scheduler.atm_pool.waitAndWork(&scheduler.gate_keeper);
// }
//
// test "unbufferedChan" {
//     // create channel of u8
//     const T = Channel.Chan(u8);
//     var chan = T.init(std.testing.allocator);
//     defer chan.deinit();
//
//     // spawn thread that immediately waits on channel
//     const thread = struct {
//         fn func(c: *T) !void {
//             const val = try c.recv();
//             std.debug.print("{d} Thread Received {d}\n", .{ std.time.milliTimestamp(), val });
//         }
//     };
//     const t = try std.Thread.spawn(.{}, thread.func, .{&chan});
//     defer t.join();
//
//     const val: u8 = 10;
//     std.debug.print("{d} Main Sending {d}\n", .{ std.time.milliTimestamp(), val });
//     try chan.send(val);
// }
