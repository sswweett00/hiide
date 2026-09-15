/// Lock-free bounded MPMC queue (Vyukov algorithm) plus a parking wrapper.
///
/// Spec §1.7 targets sub-2µs p99 enqueue/dequeue for the scheduler hot path, so
/// the ready queue must not take a mutex on the fast path. `BoundedQueue` is the
/// wait-free-on-success ring; `WorkQueue` layers a condition variable used only
/// when a worker would otherwise spin idle.
const std = @import("std");
const compat = @import("../../compat.zig");

pub const QueueError = error{
    CapacityNotPowerOfTwo,
    CapacityTooSmall,
    OutOfMemory,
};

/// Bounded multi-producer / multi-consumer ring buffer.
/// Capacity must be a power of two so the index wrap is a mask operation.
pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cell = struct {
            sequence: std.atomic.Value(usize),
            data: T,
        };

        buffer: []Cell,
        mask: usize,
        enqueue_pos: std.atomic.Value(usize) align(std.atomic.cache_line),
        dequeue_pos: std.atomic.Value(usize) align(std.atomic.cache_line),

        /// Allocates a ring with `slots` entries (power of two, min 2).
        /// @example
        /// var q = try BoundedQueue(u32).init(allocator, 1024);
        pub fn init(allocator: std.mem.Allocator, slots: usize) QueueError!Self {
            if (slots < 2) return QueueError.CapacityTooSmall;
            if (!std.math.isPowerOfTwo(slots)) return QueueError.CapacityNotPowerOfTwo;

            const buffer = try allocator.alloc(Cell, slots);
            for (buffer, 0..) |*cell, i| {
                cell.sequence = std.atomic.Value(usize).init(i);
                cell.data = undefined;
            }

            return .{
                .buffer = buffer,
                .mask = slots - 1,
                .enqueue_pos = std.atomic.Value(usize).init(0),
                .dequeue_pos = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
            self.* = undefined;
        }

        /// Attempts to enqueue; returns false when the ring is full.
        /// @example
        /// if (!q.tryPush(task)) return error.ExecutorSaturated;
        pub fn tryPush(self: *Self, item: T) bool {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

                if (diff == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    cell.data = item;
                    cell.sequence.store(pos +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    return false; // full
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }

        /// Attempts to dequeue; returns null when the ring is empty.
        /// @example
        /// const task = q.tryPop() orelse return;
        pub fn tryPop(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);
            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos +% 1));

                if (diff == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    const item = cell.data;
                    cell.sequence.store(pos +% self.mask +% 1, .release);
                    return item;
                } else if (diff < 0) {
                    return null; // empty
                } else {
                    pos = self.dequeue_pos.load(.monotonic);
                }
            }
        }

        /// Approximate number of queued items (racy under concurrency).
        /// @example
        /// const depth = q.len();
        pub fn len(self: *const Self) usize {
            const head = self.enqueue_pos.load(.acquire);
            const tail = self.dequeue_pos.load(.acquire);
            return head -% tail;
        }

        /// Total slot count.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// True when no items are queued (racy under concurrency).
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }
    };
}

/// Blocking facade over `BoundedQueue`: producers never block, consumers park on
/// a condition variable until work arrives or the queue is closed.
pub fn WorkQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        ring: BoundedQueue(T),
        mutex: compat.Mutex = .init,
        cond: compat.Condition = .init,
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        waiting: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        /// Allocates a work queue with `slots` entries (power of two).
        /// @example
        /// var wq = try WorkQueue(Job).init(allocator, 256);
        pub fn init(allocator: std.mem.Allocator, slots: usize) QueueError!Self {
            return .{ .ring = try BoundedQueue(T).init(allocator, slots) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.ring.deinit(allocator);
            self.* = undefined;
        }

        /// Enqueues an item and wakes one parked consumer.
        /// @example
        /// if (!wq.push(job)) return error.ExecutorSaturated;
        pub fn push(self: *Self, item: T) bool {
            if (self.closed.load(.acquire)) return false;
            if (!self.ring.tryPush(item)) return false;
            if (self.waiting.load(.acquire) > 0) {
                self.mutex.lock();
                self.mutex.unlock();
                self.cond.signal();
            }
            return true;
        }

        /// Pops an item, parking until one is available or the queue closes.
        /// Returns null only when the queue is closed and drained.
        /// @example
        /// const job = wq.pop() orelse break;
        pub fn pop(self: *Self) ?T {
            while (true) {
                if (self.ring.tryPop()) |item| return item;
                if (self.closed.load(.acquire)) {
                    // Drain race: an item may have landed between the two checks.
                    return self.ring.tryPop();
                }

                self.mutex.lock();
                _ = self.waiting.fetchAdd(1, .acq_rel);
                // Re-check under the lock to avoid a lost wakeup.
                if (self.ring.isEmpty() and !self.closed.load(.acquire)) {
                    self.cond.timedWait(&self.mutex, 2 * std.time.ns_per_ms);
                }
                _ = self.waiting.fetchSub(1, .acq_rel);
                self.mutex.unlock();
            }
        }

        /// Non-blocking pop.
        /// @example
        /// const maybe = wq.tryPop();
        pub fn tryPop(self: *Self) ?T {
            return self.ring.tryPop();
        }

        /// Closes the queue and wakes every parked consumer.
        /// @example
        /// wq.close();
        pub fn close(self: *Self) void {
            self.mutex.lock();
            self.closed.store(true, .release);
            self.mutex.unlock();
            self.cond.broadcast();
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        pub fn len(self: *const Self) usize {
            return self.ring.len();
        }
    };
}

test "queue: rejects invalid capacities" {
    try std.testing.expectError(QueueError.CapacityTooSmall, BoundedQueue(u8).init(std.testing.allocator, 1));
    try std.testing.expectError(QueueError.CapacityNotPowerOfTwo, BoundedQueue(u8).init(std.testing.allocator, 100));
}

test "queue: fifo ordering for a single producer/consumer" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    try std.testing.expect(q.tryPush(3));
    try std.testing.expectEqual(@as(usize, 3), q.len());

    try std.testing.expectEqual(@as(?u32, 1), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 3), q.tryPop());
    try std.testing.expectEqual(@as(?u32, null), q.tryPop());
}

test "queue: reports full instead of overwriting" {
    var q = try BoundedQueue(u8).init(std.testing.allocator, 2);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    try std.testing.expect(!q.tryPush(3));
    try std.testing.expectEqual(@as(?u8, 1), q.tryPop());
    try std.testing.expect(q.tryPush(3));
}

test "queue: mpmc stress keeps every item exactly once" {
    const producers = 4;
    const per_producer = 2_000;

    var q = try BoundedQueue(u64).init(std.testing.allocator, 1024);
    defer q.deinit(std.testing.allocator);

    var produced = std.atomic.Value(u64).init(0);
    var consumed_sum = std.atomic.Value(u64).init(0);
    var consumed_count = std.atomic.Value(u64).init(0);
    var done = std.atomic.Value(bool).init(false);

    const Producer = struct {
        fn run(queue: *BoundedQueue(u64), base: u64, counter: *std.atomic.Value(u64)) void {
            var i: u64 = 0;
            while (i < per_producer) : (i += 1) {
                const value = base * per_producer + i + 1;
                while (!queue.tryPush(value)) std.atomic.spinLoopHint();
                _ = counter.fetchAdd(value, .acq_rel);
            }
        }
    };

    const Consumer = struct {
        fn run(
            queue: *BoundedQueue(u64),
            sum: *std.atomic.Value(u64),
            count: *std.atomic.Value(u64),
            stop: *std.atomic.Value(bool),
        ) void {
            while (true) {
                if (queue.tryPop()) |value| {
                    _ = sum.fetchAdd(value, .acq_rel);
                    _ = count.fetchAdd(1, .acq_rel);
                    continue;
                }
                if (stop.load(.acquire)) {
                    if (queue.tryPop()) |value| {
                        _ = sum.fetchAdd(value, .acq_rel);
                        _ = count.fetchAdd(1, .acq_rel);
                        continue;
                    }
                    return;
                }
                std.atomic.spinLoopHint();
            }
        }
    };

    var prod_threads: [producers]std.Thread = undefined;
    var cons_threads: [2]std.Thread = undefined;

    for (&cons_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &consumed_sum, &consumed_count, &done });
    }
    for (&prod_threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Producer.run, .{ &q, @as(u64, i), &produced });
    }

    for (&prod_threads) |*t| t.join();
    done.store(true, .release);
    for (&cons_threads) |*t| t.join();

    try std.testing.expectEqual(@as(u64, producers * per_producer), consumed_count.load(.acquire));
    try std.testing.expectEqual(produced.load(.acquire), consumed_sum.load(.acquire));
}

test "work queue: consumers unpark on close" {
    var wq = try WorkQueue(u32).init(std.testing.allocator, 8);
    defer wq.deinit(std.testing.allocator);

    var received = std.atomic.Value(u32).init(0);

    const Consumer = struct {
        fn run(queue: *WorkQueue(u32), counter: *std.atomic.Value(u32)) void {
            while (queue.pop()) |_| {
                _ = counter.fetchAdd(1, .acq_rel);
            }
        }
    };

    var t = try std.Thread.spawn(.{}, Consumer.run, .{ &wq, &received });
    try std.testing.expect(wq.push(1));
    try std.testing.expect(wq.push(2));
    compat.sleep(5 * std.time.ns_per_ms);
    wq.close();
    t.join();

    try std.testing.expectEqual(@as(u32, 2), received.load(.acquire));
}
