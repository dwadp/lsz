const std = @import("std");
const builtin = @import("builtin");

pub const RawStat = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    size: u64,
    mode_bits: struct { owner: u3, group: u3, other: u3 },
    uid: u32,
    gid: u32,
    modified: ?std.Io.Timestamp,
    created: ?std.Io.Timestamp,
    accessed: ?std.Io.Timestamp,
};

pub const StatError = error{
    BadFileDescriptor, // EBADF
    BadAddress, // EFAULT
    InputOutputError, // EIO (macOS only)
    AccessDenied, // EACCES
    SymlinkLoop, // ELOOP
    NameTooLong, // ENAMETOOLONG
    FileNotFound, // ENOENT
    NotADirectory, // ENOTDIR
    FileSizeOverflow, // EOVERFLOW (macOS only)
    OutOfMemory, // ENOMEM (Linux only)
    InvalidFlag, // EINVAL
    Unknown,
};

pub fn statEntry(dir_handle: i32, name_z: [:0]const u8) !RawStat {
    return switch (builtin.os.tag) {
        .macos => statEntryMacos(dir_handle, name_z),
        .linux => statEntryLinux(dir_handle, name_z),
        else => error.UnsupportedPlatform,
    };
}

fn statEntryMacos(dir_handle: i32, name_z: [:0]const u8) !RawStat {
    var c_stat_buf: std.c.Stat = undefined;

    const result = std.c.fstatat(dir_handle, name_z, &c_stat_buf, std.c.AT.SYMLINK_NOFOLLOW);
    const errno = std.c.errno(result);
    if (errno != .SUCCESS) {
        return mapErrnoMacos(errno);
    }

    const mode_bits = splitModeBits(c_stat_buf.mode);
    const file_size = try toFileSize(c_stat_buf.size);

    return .{
        .name = name_z,
        .mode_bits = .{
            .owner = mode_bits.owner,
            .group = mode_bits.group,
            .other = mode_bits.other,
        },
        .size = file_size,
        .uid = c_stat_buf.uid,
        .gid = c_stat_buf.gid,
        .kind = modeToKind(c_stat_buf.mode),
        .created = timespecToTimestamp(c_stat_buf.ctimespec),
        .modified = timespecToTimestamp(c_stat_buf.mtimespec),
        .accessed = timespecToTimestamp(c_stat_buf.atimespec),
    };
}

fn statEntryLinux(dir_handle: i32, name_z: [:0]const u8) !RawStat {
    var statx_buf: std.os.linux.Statx = undefined;

    const mask: std.os.linux.STATX = @bitCast(@as(u32, @bitCast(std.os.linux.STATX.BASIC_STATS)) | @as(u32, @bitCast(std.os.linux.STATX{ .BTIME = true })));
    const result = std.os.linux.statx(dir_handle, name_z, std.os.linux.AT.SYMLINK_NOFOLLOW, mask, &statx_buf);
    const errno = std.os.linux.errno(result);

    if (errno != .SUCCESS) {
        return mapErrnoLinux(errno);
    }

    const mode_bits = splitModeBits(@as(u32, statx_buf.mode));

    return .{
        .name = name_z,
        .mode_bits = .{
            .owner = mode_bits.owner,
            .group = mode_bits.group,
            .other = mode_bits.other,
        },
        .size = statx_buf.size, // no need to pass it to toFileSize() because the is already same
        .uid = statx_buf.uid,
        .gid = statx_buf.gid,
        .kind = modeToKind(@as(u32, statx_buf.mode)),
        .created = statxTimestampToTimestamp(statx_buf.btime),
        .modified = statxTimestampToTimestamp(statx_buf.mtime),
        .accessed = statxTimestampToTimestamp(statx_buf.atime),
    };
}

fn modeToKind(mode: u32) std.Io.File.Kind {
    if (std.c.S.ISDIR(mode)) return .directory;
    if (std.c.S.ISREG(mode)) return .file;
    if (std.c.S.ISLNK(mode)) return .sym_link;
    if (std.c.S.ISSOCK(mode)) return .unix_domain_socket;
    if (std.c.S.ISCHR(mode)) return .character_device;
    if (std.c.S.ISBLK(mode)) return .block_device;
    if (std.c.S.ISFIFO(mode)) return .named_pipe;

    return .unknown;
}

pub fn splitModeBits(mode: u32) struct { owner: u3, group: u3, other: u3 } {
    return .{
        .owner = @intCast((mode >> 6) & 0o7),
        .group = @intCast((mode >> 3) & 0o7),
        .other = @intCast(mode & 0o7),
    };
}

fn toFileSize(size: anytype) !u64 {
    return std.math.cast(u64, size) orelse error.FileSizeOverflow;
}

fn timespecToTimestamp(ts: std.c.timespec) std.Io.Timestamp {
    const sec: i96 = @intCast(ts.sec);
    const nsec: i96 = @intCast(ts.nsec);
    const totalNs = (sec * std.time.ns_per_s) + nsec;

    return std.Io.Timestamp.fromNanoseconds(totalNs);
}

fn statxTimestampToTimestamp(ts: std.os.linux.statx_timestamp) std.Io.Timestamp {
    const sec: i96 = @intCast(ts.sec);
    const nsec: i96 = @intCast(ts.nsec);
    const totalNs = (sec * std.time.ns_per_s) + nsec;

    return std.Io.Timestamp.fromNanoseconds(totalNs);
}

fn mapErrnoMacos(errno: std.c.E) StatError {
    return switch (errno) {
        .BADF => error.BadFileDescriptor,
        .FAULT => error.BadAddress,
        .IO => error.InputOutputError,
        .ACCES => error.AccessDenied,
        .LOOP => error.SymlinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotADirectory,
        .OVERFLOW => error.FileSizeOverflow,
        .INVAL => error.InvalidFlag,
        else => error.Unknown,
    };
}

fn mapErrnoLinux(errno: std.os.linux.E) StatError {
    return switch (errno) {
        .ACCES => error.AccessDenied,
        .BADF => error.BadFileDescriptor,
        .FAULT => error.BadAddress,
        .INVAL => error.InvalidFlag,
        .LOOP => error.SymlinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.OutOfMemory,
        .NOTDIR => error.NotADirectory,
        else => error.Unknown,
    };
}

// Retrieve the owner & group name from the given uid & gid
// by default it will return "???" if it can't resolve the names
pub fn resolveOwnerGroupNames(alloc: std.mem.Allocator, uid: std.c.uid_t, gid: std.c.gid_t) !struct { user_name: []const u8, group_name: []const u8 } {
    switch (builtin.os.tag) {
        .macos, .linux => {
            var user_name: []const u8 = "???";
            var group_name: []const u8 = "???";

            if (std.c.getpwuid(uid)) |user| {
                user_name = try alloc.dupe(u8, std.mem.span(user.name orelse "???"));
            }

            if (std.c.getgrgid(gid)) |group| {
                group_name = try alloc.dupe(u8, std.mem.span(group.name orelse "???"));
            }

            return .{ .user_name = user_name, .group_name = group_name };
        },
        else => error.UnsupportedPlatform,
    }
}

test "splitModeBits: extracts owner, group, other from full permission" {
    const result = splitModeBits(@as(u32, 0o755));
    try std.testing.expectEqual(@as(u3, 7), result.owner);
    try std.testing.expectEqual(@as(u3, 5), result.group);
    try std.testing.expectEqual(@as(u3, 5), result.other);
}

test "splitModeBits: handles zero permission" {
    const result = splitModeBits(@as(u32, 0));
    try std.testing.expectEqual(@as(u3, 0), result.owner);
    try std.testing.expectEqual(@as(u3, 0), result.group);
    try std.testing.expectEqual(@as(u3, 0), result.other);
}

test "splitModeBits: ignores file type bits above permission bits" {
    // 0o120755 -> symlink (0o120000) with permission 755
    const result = splitModeBits(@as(u32, 0o120755));
    try std.testing.expectEqual(@as(u3, 7), result.owner);
    try std.testing.expectEqual(@as(u3, 5), result.group);
    try std.testing.expectEqual(@as(u3, 5), result.other);
}

test "modeToKind: maps raw stat mode bits to the correct Kind" {
    try std.testing.expectEqual(.directory, modeToKind(0o040755));
    try std.testing.expectEqual(.file, modeToKind(0o100644));
    try std.testing.expectEqual(.sym_link, modeToKind(0o120777));
    try std.testing.expectEqual(.unix_domain_socket, modeToKind(0o140755));
    try std.testing.expectEqual(.character_device, modeToKind(0o020666));
    try std.testing.expectEqual(.block_device, modeToKind(0o060660));
    try std.testing.expectEqual(.named_pipe, modeToKind(0o010644));
    try std.testing.expectEqual(.unknown, modeToKind(0));
}
