const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const builtin = @import("builtin");
const stat = @import("stat.zig");
const Io = std.Io;

const helpText =
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

var showLongListFormat = false;
var showAll = false;

var sizeLength: usize = 6;
var userNameLength: usize = 0;
var groupNameLength: usize = 0;
var dateCreatedLength: usize = 12;
var dateModifiedLength: usize = 13;

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

const mainParams = clap.parseParamsComptime(
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
    var res = clap.parseEx(clap.Help, &mainParams, clap.parsers.default, &iter, .{
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
        stdout.print("{s}\n", .{helpText}) catch |err| {
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

    showAll = res.args.all == 1;
    showLongListFormat = res.args.list == 1;

    run(allocator, io, &stdout_impl.interface, path) catch |err| switch (err) {
        error.FileNotFound => {
            stderr.print("No such file or directory: {s}\n", .{path}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8) !void {
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

    var contents = std.ArrayList(Item).empty;
    defer contents.deinit(allocator);

    while (try iterator.next(io)) |content| {
        if (!showAll and std.mem.startsWith(u8, content.name, ".")) {
            continue;
        }

        try collectItem(allocator, dir, io, content, &contents);
    }

    if (showLongListFormat) {
        try runLongList(allocator, io, writer, contents);
    } else {
        try runPlain(writer, contents);
        try writer.flush();
    }
}

fn runPlain(writer: *std.Io.Writer, contents: std.ArrayList(Item)) !void {
    for (contents.items, 0..) |item, index| {
        const lastItem = index == contents.items.len - 1;

        if (!lastItem) {
            try writer.print("{s} ", .{item.name});
        } else {
            try writer.print("{s}\n", .{item.name});
        }
    }
}

fn runLongList(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, contents: std.ArrayList(Item)) !void {
    var itemList = std.ArrayList([]u8).empty;

    for (contents.items) |item| {
        var dateCreatedBuf: std.ArrayList(u8) = .empty;
        var dateModifiedBuf: std.ArrayList(u8) = .empty;
        var dateCreated: []u8 = "";
        var dateModified: []u8 = "";

        defer dateCreatedBuf.deinit(allocator);
        defer dateModifiedBuf.deinit(allocator);

        if (item.created_timestamp) |created_timestamp| {
            dateCreated = try convertTimestampToString(allocator, io, &dateCreatedBuf, @intCast(created_timestamp.toSeconds()));
        }

        if (item.modified_timestamp) |modified_timestamp| {
            dateModified = try convertTimestampToString(allocator, io, &dateModifiedBuf, @intCast(modified_timestamp.toSeconds()));
        }

        if (dateCreated.len > dateCreatedLength) {
            dateCreatedLength = dateCreated.len + 2; // add more padding for clarity
        }

        if (dateModified.len > dateModifiedLength) {
            dateModifiedLength = dateModified.len + 2; // add more padding for clarity
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

        if (sizeLength < countDigitsLog(@intCast(item.size))) {
            sizeLength = countDigitsLog(@intCast(item.size)) + 2;
        }

        if (userNameLength < item.permission.userName.len) {
            userNameLength = item.permission.userName.len + 2;
        }

        if (groupNameLength < item.permission.groupName.len) {
            groupNameLength = item.permission.groupName.len + 2;
        }

        const sizeText = try formatLeftAligned(allocator, sizeLength, item.size);
        const userText = try formatLeftAligned(allocator, userNameLength, item.permission.userName);
        const groupText = try formatLeftAligned(allocator, groupNameLength, item.permission.groupName);

        decodeModeDigit(permission[1..4], item.permission.owner);
        decodeModeDigit(permission[4..7], item.permission.group);
        decodeModeDigit(permission[7..10], item.permission.other);

        dateCreated = try formatLeftAligned(allocator, dateCreatedLength, dateCreated);
        dateModified = try formatLeftAligned(allocator, dateModifiedLength, dateModified);

        var itemName = item.name;

        if (item.target_link_name) |targetName| {
            itemName = try std.fmt.allocPrint(allocator, "{s} -> {s}", .{ item.name, targetName });
        }

        const list = try std.fmt.allocPrint(allocator, "{s:<13} {s} {s} {s} {s} {s} {s}", .{ permission, sizeText, userText, groupText, dateCreated, dateModified, itemName });
        try itemList.append(allocator, list);
    }

    const sizeLabel = try formatLeftAligned(allocator, sizeLength, "Size");
    const userLabel = try formatLeftAligned(allocator, userNameLength, "User");
    const groupLabel = try formatLeftAligned(allocator, groupNameLength, "Group");
    const dateCreatedLabel = try formatLeftAligned(allocator, dateCreatedLength, "Date Created");
    const dateModifiedLabel = try formatLeftAligned(allocator, dateModifiedLength, "Date Modified");

    try writer.print("{s:<13} {s} {s} {s} {s} {s} {s}\n", .{ "Permissions", sizeLabel, userLabel, groupLabel, dateCreatedLabel, dateModifiedLabel, "Name" });

    for (itemList.items) |item| {
        try writer.print("{s}\n", .{item});
    }

    try writer.flush();
}

fn collectItem(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, content: Io.Dir.Entry, result: *std.ArrayList(Item)) !void {
    const name_z = try allocator.dupeZ(u8, content.name);
    const name = try allocator.dupe(u8, content.name);

    var target_link_name: ?[]const u8 = null;

    if (content.kind == .sym_link) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const read_bytes = dir.readLink(io, content.name, &buffer) catch |err| blk: {
            std.log.warn("failed to read symlink target for {s}: {s}", .{ content.name, @errorName(err) });
            break :blk 0;
        };

        if (read_bytes > 0) {
            target_link_name = try allocator.dupe(u8, buffer[0..read_bytes]);
        }
    }

    const raw_stat = try stat.statEntry(dir.handle, name_z);
    const owner_group_names = try stat.resolveOwnerGroupNames(allocator, raw_stat.uid, raw_stat.gid);

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

    try result.append(allocator, item);
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

fn convertTimestampToString(allocator: std.mem.Allocator, io: std.Io, buf: *std.ArrayList(u8), unixEpochSeconds: u64) ![]u8 {
    const unixEpoch = std.time.epoch.EpochSeconds{ .secs = unixEpochSeconds };

    const epochDay = unixEpoch.getEpochDay();
    const yearDay = epochDay.calculateYearDay();
    const monthDay = yearDay.calculateMonthDay();

    const daySeconds = unixEpoch.getDaySeconds();

    const year = yearDay.year;
    const month = @intFromEnum(monthDay.month) + 1;
    const day = monthDay.day_index + 1;

    const hour = daySeconds.getHoursIntoDay();
    const minute = daySeconds.getMinutesIntoHour();
    const second = daySeconds.getSecondsIntoMinute();

    var defaultTZ = try zdt.Timezone.tzLocal(io, allocator);
    defer defaultTZ.deinit();

    var datetime = try zdt.Datetime.fromFields(.{ .year = @intCast(year), .month = month, .day = day, .hour = hour, .minute = minute, .second = second, .tz_options = .{ .tz = &defaultTZ } });

    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, buf);
    try datetime.toString("%d %:b %Y %H:%M:%S", &w.writer);

    const written = w.written();

    return written;
}

fn formatLeftAligned(allocator: std.mem.Allocator, width: usize, value: anytype) ![]u8 {
    const valueInfo = @typeInfo(@TypeOf(value));

    return switch (valueInfo) {
        .int => try std.fmt.allocPrint(allocator, "{d: <[1]}", .{ value, width }),
        .float => try std.fmt.allocPrint(allocator, "{f: <[1]}", .{ value, width }),
        else => try std.fmt.allocPrint(allocator, "{s: <[1]}", .{ value, width }),
    };
}
