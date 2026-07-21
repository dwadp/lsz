const std = @import("std");
const builtin = @import("builtin");

pub const RawStat = struct {
    kind: std.Io.File.Kind,
    size: usize,
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

    return .{
        .mode_bits = .{
            .owner = mode_bits.owner,
            .group = mode_bits.group,
            .other = mode_bits.other,
        },
        .size = toFileSize(c_stat_buf.size),
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
        .mode_bits = .{
            .owner = mode_bits.owner,
            .group = mode_bits.group,
            .other = mode_bits.other,
        },
        .size = toFileSize(statx_buf.size),
        .uid = statx_buf.uid,
        .gid = statx_buf.gid,
        .kind = modeToKind(@as(u32, statx_buf.mode)),
        .created = statxTimestampToTimestamp(statx_buf.btime),
        .modified = statxTimestampToTimestamp(statx_buf.mtime),
        .accessed = statxTimestampToTimestamp(statx_buf.atime),
    };
}

// Convert linux file mode to std.Io.File.Kind
// Need to work on for windows
fn modeToKind(mode: u32) std.Io.File.Kind {
    if (std.c.S.ISDIR(mode)) return .directory;
    if (std.c.S.ISREG(mode)) return .file;
    if (std.c.S.ISLNK(mode)) return .sym_link;
    if (std.c.S.ISSOCK(mode)) return .unix_domain_socket;

    return .unknown;
}

pub fn splitModeBits(mode: u32) struct { owner: u3, group: u3, other: u3 } {
    return .{
        .owner = @intCast((mode >> 6) & 0o7),
        .group = @intCast((mode >> 3) & 0o7),
        .other = @intCast(mode & 0o7),
    };
}

fn toFileSize(size: anytype) usize {
    const T = @TypeOf(size);
    const info = @typeInfo(T).int;

    if (info.signedness == .signed) {
        std.debug.assert(size >= 0);
    }

    return @intCast(size);
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
