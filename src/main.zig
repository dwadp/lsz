const std = @import("std");
const clap = @import("clap");
const builtin = @import("builtin");
const Io = std.Io;

const helpText =
    \\Usage: lsz [PATH] [OPTIONS]
    \\
    \\A minimal implementation of ls.
    \\
    \\Arguments:
    \\  PATH             Directory to list (default: current directory)
    \\
    \\Options:
    \\  -a, --all       List all files and do not ignore entries starting with .
    \\  -l, --list      Use a long listing format
    \\  -h, --help      Show this help message
    \\
    \\Examples:
    \\  lsz
    \\  lsz -a
    \\  lsz -l
    \\  lsz /path -l -a
;

var showLongListFormat = false;
var showAll = false;

var sizeLength: usize = 4;
var userNameLength: usize = 0;
var groupNameLength: usize = 0;

const PlatformError = error{UnsupportedPlatform};

const Permission = struct {
    owner: u32,
    group: u32,
    other: u32,
};

const Item = struct {
    kind: Io.File.Kind,
    size: usize,
    permission: Permission,
    timestamp: Io.Timestamp,
    name: []const u8,
    userName: [:0]const u8,
    groupName: [:0]const u8,
};

const mainParams = clap.parseParamsComptime(
    \\-h, --help    Display this help and exit.
    \\-l, --list    Use a long listing format
    \\-a, --all     List all files and do not ignore entries starting with .
    \\<str>
    \\
);

pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
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
        std.debug.print("{s}\n", .{helpText});
        return;
    }

    const allocator = arena.allocator();
    var path: []const u8 = "";

    if (res.positionals.len > 0) {
        path = res.positionals[0] orelse ".";
    }

    const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    showAll = res.args.all == 1;
    showLongListFormat = res.args.list == 1;

    var dirIter = dir.iterate();
    var result = std.ArrayList(Item).empty;
    defer result.deinit(allocator);

    while (try dirIter.next(io)) |content| {
        if (!showAll and std.mem.startsWith(u8, content.name, ".")) {
            continue;
        }

        try collectItem(allocator, dir, io, content, &result);
    }

    if (showLongListFormat) {
        const sizeLabel = try formatLeftAligned(allocator, sizeLength, "Size");
        const userLabel = try formatLeftAligned(allocator, userNameLength, "User");
        const groupLabel = try formatLeftAligned(allocator, groupNameLength, "Group");

        std.debug.print("{s:<11} {s} {s} {s} {s}\n", .{ "Permissions", sizeLabel, userLabel, groupLabel, "Name" });
    }

    for (result.items, 0..) |item, index| {
        if (showLongListFormat) {
            var permission = [_]u8{'-'} ** 10;

            if (item.kind == .file) {
                permission[0] = '.';
            } else if (item.kind == .directory) {
                permission[0] = 'd';
            }

            const sizeText = try formatLeftAligned(allocator, sizeLength, item.size);
            const userText = try formatLeftAligned(allocator, userNameLength, item.userName);
            const groupText = try formatLeftAligned(allocator, groupNameLength, item.groupName);

            decodeModeDigit(permission[1..4], item.permission.owner);
            decodeModeDigit(permission[4..7], item.permission.group);
            decodeModeDigit(permission[7..10], item.permission.other);

            std.debug.print("{s:<11} {s} {s} {s} {s}\n", .{ permission, sizeText, userText, groupText, item.name });
        } else {
            const lastItem = index == result.items.len - 1;

            if (!lastItem) {
                std.debug.print("{s} ", .{item.name});
            } else {
                std.debug.print("{s}\n", .{item.name});
            }
        }
    }
}

fn collectItem(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, content: Io.Dir.Entry, result: *std.ArrayList(Item)) !void {
    const stat = try dir.statFile(io, content.name, .{ .follow_symlinks = true });
    const file = try dir.openFile(io, content.name, .{});
    var userName: [:0]const u8 = "";
    var groupName: [:0]const u8 = "";

    switch (builtin.os.tag) {
        .macos => {
            var cStat: std.c.Stat = undefined;
            const fstat = std.c.fstat(file.handle, &cStat);
            const errno = std.c.errno(fstat);

            if (errno != .SUCCESS) {
                switch (errno) {
                    .FAULT => std.debug.print("Bad addresses: {any}", .{errno}),
                    else => std.debug.print("Unknown error: {any}", .{errno}),
                }
            } else {
                const uid = std.c.getpwuid(cStat.uid);
                const gid = std.c.getgrgid(cStat.gid);

                if (uid) |user| {
                    userName = std.mem.span(user.name orelse "");
                }

                if (gid) |group| {
                    groupName = std.mem.span(group.name orelse "");
                }
            }
        },
        .linux => return PlatformError.UnsupportedPlatform,
        .windows => return PlatformError.UnsupportedPlatform,
        else => return PlatformError.UnsupportedPlatform,
    }

    const mode = stat.permissions.toMode();
    const owner = (mode >> 6) & 0o7;
    const group = (mode >> 3) & 0o7;
    const other = mode & 0o7;

    if (sizeLength < countDigitsLog(@intCast(stat.size))) {
        sizeLength = countDigitsLog(@intCast(stat.size));
    }

    if (userNameLength < userName.len) {
        userNameLength = userName.len;
    }

    if (groupNameLength < groupName.len) {
        groupNameLength = groupName.len;
    }

    const item: Item = .{
        .kind = stat.kind,
        .permission = .{ .owner = owner, .group = group, .other = other },
        .name = content.name,
        .size = stat.size,
        .timestamp = stat.mtime,
        .userName = userName,
        .groupName = groupName,
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

fn formatLeftAligned(allocator: std.mem.Allocator, width: usize, value: anytype) ![]u8 {
    const valueInfo = @typeInfo(@TypeOf(value));

    return switch (valueInfo) {
        .int => try std.fmt.allocPrint(allocator, "{d: <[1]}", .{ value, width }),
        .float => try std.fmt.allocPrint(allocator, "{f: <[1]}", .{ value, width }),
        else => try std.fmt.allocPrint(allocator, "{s: <[1]}", .{ value, width }),
    };
}
