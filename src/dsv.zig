const std = @import("std");
const tempora = @import("tempora");
const entry = @import("entry.zig");

pub const Delimiter = enum(u8) {
    comma = ',',
    tab = '\t',
};

pub fn print(alloc: std.mem.Allocator, writer: *std.Io.Writer, entries: std.ArrayList(entry.Entry), human_readable: bool, tz: tempora.Timezone, delimiter: Delimiter) !void {
    var columns = std.EnumArray(entry.EntryField, []const u8).init(.{
        .permission = "Permission",
        .size = "Size",
        .user_name = "User",
        .group_name = "Group",
        .created_timestamp = "Date Created",
        .modified_timestamp = "Date Modified",
        .name = "Name",
    });

    var rows: std.ArrayList([][]const u8) = .empty;

    for (entries.items) |e| {
        const cells = try e.toCells(alloc, human_readable, tz);

        try rows.append(alloc, cells);
    }

    try render(writer, &columns.values, rows.items, delimiter);
    return;
}

pub fn render(writer: *std.Io.Writer, columns: [][]const u8, rows: []const []const []const u8, delimiter: Delimiter) !void {
    try renderHeader(writer, columns, delimiter);

    for (rows) |row| try renderRow(writer, row, delimiter);

    try writer.flush();
}

fn renderHeader(writer: *std.Io.Writer, columns: [][]const u8, delimiter: Delimiter) !void {
    for (columns, 0..) |col, i| {
        if (i != 0) try writer.writeByte(@intFromEnum(delimiter));

        try writer.writeAll(col);
    }

    try writer.writeByte('\n');
}

fn renderRow(writer: *std.Io.Writer, cells: []const []const u8, delimiter: Delimiter) !void {
    for (cells, 0..) |cell, i| {
        if (i != 0) try writer.writeByte(@intFromEnum(delimiter));

        try writer.writeAll(cell);
    }

    try writer.writeByte('\n');
}

fn expectRendered(columns: [][]const u8, rows: []const []const []const u8, expected: []const u8, delimiter: Delimiter) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try render(&w, columns, rows, delimiter);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

fn testEntry(name: []const u8, size: u64) entry.Entry {
    return .{
        .kind = .file,
        .size = size,
        .mode = .{
            .owner = 7,
            .group = 5,
            .other = 5,
            .user_name = "user",
            .group_name = "group",
        },
        .created_timestamp = null,
        .modified_timestamp = null,
        .accessed_timestamp = null,
        .name = name,
        .target_link_name = null,
    };
}

test "dsv.render: csv" {
    var columns = [_][]const u8{ "Size", "Name" };
    const rows = [_][]const []const u8{
        &.{ "12", "a.txt" },
    };

    try expectRendered(&columns, &rows, "Size,Name\n12,a.txt\n", .comma);
}

test "dsv.render: tsv" {
    var columns = [_][]const u8{ "Size", "Name" };
    const rows = [_][]const []const u8{
        &.{ "12", "a.txt" },
    };

    try expectRendered(&columns, &rows, "Size\tName\n12\ta.txt\n", .tab);
}

test "dsv.renderHeader: tsv & csv" {
    var columns: [2][]const u8 = .{ "Size", "Name" };

    const rows = [_][]const []const u8{};

    try expectRendered(&columns, &rows, "Size,Name\n", .comma);
    try expectRendered(&columns, &rows, "Size\tName\n", .tab);
}

test "dsv.render: single column has no delimiter at all" {
    var columns = [_][]const u8{"Name"};
    const rows = [_][]const []const u8{
        &.{"a.txt"},
    };

    try expectRendered(&columns, &rows, "Name\na.txt\n", .comma);
}

test "dsv.print: csv & tsv" {
    const cases = [_]Delimiter{ .comma, .tab };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const alloc = arena.allocator();

        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        var entries: std.ArrayList(entry.Entry) = .empty;

        try entries.append(alloc, testEntry("a.txt", 12));

        try print(alloc, &w, entries, false, tempora.Timezone.utc, case);

        const output = w.buffered();

        try std.testing.expect(std.mem.indexOf(u8, output, "Permission") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "Size") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "User") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "Group") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "Name") != null);

        try std.testing.expect(std.mem.indexOf(u8, output, "-rwxr-xr-x") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "a.txt") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "12") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "user") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "group") != null);
    }
}
