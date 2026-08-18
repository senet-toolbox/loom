const std = @import("std");

// Wrapper that pairs an unmanaged MemoryPool with its allocator
pub fn ManagedMemoryPool(comptime T: type) type {
    return struct {
        pool: std.heap.MemoryPool(T) = .empty,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit(self.allocator);
        }

        pub fn create(self: *Self) std.mem.Allocator.Error!*T {
            return self.pool.create(self.allocator);
        }

        pub fn destroy(self: *Self, ptr: *T) void {
            self.pool.destroy(ptr);
        }
    };
}

// Wrapper that pairs an unmanaged AutoHashMap with its allocator
pub fn ManagedAutoHashMap(comptime K: type, comptime V: type) type {
    return struct {
        map: std.AutoHashMapUnmanaged(K, V) = .empty,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit(self.allocator);
        }

        pub fn put(self: *Self, key: K, value: V) std.mem.Allocator.Error!void {
            return self.map.put(self.allocator, key, value);
        }

        pub fn get(self: *Self, key: K) ?V {
            return self.map.get(key);
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            return self.map.getPtr(key);
        }

        pub fn remove(self: *Self, key: K) bool {
            return self.map.remove(key);
        }

        pub fn contains(self: *Self, key: K) bool {
            return self.map.contains(key);
        }

        pub fn count(self: *Self) usize {
            return self.map.count();
        }
        pub fn iterator(self: *Self) std.AutoHashMapUnmanaged(K, V).Iterator {
            return self.map.iterator();
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.map.clearRetainingCapacity();
        }
    };
}
