const std = @import("std");
const entry = @import("entry.zig");
const table = @import("table.zig");

pub fn printDefault(writer: *std.Io.Writer, entries: std.ArrayList(entry.Entry)) !void {
    for (entries.items, 0..) |e, index| {
        const last_item = index == entries.items.len - 1;

        if (!last_item) {
            try writer.print("{s} ", .{e.name});
        } else {
            try writer.print("{s}\n", .{e.name});
        }
    }
}

pub fn printLongListFormat(alloc: std.mem.Allocator, writer: *std.Io.Writer, entries: std.ArrayList(entry.Entry), human_readable: bool) !void {
    var columns = std.EnumArray(entry.EntryField, table.Column).init(.{
        .permission = .init("Permission", table.Align.left),
        .size = .init("Size", table.Align.right),
        .user_name = .init("User", table.Align.left),
        .group_name = .init("Group", table.Align.left),
        .created_timestamp = .init("Date Created", table.Align.left),
        .modified_timestamp = .init("Date Modified", table.Align.left),
        .name = .init("Name", table.Align.left),
    });

    var rows: std.ArrayList([][]const u8) = .empty;

    for (entries.items) |e| {
        const cells = try e.toCells(alloc, human_readable);

        try rows.append(alloc, cells);
    }

    try table.render(writer, &columns.values, rows.items);
}
