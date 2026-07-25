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
