const std = @import("std");
const builtin = @import("builtin");

const ArchInfo = struct {
    num_registers: usize,
    jump_idx: usize,
    assembly: []const u8,
};

const arch_info: ArchInfo = switch (builtin.cpu.arch) {
    .aarch64 => .{
        .num_registers = 20,
        .jump_idx = 19,
        .assembly = @embedFile("asm/coro_aarch64.s"),
    },
    .x86_64 => switch (builtin.os.tag) {
        .windows => .{
            .num_registers = 32,
            .jump_idx = 30,
            .assembly = @embedFile("asm/coro_x86_64_windows.s"),
        },
        else => .{
            .num_registers = 8,
            .jump_idx = 6,
            .assembly = @embedFile("asm/coro_x86_64.s"),
        },
    },
    .riscv64 => .{
        .num_registers = 25,
        .jump_idx = 24,
        .assembly = @embedFile("asm/coro_riscv64.s"),
    },
    else => @compileError("Unsupported cpu architecture"),
};

pub const stack_alignment = std.mem.Alignment.@"16";

// This x0 and x1
extern fn asm_stack_swap(current: *Frame, target: *Frame) void;
comptime {
    asm (arch_info.assembly);
}

pub const Frame = packed struct {
    stack_pointer: usize,

    const Self = @This();
    const Func = *const fn (
        from: *Frame,
        self: *Frame,
    ) callconv(.c) noreturn;

    // This Function takes a func and a stack
    // we check that the Func is u8
    // register space is a space for saving the cpu registers
    // we resume by restoring all the registers from the register space
    // one of these registers is 19 the instruction ptr
    // program counter
    // we load the stack then we jump to the lr program counter and set out func to it
    pub fn init(func: Func, stack: []align(stack_alignment.toByteUnits()) u8) !Self {
        if (@sizeOf(usize) != 8) @compileError("usize expected to take 8 bytes");
        if (@sizeOf(*Func) != 8) @compileError("function pointer expected to take 8 bytes");
        // We create the number of bytes needed for the stack
        const register_bytes = arch_info.num_registers * 8;
        if (register_bytes > stack.len) return error.StackToSmall;
        const register_space = stack[stack.len - register_bytes ..];
        // then we grab the space since the stack length is 1024
        // function ptr
        const jump_ptr: *Func = @ptrCast(@alignCast(&register_space[arch_info.jump_idx * 8]));
        jump_ptr.* = func;
        return .{ .stack_pointer = @intFromPtr(register_space.ptr) };
    }

    /// Switch to takes a coro and a target coro to switch to
    pub inline fn switchTo(
        self: *Self, // Coroutine to suspend (current)
        target: *Self, // Coroutine to resume (new target)
    ) void {
        asm_stack_swap(self, target);
    }
};
