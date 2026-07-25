const std = @import("std");
const file_entry = @import("file_entry.zig");
const table = @import("table.zig");

pub fn printDefault(writer: *std.Io.Writer, entries: std.ArrayList(file_entry.Entry)) !void {
    for (entries.items, 0..) |entry, index| {
        const last_item = index == entries.items.len - 1;

        if (!last_item) {
            try writer.print("{s} ", .{entry.name});
        } else {
            try writer.print("{s}\n", .{entry.name});
        }
    }
}

pub fn printLongListFormat(alloc: std.mem.Allocator, writer: *std.Io.Writer, entries: std.ArrayList(file_entry.Entry), human_readable: bool) !void {
    var columns = std.EnumArray(file_entry.EntryField, table.Column).init(.{
        .permission = .init("Permission", table.Align.left),
        .size = .init("Size", table.Align.right),
        .user_name = .init("User", table.Align.left),
        .group_name = .init("Group", table.Align.left),
        .created_timestamp = .init("Date Created", table.Align.left),
        .modified_timestamp = .init("Date Modified", table.Align.left),
        .name = .init("Name", table.Align.left),
    });

    var rows: std.ArrayList([][]const u8) = .empty;

    for (entries.items) |entry| {
        const cells = try entry.toCells(alloc, human_readable);

        try rows.append(alloc, cells);
    }

    try table.render(writer, &columns.values, rows.items);
}
