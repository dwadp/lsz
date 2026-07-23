const std = @import("std");
const clap = @import("clap");
const builtin = @import("builtin");
const stat = @import("stat.zig");
const tempora = @import("tempora");

const Io = std.Io;

const help_text =
    \\Usage: lsz [PATH] [OPTIONS]
    \\
    \\A very minimal implementation of ls.
    \\
    \\Arguments:
    \\  PATH             Directory to list (default: current directory)
    \\
    \\Options:
    \\  -a, --all       List all files and do not ignore entries starting with .
    \\  -l, --list      Use a long listing format
    \\  --help          Show this help message
    \\
    \\Examples:
    \\  lsz
    \\  lsz -a
    \\  lsz -l
    \\  lsz /path -l -a
;

var show_long_list_format = false;
var show_all = false;
var show_human_readable = false;

const PlatformError = error{UnsupportedPlatform};

const Permission = struct {
    owner: u32,
    group: u32,
    other: u32,
    userName: []const u8,
    groupName: []const u8,
};

const Item = struct {
    kind: Io.File.Kind,
    size: u64,
    permission: Permission,
    created_timestamp: ?Io.Timestamp,
    modified_timestamp: ?Io.Timestamp,
    accessed_timestamp: ?Io.Timestamp,
    name: []const u8,
    target_link_name: ?[]const u8 = null,
};

const main_params = clap.parseParamsComptime(
    \\--help        Display this help and exit.
    \\-l, --list    Use a long listing format
    \\-a, --all     List all files and do not ignore entries starting with .
    \\-h, --human   Print a human readable format information. With -l and -s, print sizes like 1K 234M 2G etc.
    \\<str>
    \\
);

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_impl = Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_impl.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_impl = Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_impl.interface;

    var iter = init.minimal.args.iterateAllocator(init.gpa) catch |err| {
        std.log.warn("failed to create iterate allocator: {}\n", .{err});
        return err;
    };

    defer iter.deinit();

    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };

    defer res.deinit();

    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    if (res.args.help == 1) {
        stdout.print("{s}\n", .{help_text}) catch |err| {
            std.log.warn("failed to print help text: {}\n", .{err});
            return err;
        };

        stdout.flush() catch |err| {
            std.log.warn("failed to flush stdout: {}\n", .{err});
            return err;
        };

        return;
    }

    const allocator = arena.allocator();
    var path: []const u8 = "";

    if (res.positionals.len > 0) {
        path = res.positionals[0] orelse ".";
    }

    show_all = res.args.all == 1;
    show_long_list_format = res.args.list == 1;
    show_human_readable = res.args.human == 1;

    run(allocator, io, &stdout_impl.interface, path) catch |err| switch (err) {
        error.FileNotFound => {
            stderr.print("No such file or directory: {s}\n", .{path}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

fn run(alloc: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8) !void {
    var dir = Io.Dir.cwd();
    var real_path: []const u8 = ".";

    if (path.len >= 0) {
        real_path = path;

        dir = dir.openDir(io, real_path, .{ .iterate = true }) catch |err| blk: {
            if (err == error.NotDir) {
                if (std.fs.path.dirname(real_path)) |dirname| {
                    break :blk try dir.openDir(io, dirname, .{ .iterate = true });
                }
            }

            return err;
        };
    }

    defer dir.close(io);

    var iterator = dir.iterate();

    var items = std.ArrayList(Item).empty;
    defer items.deinit(alloc);

    while (try iterator.next(io)) |entry| {
        if (!show_all and std.mem.startsWith(u8, entry.name, ".")) {
            continue;
        }

        try collectItem(alloc, dir, io, entry, &items);
    }

    if (show_long_list_format) {
        try runLongList(alloc, io, writer, items);
    } else {
        try runPlain(writer, items);
        try writer.flush();
    }
}

fn runPlain(writer: *std.Io.Writer, items: std.ArrayList(Item)) !void {
    for (items.items, 0..) |item, index| {
        const last_item = index == items.items.len - 1;

        if (!last_item) {
            try writer.print("{s} ", .{item.name});
        } else {
            try writer.print("{s}\n", .{item.name});
        }
    }
}

fn runLongList(alloc: std.mem.Allocator, _: std.Io, writer: *std.Io.Writer, items: std.ArrayList(Item)) !void {
    const permissions_label: []const u8 = "Permissions";
    var size_label: []const u8 = "Size";
    var user_name_label: []const u8 = "User";
    var group_name_label: []const u8 = "Group";
    var date_created_label: []const u8 = "Date Created";
    var date_modified_label: []const u8 = "Date Modified";
    const name_label: []const u8 = "Name";

    // Sizes declaration for formatting
    var size_length: usize = size_label.len;
    var user_name_length: usize = 0;
    var group_name_length: usize = 0;
    var date_created_length: usize = date_created_label.len;
    var date_modified_length: usize = date_modified_label.len;

    var item_list = std.ArrayList([]u8).empty;

    // TODO: figure out how to get timezone based on system
    const timezone = tempora.Timezone.utc;

    for (items.items) |item| {
        var date_modified_buf: std.ArrayList(u8) = .empty;
        var date_created: []const u8 = "";
        var date_modified: []const u8 = "";

        defer date_modified_buf.deinit(alloc);

        if (item.created_timestamp) |created_timestamp| {
            if (show_human_readable) {
                date_created = try formatTimestamHumanReadable(alloc, timezone, created_timestamp);
            } else {
                date_created = try std.fmt.allocPrint(alloc, "{d}", .{created_timestamp.toMilliseconds()});
            }

            if (date_created_length < date_created.len) {
                date_created_length = date_created.len;
            }
        }

        if (item.modified_timestamp) |modified_timestamp| {
            if (show_human_readable) {
                date_modified = try formatTimestamHumanReadable(alloc, timezone, modified_timestamp);
            } else {
                date_modified = try std.fmt.allocPrint(alloc, "{d}", .{modified_timestamp.toMilliseconds()});
            }

            if (date_modified_length < date_modified.len) {
                date_modified_length = date_modified.len;
            }
        }

        var permission = [_]u8{'-'} ** 10;

        if (item.kind == .file) {
            permission[0] = '.';
        } else if (item.kind == .directory) {
            permission[0] = 'd';
        } else if (item.kind == .sym_link) {
            permission[0] = 'l';
        } else if (item.kind == .unix_domain_socket) {
            permission[0] = 's';
        }

        var size_text = try std.fmt.allocPrint(alloc, "{d}", .{item.size});
        if (size_length < size_text.len) {
            size_length = @as(usize, size_text.len);
        }

        if (user_name_length < item.permission.userName.len) {
            user_name_length = item.permission.userName.len;
        }

        if (group_name_length < item.permission.groupName.len) {
            group_name_length = item.permission.groupName.len;
        }

        size_text = try formatLeftAligned(alloc, size_length, size_text);
        const user_text = try formatLeftAligned(alloc, user_name_length, item.permission.userName);
        const group_text = try formatLeftAligned(alloc, group_name_length, item.permission.groupName);

        decodeModeDigit(permission[1..4], item.permission.owner);
        decodeModeDigit(permission[4..7], item.permission.group);
        decodeModeDigit(permission[7..10], item.permission.other);

        var item_name = item.name;

        if (item.target_link_name) |targetName| {
            item_name = try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ item.name, targetName });
        }

        date_created = try formatLeftAligned(alloc, date_created.len, date_created);
        date_modified = try formatLeftAligned(alloc, date_modified.len, date_modified);

        // TODO: convert size to human readable format if specified
        const list = try std.fmt.allocPrint(alloc, "{s:<13} {s} {s} {s} {s} {s} {s}", .{ permission, size_text, user_text, group_text, date_created, date_modified, item_name });
        try item_list.append(alloc, list);
    }

    size_label = try formatLeftAligned(alloc, size_length, size_label);
    user_name_label = try formatLeftAligned(alloc, user_name_length, user_name_label);
    group_name_label = try formatLeftAligned(alloc, group_name_length, group_name_label);
    date_created_label = try formatLeftAligned(alloc, date_created_length, date_created_label);
    date_modified_label = try formatLeftAligned(alloc, date_modified_length, date_modified_label);

    try writer.print("{s:<13} {s} {s} {s} {s} {s} {s}\n", .{ permissions_label, size_label, user_name_label, group_name_label, date_created_label, date_modified_label, name_label });

    for (item_list.items) |item| {
        try writer.print("{s}\n", .{item});
    }

    try writer.flush();
}

fn collectItem(alloc: std.mem.Allocator, dir: Io.Dir, io: Io, entry: Io.Dir.Entry, items: *std.ArrayList(Item)) !void {
    const name_z = try alloc.dupeZ(u8, entry.name);
    const name = try alloc.dupe(u8, entry.name);

    var target_link_name: ?[]const u8 = null;

    if (entry.kind == .sym_link) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const read_bytes = dir.readLink(io, entry.name, &buffer) catch |err| blk: {
            std.log.warn("failed to read symlink target for {s}: {s}", .{ entry.name, @errorName(err) });
            break :blk 0;
        };

        if (read_bytes > 0) {
            target_link_name = try alloc.dupe(u8, buffer[0..read_bytes]);
        }
    }

    const raw_stat = try stat.statEntry(dir.handle, name_z);
    const owner_group_names = try stat.resolveOwnerGroupNames(alloc, raw_stat.uid, raw_stat.gid);

    const item: Item = .{
        .kind = raw_stat.kind,
        .permission = .{
            .owner = raw_stat.mode_bits.owner,
            .group = raw_stat.mode_bits.group,
            .other = raw_stat.mode_bits.owner,
            .userName = owner_group_names.user_name,
            .groupName = owner_group_names.group_name,
        },
        .name = name,
        .target_link_name = target_link_name,
        .size = raw_stat.size,
        .modified_timestamp = raw_stat.modified,
        .created_timestamp = raw_stat.created,
        .accessed_timestamp = raw_stat.accessed,
    };

    try items.append(alloc, item);
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

fn formatTimestamHumanReadable(alloc: std.mem.Allocator, timezone: tempora.Timezone, timestamp: std.Io.Timestamp) ![]u8 {
    const date_time = tempora.Date_Time.With_Offset.from_timestamp(timestamp, &timezone);
    const date_time_buf = try std.fmt.allocPrint(alloc, "{f}", .{date_time.fmt("DD MMM YYYY HH:mm:ss")});

    return date_time_buf;
}

fn formatLeftAligned(alloc: std.mem.Allocator, width: usize, value: anytype) ![]u8 {
    const value_info = @typeInfo(@TypeOf(value));

    return switch (value_info) {
        .int => try std.fmt.allocPrint(alloc, "{d:<[1]}", .{ value, width + 2 }),
        .float => try std.fmt.allocPrint(alloc, "{f:<[1]}", .{ value, width + 2 }),
        else => try std.fmt.allocPrint(alloc, "{s:<[1]}", .{ value, width + 2 }),
    };
}
