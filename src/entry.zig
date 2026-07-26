const tempora = @import("tempora");
const stat = @import("stat.zig");
const std = @import("std");
const Io = std.Io;

pub const Permission = struct {
    owner: u32,
    group: u32,
    other: u32,
    user_name: []const u8,
    group_name: []const u8,

    fn render(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        var permission = [_]u8{'-'} ** 10;

        decodeModeDigit(permission[1..4], self.owner);
        decodeModeDigit(permission[4..7], self.group);
        decodeModeDigit(permission[7..10], self.other);

        return try std.fmt.allocPrint(alloc, "{s}", .{permission});
    }

    fn decodeModeDigit(slots: []u8, mode: u32) void {
        if (mode == 1) {
            slots[0] = '-';
            slots[1] = '-';
            slots[2] = 'x';
        } else if (mode == 2) {
            slots[0] = '-';
            slots[1] = 'w';
            slots[2] = '-';
        } else if (mode == 3) {
            slots[0] = 'w';
            slots[1] = '-';
            slots[2] = 'x';
        } else if (mode == 4) {
            slots[0] = 'r';
            slots[1] = '-';
            slots[2] = '-';
        } else if (mode == 5) {
            slots[0] = 'r';
            slots[1] = '-';
            slots[2] = 'x';
        } else if (mode == 6) {
            slots[0] = 'r';
            slots[1] = 'w';
            slots[2] = '-';
        } else if (mode == 7) {
            slots[0] = 'r';
            slots[1] = 'w';
            slots[2] = 'x';
        }
    }
};

pub const EntryField = enum(usize) { permission, size, user_name, group_name, created_timestamp, modified_timestamp, name };

pub const Entry = struct {
    kind: Io.File.Kind,
    size: u64,
    permission: Permission,
    created_timestamp: ?Io.Timestamp,
    modified_timestamp: ?Io.Timestamp,
    accessed_timestamp: ?Io.Timestamp,
    name: []const u8,
    target_link_name: ?[]const u8 = null,

    pub fn toCells(self: @This(), alloc: std.mem.Allocator, human_readable: bool) ![][]const u8 {
        const tz = tempora.Timezone.utc;

        const fields = std.EnumArray(EntryField, []const u8).init(.{
            .permission = try self.permission.render(alloc),
            .size = try self.renderSize(alloc, human_readable),
            .user_name = self.permission.user_name,
            .group_name = self.permission.group_name,
            .created_timestamp = try renderDate(alloc, tz, self.created_timestamp, human_readable),
            .modified_timestamp = try renderDate(alloc, tz, self.modified_timestamp, human_readable),
            .name = try self.renderName(alloc),
        });

        return try alloc.dupe([]const u8, &fields.values);
    }

    pub fn renderName(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
        return if (self.target_link_name) |t|
            try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ self.name, t })
        else
            self.name;
    }

    pub fn renderSize(self: @This(), alloc: std.mem.Allocator, human_readable: bool) ![]const u8 {
        return try renderFileSize(alloc, human_readable, self.size);
    }

    pub fn renderDate(alloc: std.mem.Allocator, tz: tempora.Timezone, timestamp: ?std.Io.Timestamp, human_readable: bool) ![]const u8 {
        if (timestamp) |t| {
            if (!human_readable) {
                return try std.fmt.allocPrint(alloc, "{d}", .{t.toMilliseconds()});
            }

            const date_time = tempora.Date_Time.With_Offset.from_timestamp(t, &tz);
            const date_time_buf = try std.fmt.allocPrint(alloc, "{f}", .{date_time.fmt("DD MMM YYYY HH:mm:ss")});

            return date_time_buf;
        }

        return "";
    }
};

pub const SortField = enum { name, size, created, modified, accessed };

pub const Sort = struct {
    field: SortField,
    reverse: bool,
    entries: []Entry,

    pub fn init(field: SortField, reverse: bool, entries: []Entry) Sort {
        return .{ .field = field, .reverse = reverse, .entries = entries };
    }

    fn compareByField(comptime field: SortField, lhs: Entry, rhs: Entry) std.math.Order {
        return switch (field) {
            .name => std.ascii.orderIgnoreCase(lhs.name, rhs.name),
            .size => std.math.order(lhs.size, rhs.size),
            .created => compareTimestamp(lhs.created_timestamp, rhs.created_timestamp),
            .modified => compareTimestamp(lhs.modified_timestamp, rhs.modified_timestamp),
            .accessed => compareTimestamp(lhs.accessed_timestamp, rhs.accessed_timestamp),
        };
    }

    fn compareTimestamp(lhs: ?Io.Timestamp, rhs: ?Io.Timestamp) std.math.Order {
        if (lhs == null and rhs == null) return .eq;
        if (lhs == null) return .lt;
        if (rhs == null) return .gt;

        return std.math.order(lhs.?.nanoseconds, rhs.?.nanoseconds);
    }

    fn lessThanBy(comptime field: SortField, comptime reverse: bool) fn (void, Entry, Entry) bool {
        return struct {
            fn inner(_: void, lhs: Entry, rhs: Entry) bool {
                const order = compareByField(field, lhs, rhs);
                return if (reverse) order == .gt else order == .lt;
            }
        }.inner;
    }

    pub fn sort(self: @This()) void {
        switch (self.field) {
            inline else => |f| {
                if (self.reverse) {
                    std.mem.sort(Entry, self.entries, {}, lessThanBy(f, true));
                } else {
                    std.mem.sort(Entry, self.entries, {}, lessThanBy(f, false));
                }
            },
        }
    }
};

pub fn buildEntry(alloc: std.mem.Allocator, io: std.Io, dir: Io.Dir, name: []const u8) !Entry {
    var target_link_name: ?[]const u8 = null;
    const raw_stat = try stat.statEntry(dir.handle, try alloc.dupeZ(u8, name));

    if (raw_stat.kind == .sym_link) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const read_bytes = dir.readLink(io, raw_stat.name, &buffer) catch |err| blk: {
            std.log.warn("failed to read symlink target for {s}: {s}", .{ raw_stat.name, @errorName(err) });
            break :blk 0;
        };

        if (read_bytes > 0) {
            target_link_name = try alloc.dupe(u8, buffer[0..read_bytes]);
        }
    }

    const owner_group_names = try stat.resolveOwnerGroupNames(alloc, raw_stat.uid, raw_stat.gid);

    return .{
        .kind = raw_stat.kind,
        .permission = .{
            .owner = raw_stat.mode_bits.owner,
            .group = raw_stat.mode_bits.group,
            .other = raw_stat.mode_bits.other,
            .user_name = owner_group_names.user_name,
            .group_name = owner_group_names.group_name,
        },
        .name = raw_stat.name,
        .target_link_name = target_link_name,
        .size = raw_stat.size,
        .modified_timestamp = raw_stat.modified,
        .created_timestamp = raw_stat.created,
        .accessed_timestamp = raw_stat.accessed,
    };
}

fn renderFileSize(alloc: std.mem.Allocator, human_readable: bool, size: u64) ![]const u8 {
    if (!human_readable) {
        return try std.fmt.allocPrint(alloc, "{d}", .{size});
    }

    const size_units = [_][]const u8{ "K", "M", "G", "T", "P", "E" };
    const base = 1024;

    if (size < base) {
        return try std.fmt.allocPrint(alloc, "{d}B", .{size});
    }

    var value: f64 = @as(f64, @floatFromInt(size)) / base;
    var unit_index: usize = 0;

    while (value >= base and unit_index < size_units.len - 1) {
        value /= base;
        unit_index += 1;
    }

    if (value >= 999.5 and unit_index < size_units.len - 1) {
        value /= base;
        unit_index += 1;
    }

    if (value < 10) {
        return std.fmt.allocPrint(alloc, "{d:.1}{s}", .{ value, size_units[unit_index] });
    }

    return std.fmt.allocPrint(alloc, "{d:.0}{s}", .{ value, size_units[unit_index] });
}

fn expectHumanSize(size: u64, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const actual = try renderFileSize(alloc, true, size);

    defer alloc.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "renderFileSize: byte range (below 1024, no unit division)" {
    try expectHumanSize(0, "0B");
    try expectHumanSize(900, "900B");
    try expectHumanSize(1023, "1023B");
    try expectHumanSize(1024, "1.0K");
    try expectHumanSize(1025, "1.0K");
}

test "renderFileSize: precision cutoff (1 decimal below 10, none at/above)" {
    try expectHumanSize(5000, "4.9K");
    try expectHumanSize(10239, "10.0K");
    try expectHumanSize(10240, "10K");
}

test "renderFileSize: 999.5 correction boundary, at two different units" {
    try expectHumanSize(1023487, "999K");
    try expectHumanSize(1023488, "1.0M");
    try expectHumanSize(1023489, "1.0M");
    try expectHumanSize(1048051711, "999M");
    try expectHumanSize(1048051712, "1.0G");
}

test "renderFileSize: u64 max does not crash or go out of bounds" {
    try expectHumanSize(18446744073709551615, "16E");
}

test "renderFileSize: regression cases from the off-by-one and missing-branch bugs" {
    try expectHumanSize(2791728742, "2.6G");
    try expectHumanSize(67605770, "64M");
}

test "renderFileSize: human_readable=false returns the raw byte count" {
    const alloc = std.testing.allocator;
    const actual = try renderFileSize(alloc, false, 123456);

    defer alloc.free(actual);

    try std.testing.expectEqualStrings("123456", actual);
}

fn testEntry(name: []const u8, size: u64, created_ns: ?i96, modified_ns: ?i96, accessed_ns: ?i96) Entry {
    return .{
        .kind = .file,
        .size = size,
        .permission = .{
            .owner = 7,
            .group = 5,
            .other = 5,
            .user_name = "user",
            .group_name = "group",
        },
        .created_timestamp = if (created_ns) |ns| Io.Timestamp.fromNanoseconds(ns) else null,
        .modified_timestamp = if (modified_ns) |ns| Io.Timestamp.fromNanoseconds(ns) else null,
        .accessed_timestamp = if (accessed_ns) |ns| Io.Timestamp.fromNanoseconds(ns) else null,
        .name = name,
        .target_link_name = null,
    };
}

fn expectNamesInOrder(entries: []const Entry, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |entry, expected_name| {
        try std.testing.expectEqualStrings(expected_name, entry.name);
    }
}

test "Sort: by name in ascending & descending order" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 1, null, null, null),
        testEntry("README.md", 2, null, null, null),
        testEntry("build.zig", 1, null, null, null),
        testEntry("author.txt", 1, null, null, null),
        testEntry(".agents", 1, null, null, null),
        testEntry(".github", 1, null, null, null),
    };

    var sort = Sort.init(.name, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ ".agents", ".github", "author.txt", "build.zig", "Dockerfile", "README.md" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "README.md", "Dockerfile", "build.zig", "author.txt", ".github", ".agents" });
}

test "Sort: by size in ascending and descending order" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 100, null, null, null),
        testEntry("README.md", 2 * 1024, null, null, null),
        testEntry("build.zig", 195, null, null, null),
    };

    var sort = Sort.init(.size, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "Dockerfile", "build.zig", "README.md" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "README.md", "build.zig", "Dockerfile" });
}

test "Sort: by created timestamp in ascending and descending order" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 100, 900, null, null),
        testEntry("README.md", 2 * 1024, 100, null, null),
        testEntry("build.zig", 195, 700, null, null),
    };

    var sort = Sort.init(.created, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "README.md", "build.zig", "Dockerfile" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "Dockerfile", "build.zig", "README.md" });
}

test "Sort: by modified timestamp in ascending and descending order" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 100, null, 900, null),
        testEntry("README.md", 2 * 1024, null, 100, null),
        testEntry("build.zig", 195, null, 700, null),
    };

    var sort = Sort.init(.modified, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "README.md", "build.zig", "Dockerfile" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "Dockerfile", "build.zig", "README.md" });
}

test "Sort: by accessed timestamp in ascending and descending order" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 100, null, null, 900),
        testEntry("README.md", 2 * 1024, null, null, 100),
        testEntry("build.zig", 195, null, null, 700),
    };

    var sort = Sort.init(.accessed, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "README.md", "build.zig", "Dockerfile" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "Dockerfile", "build.zig", "README.md" });
}

test "Sort: entry with null timestamp sorts first (ascending & descending)" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 100, null, null, null),
        testEntry("README.md", 2 * 1024, null, null, null),
        testEntry("build.zig", 195, null, null, 900),
        testEntry(".gitignore", 207, null, null, 700),
    };

    var sort = Sort.init(.accessed, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "Dockerfile", "README.md", ".gitignore", "build.zig" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "build.zig", ".gitignore", "Dockerfile", "README.md" });
}

test "Sort: entry with the same timestamp will stay as is" {
    var entries = [_]Entry{
        testEntry("Dockerfile", 100, null, null, null),
        testEntry("README.md", 2 * 1024, 900, null, null),
        testEntry("build.zig", 195, 900, null, null),
        testEntry(".gitignore", 207, null, null, null),
    };

    var sort = Sort.init(.created, false, &entries);

    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "Dockerfile", ".gitignore", "README.md", "build.zig" });

    sort.reverse = true;
    sort.sort();
    try expectNamesInOrder(&entries, &[_][]const u8{ "README.md", "build.zig", "Dockerfile", ".gitignore" });
}

test "Sort: single-element and empty slice do not crash" {
    var entries = [_]Entry{testEntry("Dockerfile", 100, null, null, null)};
    var entries2 = [_]Entry{};

    var sort = Sort.init(.created, false, &entries);
    var sort2 = Sort.init(.created, false, &entries2);

    sort.sort();
    sort2.sort();

    try expectNamesInOrder(&entries, &[_][]const u8{"Dockerfile"});
    try expectNamesInOrder(&entries2, &[_][]const u8{});

    sort.reverse = true;
    sort2.reverse = true;

    sort.sort();
    sort2.sort();

    try expectNamesInOrder(&entries, &[_][]const u8{"Dockerfile"});
    try expectNamesInOrder(&entries2, &[_][]const u8{});
}
