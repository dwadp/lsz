const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const path = if (args.len > 1 and !std.mem.startsWith(u8, args[1], "-")) args[1] else ".";

    for (args, 0..) |arg, index| {
        if (index == 0) continue;

        if (std.mem.eql(u8, arg, "-l")) {
            showLongListFormat = true;
        }

        if (std.mem.eql(u8, arg, "-a")) {
            showAll = true;
        }
    }

    const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    var result = std.ArrayList(Item).empty;
    defer result.deinit(allocator);

    while (try iter.next(io)) |content| {
        if (!showAll and std.mem.startsWith(u8, content.name, ".")) {
            continue;
        }

        if (showLongListFormat) {
            try collectLongListItem(allocator, dir, io, content, &result);
            continue;
        }

        std.debug.print("{s} ", .{content.name});
    }

    if (showLongListFormat) {
        const sizeLabel = try formatLeftAligned(allocator, sizeLength, "Size");
        const userLabel = try formatLeftAligned(allocator, userNameLength, "User");
        const groupLabel = try formatLeftAligned(allocator, groupNameLength, "Group");

        std.debug.print("{s:<11} {s} {s} {s} {s}\n", .{ "Permissions", sizeLabel, userLabel, groupLabel, "Name" });
    }

    for (result.items) |item| {
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
    }
}

fn collectLongListItem(allocator: std.mem.Allocator, dir: Io.Dir, io: Io, content: Io.Dir.Entry, result: *std.ArrayList(Item)) !void {
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
