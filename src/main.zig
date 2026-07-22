const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const builtin = @import("builtin");
const stat = @import("stat.zig");
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

var size_length: usize = 6;
var user_name_length: usize = 0;
var group_name_length: usize = 0;
var date_created_length: usize = 12;
var date_modified_length: usize = 13;

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
    size: usize,
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

    if (path.len == 0) {
        dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    } else if (std.mem.eql(u8, path, ".") or std.mem.startsWith(u8, path, ".")) {
        dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    } else if (std.fs.path.isAbsolute(path)) {
        dir = try Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    } else {
        dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
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

fn runLongList(alloc: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, items: std.ArrayList(Item)) !void {
    var item_list = std.ArrayList([]u8).empty;

    for (items.items) |item| {
        var date_created_buf: std.ArrayList(u8) = .empty;
        var date_modified_buf: std.ArrayList(u8) = .empty;
        var date_created: []u8 = "";
        var date_modified: []u8 = "";

        defer date_created_buf.deinit(alloc);
        defer date_modified_buf.deinit(alloc);

        if (item.created_timestamp) |created_timestamp| {
            date_created = try convertTimestampToString(alloc, io, &date_created_buf, @intCast(created_timestamp.toSeconds()));
        }

        if (item.modified_timestamp) |modified_timestamp| {
            date_modified = try convertTimestampToString(alloc, io, &date_modified_buf, @intCast(modified_timestamp.toSeconds()));
        }

        if (date_created.len > date_created_length) {
            date_created_length = date_created.len + 2; // add more padding for clarity
        }

        if (date_modified.len > date_modified_length) {
            date_modified_length = date_modified.len + 2; // add more padding for clarity
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

        if (size_length < countDigitsLog(@intCast(item.size))) {
            size_length = countDigitsLog(@intCast(item.size)) + 2;
        }

        if (user_name_length < item.permission.userName.len) {
            user_name_length = item.permission.userName.len + 2;
        }

        if (group_name_length < item.permission.groupName.len) {
            group_name_length = item.permission.groupName.len + 2;
        }

        const size_text = try formatLeftAligned(alloc, size_length, item.size);
        const user_text = try formatLeftAligned(alloc, user_name_length, item.permission.userName);
        const group_text = try formatLeftAligned(alloc, group_name_length, item.permission.groupName);

        decodeModeDigit(permission[1..4], item.permission.owner);
        decodeModeDigit(permission[4..7], item.permission.group);
        decodeModeDigit(permission[7..10], item.permission.other);

        date_created = try formatLeftAligned(alloc, date_created_length, date_created);
        date_modified = try formatLeftAligned(alloc, date_modified_length, date_modified);

        var item_name = item.name;

        if (item.target_link_name) |targetName| {
            item_name = try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ item.name, targetName });
        }

        const list = try std.fmt.allocPrint(alloc, "{s:<13} {s} {s} {s} {s} {s} {s}", .{ permission, size_text, user_text, group_text, date_created, date_modified, item_name });
        try item_list.append(alloc, list);
    }

    const size_label = try formatLeftAligned(alloc, size_length, "Size");
    const user_label = try formatLeftAligned(alloc, user_name_length, "User");
    const group_label = try formatLeftAligned(alloc, group_name_length, "Group");
    const date_created_label = try formatLeftAligned(alloc, date_created_length, "Date Created");
    const date_modified_label = try formatLeftAligned(alloc, date_modified_length, "Date Modified");

    try writer.print("{s:<13} {s} {s} {s} {s} {s} {s}\n", .{ "Permissions", size_label, user_label, group_label, date_created_label, date_modified_label, "Name" });

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

fn countDigitsLog(num: u32) u32 {
    if (num == 0) return 1;
    return std.math.log10(num) + 1;
}

// TODO:Still has bugs for the timezone. I'm still not able to make it timezone aware. I'll get to that later :)
fn convertTimestampToString(alloc: std.mem.Allocator, io: std.Io, buf: *std.ArrayList(u8), unixEpochSeconds: u64) ![]u8 {
    const unix_epoch = std.time.epoch.EpochSeconds{ .secs = unixEpochSeconds };

    const epoch_day = unix_epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_seconds = unix_epoch.getDaySeconds();

    const year = year_day.year;
    const month = @intFromEnum(month_day.month) + 1;
    const day = month_day.day_index + 1;

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    var default_tz = try zdt.Timezone.tzLocal(io, alloc);
    defer default_tz.deinit();

    var datetime = try zdt.Datetime.fromFields(.{ .year = @intCast(year), .month = month, .day = day, .hour = hour, .minute = minute, .second = second, .tz_options = .{ .tz = &default_tz } });

    var w: std.Io.Writer.Allocating = .fromArrayList(alloc, buf);
    try datetime.toString("%d %:b %Y %H:%M:%S", &w.writer);

    const written = w.written();

    return written;
}

fn formatLeftAligned(alloc: std.mem.Allocator, width: usize, value: anytype) ![]u8 {
    const value_info = @typeInfo(@TypeOf(value));

    return switch (value_info) {
        .int => try std.fmt.allocPrint(alloc, "{d: <[1]}", .{ value, width }),
        .float => try std.fmt.allocPrint(alloc, "{f: <[1]}", .{ value, width }),
        else => try std.fmt.allocPrint(alloc, "{s: <[1]}", .{ value, width }),
    };
}
