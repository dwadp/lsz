const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const builtin = @import("builtin");
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
    createdTimestamp: Io.Timestamp,
    modifiedTimestamp: Io.Timestamp,
    name: []const u8,
    targetLinkName: ?[]const u8 = null,
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

    showAll = res.args.all == 1;
    showLongListFormat = res.args.list == 1;

    try run(allocator, io, path);
}

fn run(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var dir = Io.Dir.cwd();

    if (path.len == 0) {
        dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    } else if (std.mem.eql(u8, path, ".") or std.mem.startsWith(u8, path, ".")) {
        dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    } else {
        dir = try Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
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
        try runLongList(allocator, io, contents);
    } else {
        try runPlain(contents);
    }
}

fn runPlain(contents: std.ArrayList(Item)) !void {
    for (contents.items, 0..) |item, index| {
        const lastItem = index == contents.items.len - 1;

        if (!lastItem) {
            std.debug.print("{s} ", .{item.name});
        } else {
            std.debug.print("{s}\n", .{item.name});
        }
    }
}

fn runLongList(allocator: std.mem.Allocator, io: std.Io, contents: std.ArrayList(Item)) !void {
    var itemList = std.ArrayList([]u8).empty;

    for (contents.items) |item| {
        var dateCreatedBuf: std.ArrayList(u8) = .empty;
        var dateModifiedBuf: std.ArrayList(u8) = .empty;
        var dateCreated: []u8 = "";
        var dateModified: []u8 = "";

        defer dateCreatedBuf.deinit(allocator);
        defer dateModifiedBuf.deinit(allocator);

        dateCreated = try convertTimestampToString(allocator, io, &dateCreatedBuf, @intCast(item.createdTimestamp.toSeconds()));
        dateModified = try convertTimestampToString(allocator, io, &dateModifiedBuf, @intCast(item.modifiedTimestamp.toSeconds()));

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

        if (item.targetLinkName) |targetName| {
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

    std.debug.print("{s:<13} {s} {s} {s} {s} {s} {s}\n", .{ "Permissions", sizeLabel, userLabel, groupLabel, dateCreatedLabel, dateModifiedLabel, "Name" });

    for (itemList.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
}

fn collectItem(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, content: Io.Dir.Entry, result: *std.ArrayList(Item)) !void {
    if (content.kind == .directory) {
        const subDir = try dir.openDir(io, content.name, .{ .iterate = false });
        const subDirStat = try subDir.stat(io);

        const permission = try collectOwnershipAndPermissions(subDir.handle, subDirStat);

        const item: Item = .{
            .kind = .directory,
            .permission = permission,
            .name = content.name,
            .size = subDirStat.size,
            .modifiedTimestamp = subDirStat.mtime,
            .createdTimestamp = subDirStat.ctime,
        };

        try result.append(allocator, item);
    } else if (content.kind == .file) {
        const stat = try dir.statFile(io, content.name, .{ .follow_symlinks = true });
        const file = try dir.openFile(io, content.name, .{ .follow_symlinks = false });

        const permission = try collectOwnershipAndPermissions(file.handle, stat);

        const item: Item = .{
            .kind = stat.kind,
            .permission = permission,
            .name = content.name,
            .size = stat.size,
            .modifiedTimestamp = stat.mtime,
            .createdTimestamp = stat.ctime,
        };

        try result.append(allocator, item);
    } else if (content.kind == .sym_link) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var permission: ?Permission = null;
        const readBytes = try dir.readLink(io, content.name, &buffer);

        const targetLinkName = try allocator.alloc(u8, readBytes);
        @memcpy(targetLinkName, buffer[0..readBytes]);

        const stat = try dir.statFile(io, content.name, .{ .follow_symlinks = false });
        if (stat.kind == .file or stat.kind == .sym_link) {
            const file = dir.openFile(io, targetLinkName, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.FileNotFound) {
                    try result.append(allocator, .{
                        .kind = stat.kind,
                        .permission = .{
                            .owner = 0,
                            .group = 0,
                            .other = 0,
                            .userName = "???",
                            .groupName = "???",
                        },
                        .name = content.name,
                        .targetLinkName = targetLinkName,
                        .size = stat.size,
                        .modifiedTimestamp = stat.mtime,
                        .createdTimestamp = stat.ctime,
                    });

                    return;
                }

                return err;
            };

            permission = try collectOwnershipAndPermissions(file.handle, stat);
        } else if (stat.kind == .directory) {
            std.log.err("not implemented yet!\n", .{});
            unreachable;
        }

        var owner: u32 = 0;
        var group: u32 = 0;
        var other: u32 = 0;
        var userName: []const u8 = "";
        var groupName: []const u8 = "";

        if (permission) |p| {
            owner = p.owner;
            group = p.group;
            other = p.other;
            userName = p.userName;
            groupName = p.groupName;
        }

        const item: Item = .{
            .kind = stat.kind,
            .permission = .{
                .owner = owner,
                .group = group,
                .other = other,
                .userName = userName,
                .groupName = groupName,
            },
            .name = content.name,
            .targetLinkName = targetLinkName,
            .size = stat.size,
            .modifiedTimestamp = stat.mtime,
            .createdTimestamp = stat.ctime,
        };

        try result.append(allocator, item);
    }
}

fn collectOwnershipAndPermissions(fileHandle: i32, stat: Io.File.Stat) !Permission {
    var userName: [:0]const u8 = "";
    var groupName: [:0]const u8 = "";

    switch (builtin.os.tag) {
        .macos => {
            var cStat: std.c.Stat = undefined;
            const fstat = std.c.fstat(fileHandle, &cStat);
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

    const permission: Permission = .{
        .owner = owner,
        .group = group,
        .other = other,
        .userName = userName[0..],
        .groupName = groupName[0..],
    };

    return permission;
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
