const std = @import("std");
const tempora = @import("tempora");
const entry = @import("entry.zig");

pub const Align = enum { left, right };

pub const Column = struct {
    header: []const u8,
    alignment: Align,
    width: usize = 0,

    pub fn init(header: []const u8, alignment: Align) Column {
        return .{
            .header = header,
            .alignment = alignment,
            .width = header.len,
        };
    }
};

pub fn print(alloc: std.mem.Allocator, writer: *std.Io.Writer, entries: std.ArrayList(entry.Entry), human_readable: bool, tz: tempora.Timezone) !void {
    var columns = std.EnumArray(entry.EntryField, Column).init(.{
        .permission = .init("Permission", Align.left),
        .size = .init("Size", Align.right),
        .user_name = .init("User", Align.left),
        .group_name = .init("Group", Align.left),
        .created_timestamp = .init("Date Created", Align.left),
        .modified_timestamp = .init("Date Modified", Align.left),
        .name = .init("Name", Align.left),
    });

    var rows: std.ArrayList([][]const u8) = .empty;

    for (entries.items) |e| {
        const cells = try e.toCells(alloc, human_readable, tz);

        try rows.append(alloc, cells);
    }

    try render(writer, &columns.values, rows.items);
}

pub fn render(writer: *std.Io.Writer, columns: []Column, rows: []const []const []const u8) !void {
    for (rows) |row| {
        for (row, 0..) |cell, index| {
            if (cell.len > columns[index].width) columns[index].width = cell.len;
        }
    }

    try renderHeader(writer, columns);

    for (rows) |row| try renderRow(writer, columns, row);

    try writer.flush();
}

fn renderHeader(writer: *std.Io.Writer, columns: []Column) !void {
    for (columns, 0..) |col, i| {
        if (i != 0) try writer.writeAll("  "); // 2-space column gap

        try renderCell(writer, col.header, col.width, col.alignment, i == columns.len - 1);
    }

    try writer.writeByte('\n');
}

fn renderRow(writer: *std.Io.Writer, columns: []Column, cells: []const []const u8) !void {
    for (cells, 0..) |cell, i| {
        if (i != 0) try writer.writeAll("  ");

        try renderCell(writer, cell, columns[i].width, columns[i].alignment, i == cells.len - 1);
    }

    try writer.writeByte('\n');
}

fn renderCell(writer: *std.Io.Writer, cell: []const u8, width: usize, alignment: Align, last: bool) !void {
    if (last) {
        try writer.writeAll(cell);
    } else switch (alignment) {
        .left => try writer.print("{s:<[1]}", .{ cell, width }),
        .right => try writer.print("{s:>[1]}", .{ cell, width }),
    }
}

fn expectRendered(columns: []Column, rows: []const []const []const u8, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try render(&w, columns, rows);
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

test "table.render: basic header & row alignment" {
    var columns = [_]Column{
        .init("Size", .right),
        .init("Name", .left),
    };

    const rows = [_][]const []const u8{
        &.{ "12", "a.txt" },
    };

    try expectRendered(&columns, &rows, "Size  Name\n  12  a.txt\n");
}

test "table.render: column width is driven by the widest rows" {
    var columns = [_]Column{
        .init("Size", .right),
        .init("Name", .left),
    };

    const rows = [_][]const []const u8{
        &.{ "12", "a.txt" },
        &.{ "999999", "b.txt" },
    };

    try expectRendered(&columns, &rows, "  Size  Name\n    12  a.txt\n999999  b.txt\n");
}

test "table.render: header only, no rows" {
    var columns = [_]Column{
        .init("Size", .right),
        .init("Name", .left),
    };

    const rows = [_][]const []const u8{};

    try expectRendered(&columns, &rows, "Size  Name\n");
}

test "table.print" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var entries: std.ArrayList(entry.Entry) = .empty;

    try entries.append(alloc, testEntry("a.txt", 12));

    try print(alloc, &w, entries, false, tempora.Timezone.utc);

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
