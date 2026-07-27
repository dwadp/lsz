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

fn testEntry(name: []const u8, size: u64) entry.Entry {
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
        .created_timestamp = null,
        .modified_timestamp = null,
        .accessed_timestamp = null,
        .name = name,
        .target_link_name = null,
    };
}

fn expectWritten(entries: std.ArrayList(entry.Entry), expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printDefault(&w, entries);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "printDefault: multiple entries are displayed with a space-separated format and the last entry gets a new line character" {
    const alloc = std.testing.allocator;
    var entries = std.ArrayList(entry.Entry).empty;
    defer entries.deinit(alloc);

    try entries.append(alloc, testEntry(".gitignore", 100));
    try entries.append(alloc, testEntry("build.zig", 200));
    try entries.append(alloc, testEntry("Dockerfile", 300));
    try entries.append(alloc, testEntry("README.md", 400));

    try expectWritten(entries, ".gitignore build.zig Dockerfile README.md\n");
}

test "printDefault: single-line has no leading/trailing space, just newline" {
    const alloc = std.testing.allocator;
    var entries = std.ArrayList(entry.Entry).empty;
    defer entries.deinit(alloc);

    try entries.append(alloc, testEntry(".gitignore", 100));

    try expectWritten(entries, ".gitignore\n");
}

test "printDefault: empty entries display nothing" {
    const alloc = std.testing.allocator;
    var entries = std.ArrayList(entry.Entry).empty;
    defer entries.deinit(alloc);

    try expectWritten(entries, "");
}

test "printLongListFormat: render header and rows through the real table + entry pipeline" {
    const t_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(t_alloc);
    defer arena.deinit();

    const a_aloc = arena.allocator();

    var entries = std.ArrayList(entry.Entry).empty;
    defer entries.deinit(a_aloc);

    try entries.append(a_aloc, testEntry(".gitignore", 100));

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try printLongListFormat(a_aloc, &w, entries, false);

    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "Permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Size") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "User") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Group") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Name") != null);

    try std.testing.expect(std.mem.indexOf(u8, output, "-rwxr-xr-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".gitignore") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "100") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "group") != null);
}
