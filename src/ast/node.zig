const std = @import("std");

pub const NodeType = enum(u8) {
    None,

    // literals
    String,
    Null,
    True,
    False,
    Number,

    Object,
    Array,
    Local,
    Apply,
    Index,
    Var,
    Function,
    Conditional,
    Import,
    importStr,
    importBin,
    Self,
    SuperIndex,
    In,
    InSuper,
    Error,

    // binary ops
    BinaryAnd,
    BinaryOr,
    BinaryEqual,
    BinaryPlus,
    BinaryMinus,
    BinaryDiv,
    BinaryMult,
    BinaryPercent,
    BinaryBitwiseAnd,
    BinaryBitwiseOr,
    BinaryBitwiseXor,
    BinaryShiftL,
    BinaryShiftR,
    BinaryUnequal,
    BinaryGreater,
    BinaryGreaterEq,
    BinaryLess,
    BinaryLessEq,

    // unary ops
    UnaryNot,
    UnaryMinus,
    UnaryBitwiseNot,
};

pub const FieldVisibility = enum(u8) {
    Hidden,
    Inherit,
    Visible,
};

// 12 Bytes Total
pub const NodeData = extern union {
    // -----------------------------------------------------
    // Nodes using all 3 slots (12 bytes)
    // -----------------------------------------------------
    conditional: extern struct { cond: u32, b_true: u32, b_false: u32 },
    apply: extern struct { target: u32, params_start: u32, param_count: u32 },
    local: extern struct { body: u32, binds_start: u32, binds_count: u32 },
    function: extern struct { body: u32, params_start: u32, param_count: u32 },

    // -----------------------------------------------------
    // Nodes using 2 slots (8 bytes - union pads the rest)
    // -----------------------------------------------------
    binary: extern struct { left: u32, right: u32 },
    index: extern struct { index: u32, target: u32 },
    collection: extern struct { start: u32, count: u32 }, // For Object and Array
    import_file: extern struct { file_id: u32, loc_id: u32 },

    // -----------------------------------------------------
    // Nodes using 1 slot (4 bytes - union pads the rest)
    // -----------------------------------------------------
    unary: extern struct { expr: u32 },
    variable: extern struct { key_id: u32 },
    string: extern struct { key_id: u32 },

    // -----------------------------------------------------
    // The explicitly aligned 64-bit float (12 bytes)
    // -----------------------------------------------------
    number: extern struct {
        value: f64 align(4), // Takes 8 bytes, aligned to a 4-byte boundary
        _unused: u32 = 0, // Fills the last 4 bytes to make the struct 12 bytes
    },

    none: extern struct {},

    // -----------------------------------------------------
    // Raw fallback (Useful for bulk emitting or debugging)
    // -----------------------------------------------------
    raw: extern struct { a: u32, b: u32, c: u32 },
};

pub const Node = extern struct {
    type: NodeType, // 1 byte
    flags: u8 = 0, // 1 byte
    _pad: u16 = 0, // 2 bytes (Keeps the payload aligned to 4 bytes)
    data: NodeData, // 12 bytes
};

// sanity check
comptime {
    std.debug.assert(@sizeOf(NodeData) == 12);
    std.debug.assert(@sizeOf(Node) == 16);
}

pub const AST = struct {
    nodes: []Node,
    side_table: []u32,
    root_id: u32,

    // locations: []NodeContext, // TODO: Build node context
};
