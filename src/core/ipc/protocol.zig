const std = @import("std");
const agent_types = @import("../agent/types.zig");

pub const protocol_version: u16 = 1;

pub const MessageKind = enum(u16) {
    hello = 1,
    bootstrap_task = 2,
    task_receipt = 3,
    task_state = 4,
    cancel_task = 5,
};

pub const FrameHeader = extern struct {
    version: u16,
    kind: MessageKind,
    flags: u16,
    payload_len: u32,
    correlation_id: u64,
};

pub const BootstrapTaskRequest = extern struct {
    title_len: u32,
};

pub const TaskReceiptFrame = extern struct {
    task_id_hi: u64,
    task_id_lo: u64,
    state: agent_types.TaskState,
};

/// Encodes the static hello frame header.
/// @example
/// const header = helloHeader();
pub fn helloHeader() FrameHeader {
    return .{
        .version = protocol_version,
        .kind = .hello,
        .flags = 0,
        .payload_len = 0,
        .correlation_id = 0,
    };
}

/// Converts a task id into a portable two-u64 representation.
/// @example
/// const frame = toReceipt(receipt);
pub fn toReceipt(receipt: agent_types.TaskReceipt) TaskReceiptFrame {
    return .{
        .task_id_hi = @truncate(receipt.task_id >> 64),
        .task_id_lo = @truncate(receipt.task_id),
        .state = receipt.state,
    };
}
