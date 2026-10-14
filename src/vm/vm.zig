const std = @import("std");
const builtin = @import("builtin");

const Value = @import("../value/value.zig").Value;
const Program = @import("../compile/program.zig").Program;
const OpCode = @import("../compile/program.zig").OpCode;

const call_mode: std.builtin.CallModifier = if (builtin.mode != .Debug or builtin.zig_backend == .stage2_llvm)
    .always_tail
else
    .auto;

pub const VMError = error{
    DivisionByZero,
    TypeMismatch,
    StackOverflow,
    InvalidOpcode,
};

// pub const Context = struct {
//     vm: *VM,
//     target_fp: usize,
// };

pub const Context = packed struct {
    vm_ptr: usize, // Passed in rdx
    target_fp: usize,
    self: Value = Value.None, // Passed in rcx
    super_offset: u32 = 0, // Passed in r8 (low 32 bits)
    depth: u32 = 0, // Passed in r8 (high 32 bits)
    // (or target_fp: u32 if you also want it here)

    pub inline fn init(v: *VM, target_fp: usize) Context {
        return .{
            .vm_ptr = @intFromPtr(v),
            .target_fp = target_fp,
        };
    }

    pub inline fn vm(self: Context) *VM {
        return @ptrFromInt(self.vm_ptr);
    }
};

const Handler = *const fn (pc: [*]const u8, sp: [*]Value, ctx: Context) Value;

const dispatch_table: [256]Handler = init_table: {
    var table: [256]Handler = undefined;

    // Fill the table with a crash handler to catch invalid bytecode
    for (&table) |*handler| {
        handler.* = opInvalid;
    }

    table[@intFromEnum(OpCode.RETURN)] = opReturn;
    // table[@intFromEnum(OpCode.ADD)] = opAdd;

    table[@intFromEnum(OpCode.NUMBER_8)] = opNumber_8;
    table[@intFromEnum(OpCode.NUMBER_16)] = opNumber_16;
    table[@intFromEnum(OpCode.NUMBER)] = opNumber;

    table[@intFromEnum(OpCode.BINARY_MINUS)] = opBinaryMinus;

    table[@intFromEnum(OpCode.VAR_8)] = opVar_8;
    table[@intFromEnum(OpCode.VAR)] = opVar;

    table[@intFromEnum(OpCode.POP_LOCALS_8)] = opPopLocals_8;
    table[@intFromEnum(OpCode.POP_LOCALS)] = opPopLocals;

    // table[@intFromEnum(OpCode.ARRAY)] = opArray;

    break :init_table table;
};

fn opInvalid(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    _ = sp;
    _ = ctx;
    if (std.enums.fromInt(OpCode, pc[0])) |c| {
        std.debug.panic("Invalid opcode: 0x{x} ({s}) at PC: {*}\n", .{ pc[0], @tagName(c), pc });
    } else {
        std.debug.panic("Invalid opcode: 0x{x} (unknown) at PC: {*}\n", .{ pc[0], pc });
    }
}

const CallFrame = struct {
    ip: usize,
    bp: usize,
    // Add other fields: scope_bp, scope_id, etc.
};

pub const VM = struct {
    program: *Program, // Replaces prog.Instructions slice

    err: ?VMError = null,

    stack: [1024]Value = undefined,
    stack_top: usize = 0,

    frames: [256]CallFrame = undefined,
    fp: usize = 0,

    // The "Active" state, kept in registers for speed
    ip: usize = 0,
    bp: usize = 0,

    allocator: std.mem.Allocator,

    // Returns the final value when execution completely finishes
    // pub fn run(self: *VM) !Value {
    //     self.fp = 1;
    //     self.frames[0] = .{ .ip = 0, .bp = 0 }; // Dummy base frame

    //     try self.runLoop(0); // Run until the base frame returns

    //     return self.stack[self.stack_top - 1];
    // }

    pub fn execute(self: *VM, target_fp: usize) VMError!Value {
        // const ctx = Context{
        //     .vm = self,
        //     .target_fp = target_fp,
        // };

        const ctx = Context.init(self, target_fp);

        self.fp = 1;
        self.bp = 0;
        self.frames[0] = .{ .ip = 0, .bp = 0 };

        // Setup initial state pointers
        const initial_pc = self.program.bytecode.ptr;
        // const initial_sp = &self.stack[0];
        const initial_sp = self.stack[0..].ptr;
        const initial_op = initial_pc[0];

        // The "loop" is initiated by manually firing the first instruction.
        // The handlers will tail-call each other until OP_RETURN is hit.
        const result = @call(.auto, dispatch_table[initial_op], .{ initial_pc, initial_sp, ctx });
        if (self.err) |err| {
            return err;
        }
        return result;
    }

    // pub fn fail(self: *VM, current_pc: [*]const u8, comptime fmt: []const u8, args: anytype) void {
    //     self.err = error.RuntimeError;

    //     var written: usize = 0;

    //     // 1. Error header
    //     const msg = std.fmt.bufPrint(self.err_buf[written..], "RUNTIME ERROR: " ++ fmt ++ "\n", args) catch return;
    //     written += msg.len;

    //     // 2. Immediate crash site
    //     const cur_ip = @intFromPtr(current_pc) - @intFromPtr(self.program.bytecode.ptr);
    //     const cur_loc = self.program.getLocation(cur_ip);
    //     const cur_line = std.fmt.bufPrint(self.err_buf[written..], "\t{s}:{d}\t{s}\n", .{
    //         cur_loc.file, cur_loc.line, cur_loc.func_name,
    //     }) catch return;
    //     written += cur_line.len;

    //     // 3. Walk active caller frames (from innermost to outermost)
    //     var i = self.fp;
    //     while (i > 0) : (i -= 1) {
    //         const frame = self.frames[i - 1];
    //         const loc = self.program.getLocation(frame.ip);
    //         const frame_line = std.fmt.bufPrint(self.err_buf[written..], "\t{s}:{d}\t{s}\n", .{
    //             loc.file, loc.line, frame.func_name,
    //         }) catch return;
    //         written += frame_line.len;
    //     }

    //     self.err_msg = self.err_buf[0..written];
    // }
};

fn opReturn(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    _ = pc;
    _ = ctx;
    // Break the tail-call chain and return the final value to the host
    return (sp - 1)[0];

    // if (self.fp == ctx.target_fp) {
    //     self.stack[self.stack_top] = result;
    //     self.stack_top += 1;
    //     return; // Exit the nested runLoop!
    // }

    // // Replace top stack value with result and continue
    // self.stack[self.stack_top - 1] = result;
}

fn opNumber_8(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const raw: i8 = @bitCast(pc[1]);
    const num: f64 = @floatFromInt(raw);

    sp[0] = Value.makeNumber(num);

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u8);
    const next_sp = sp + 1;

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opNumber_16(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const raw = std.mem.readInt(u16, pc[1..3], .little);
    const num: f64 = @floatFromInt(@as(i16, @bitCast(raw)));

    sp[0] = Value.makeNumber(num);

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u16);
    const next_sp = sp + 1;

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opNumber(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const raw = std.mem.readInt(u64, pc[1..9], .little);

    sp[0] = Value.makeNumber(@bitCast(raw));

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u64);
    const next_sp = sp + 1;

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

// OP_ADD (0x02): Pops two values, adds them, pushes result.
// Length: 1 byte.
fn opBinaryAdd(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    // 1. Execute logic (pop 2, push 1)
    const right = sp[-1];
    const left = sp[-2];

    // Note: In a real VM you would untag the NaN-boxed values here.
    // We assume raw integers for this example.
    sp[-2] = left + right;

    // 2. Advance state
    const next_pc = pc + 1;
    const next_sp = sp - 1; // Stack shrunk by 1

    // 3. Decode next opcode and tail call
    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opBinaryMinus(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    // 1. Execute logic (pop 2, push 1)
    const right = (sp - 1)[0];
    const left = (sp - 2)[0];

    if (!left.isNumber() or !right.isNumber()) {
        ctx.vm().err = VMError.TypeMismatch;
        // TODO: save err ctx?
        // ctx.vm.err_msg = "....";
        return Value.None;
    }

    const res = Value.makeNumber(left.number() - right.number());
    (sp - 2)[0] = res;

    const next_pc = pc + 1;
    const next_sp = sp - 1;

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opVar_8(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const local_idx = pc[1];

    sp[0] = ctx.vm().stack[ctx.vm().bp + local_idx];

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u8);
    const next_sp = sp + 1;

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opVar(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const local_idx = std.mem.readInt(u32, pc[1..5], .little);

    sp[0] = ctx.vm().stack[ctx.vm().bp + local_idx];

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u32);
    const next_sp = sp + 1;

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opPopLocals_8(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const count = pc[1];

    const result = (sp - 1)[0];

    const next_sp = sp - count;
    (next_sp - 1)[0] = result;

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u8);

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

fn opPopLocals(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
    const count = std.mem.readInt(u32, pc[1..5], .little);

    const result = (sp - 1)[0];

    const next_sp = sp - count;
    (next_sp - 1)[0] = result;

    const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u32);

    const next_op = next_pc[0];
    return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
}

// fn opArray(pc: [*]const u8, sp: [*]Value, ctx: Context) Value {
//     const count = std.mem.readInt(u32, pc[1..5], .little);

//     const res = try ctx.vm.allocator.alloc(Value, count);
//     for (0..count) |i| {
//         // const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u32);
//         // const next_op = next_pc[0];
//         // try @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
//     }

//     const result = (sp - 1)[0];

//     const next_sp = sp - count;
//     (next_sp - 1)[0] = result;

//     const next_pc = pc + @sizeOf(OpCode) + @sizeOf(u32);

//     const next_op = next_pc[0];
//     return @call(call_mode, dispatch_table[next_op], .{ next_pc, next_sp, ctx });
// }

pub const Visibility = enum(u2) {
    hidden = 0, // `::`
    visible = 1, // `:`
    force_visible = 2, // `:::`
};

// This struct is guaranteed by the Zig compiler to be exactly 1 byte (u8)
pub const FieldMeta = packed struct(u8) {
    has_plus: bool, // Bit 0
    visibility: u2, // Bits 1 and 2
    _padding: u5 = 0, // Bits 3-7 (Reserved for future use)
};

// pub fn execute(chunk: []const u8, constants: []const Value) !Value {
//     var stack: [1024]Value = undefined;
//     var stack_top: usize = 0;
//     var ip: usize = 0;

//     // while (self.frame_count > target_depth) // run to a specific depth

//     while (true) {
//         const instruction = chunk[ip];
//         ip += 1; // Advance past the opcode

//         switch (@as(OpCode, @enumFromInt(instruction))) {
//             else => {
//                 @panic("unknown opcode executed");
//             },

//             // Takes NO operands (1 byte total)
//             .ADD => {
//                 const right = stack[stack_top - 1];
//                 const left = stack[stack_top - 2];
//                 stack_top -= 1;
//                 stack[stack_top - 1] = Value.makeNumber(left.number() + right.number()); // TODO: need to add all different types together here
//             },

//             // Takes a 1-byte operand (2 bytes total)
//             .CONST_8 => {
//                 const const_idx = chunk[ip]; // Read the 8-bit operand
//                 ip += 1; // Advance past the operand

//                 stack[stack_top] = constants[const_idx];
//                 stack_top += 1;
//             },

//             // Takes a 2-byte operand (3 bytes total)
//             .JUMP_FWD_16 => {
//                 // Read a 16-bit integer from the byte stream
//                 const offset_high = @as(u16, chunk[ip]) << 8;
//                 const offset_low = @as(u16, chunk[ip + 1]);
//                 const offset = offset_high | offset_low;

//                 ip += 2; // Advance past the operand
//                 ip += offset; // Perform the jump
//             },
//         }
//     }
// }

// const CallFrame = struct {
//     ip: usize,
//     bp: usize,
//     // Add other fields: scope_bp, scope_id, etc.
// };

// const VM = struct {
//     chunk: []const u8, // Replaces prog.Instructions slice
//     constants: []const Value, // Replaces prog.Numbers, prog.Strings

//     stack: [1024]Value = undefined,
//     stack_top: usize = 0,

//     frames: [256]CallFrame = undefined,
//     fp: usize = 0,

//     // The "Active" state, kept in registers for speed
//     ip: usize = 0,
//     bp: usize = 0,

//     // Returns the final value when execution completely finishes
//     pub fn run(self: *VM) !Value {
//         self.fp = 1;
//         self.frames[0] = .{ .ip = 0, .bp = 0 }; // Dummy base frame

//         try self.runLoop(0); // Run until the base frame returns

//         return self.stack[self.stack_top - 1];
//     }

//     // The core execution engine!
//     fn runLoop(self: *VM, target_fp: usize) !void {

//         // Cache the chunk pointer locally to help LLVM optimize array access
//         const bytecode = self.chunk;

//         while (true) {
//             const instruction = bytecode[self.ip];
//             self.ip += 1;

//             switch (@as(OpCode, @enumFromInt(instruction))) {
//                 .ADD => {
//                     const right = self.stack[self.stack_top - 1];
//                     const left = self.stack[self.stack_top - 2];
//                     self.stack_top -= 1;

//                     // Assuming they are numbers...
//                     self.stack[self.stack_top - 1] = Value.makeNumber(left.number() + right.number());
//                 },

//                 .CONST_8 => {
//                     const const_idx = bytecode[self.ip]; // Read operand
//                     self.ip += 1;

//                     self.stack[self.stack_top] = self.constants[const_idx];
//                     self.stack_top += 1;
//                 },

//                 .MAKE_THUNK => {
//                     // E.g., operand is how many bytes the thunk spans
//                     const offset_high = @as(u16, bytecode[self.ip]) << 8;
//                     const offset_low = @as(u16, bytecode[self.ip + 1]);
//                     const offset = offset_high | offset_low;
//                     self.ip += 2;

//                     const thunk_val = Value.makeThunk(self.ip); // ip points to start of thunk
//                     self.stack[self.stack_top] = thunk_val;
//                     self.stack_top += 1;

//                     // Jump OVER the thunk body so we don't execute it right now!
//                     self.ip += offset;
//                 },

//                 .FORCE => {
//                     const val = self.stack[self.stack_top - 1];
//                     if (val.typeOf() == .Thunk) {
//                         // 1. Save current state
//                         self.frames[self.fp] = .{ .ip = self.ip, .bp = self.bp };
//                         self.fp += 1;

//                         // 2. Set active state to the Thunk
//                         self.ip = val.asThunk().target_ip;
//                         self.bp = self.stack_top;

//                         // Loop continues!
//                     }
//                 },

//                 .RETURN => {
//                     const result = self.stack[self.stack_top - 1];

//                     self.stack_top = self.bp; // Clear locals

//                     self.fp -= 1;
//                     const prev_frame = self.frames[self.fp];

//                     // Restore state
//                     self.ip = prev_frame.ip;
//                     self.bp = prev_frame.bp;

//                     if (self.fp == target_fp) {
//                         self.stack[self.stack_top] = result;
//                         self.stack_top += 1;
//                         return; // Exit the nested runLoop!
//                     }

//                     // Replace top stack value with result and continue
//                     self.stack[self.stack_top - 1] = result;
//                 },
//             }
//         }
//     }
// };
