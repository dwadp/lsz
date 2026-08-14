const std = @import("std");
const clap = @import("clap");
const builtin = @import("builtin");
const stat = @import("stat.zig");
const tempora = @import("tempora");
const table = @import("table.zig");
const entry = @import("entry.zig");
const listing = @import("listing.zig");
const build_config = @import("build_config");

const program_version = build_config.program_version;
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
    \\  -h, --human     Print a human readable format information. Will print sizes like 1K 234M 2G etc
    \\  -s, --sort      Sort the result in ascending order given the fields (name, size, created, modified, accessed)
    \\  -r, --reverse   Reverse the sorting result
    \\  -t, --timezone  Specify an IANA tz database timezone, e.g. Asia/Makassar. This only works if you pass (-l or --list) option
    \\  --output-type   Specify the output format (csv or tsv)
    \\  -v, --version   Print lsz version
    \\  --help          Show this help message
    \\
    \\Examples:
    \\  lsz
    \\  lsz -a
    \\  lsz -l
    \\  lsz /path -l -a
    \\  lsz /path -la --sort name
    \\  lsz /path -lar --sort created
    \\  lsz /path -lah -t Asia/Makassar
    \\  TZ=Asia/Makassar lsz /path -lah
;

const main_params = clap.parseParamsComptime(
    \\--help                Display this help and exit.
    \\-l, --list            Use a long listing format
    \\-a, --all             List all files and do not ignore entries starting with .
    \\-h, --human           Print a human readable format information. Will print sizes like 1K 234M 2G etc
    \\-s, --sort <str>      Sort the result in ascending order given the fields: name, size, created, modified, accessed
    \\-r, --reverse         Reverse the sorting result
    \\-t, --timezone <str>  Specify an IANA tz database timezone, e.g. Asia/Makassar. This only works if you pass (-l or --list) option
    \\--output-type <str>   Specify the output format (csv or tsv)
    \\-v, --version         Print lsz version
    \\<str>
    \\
);

var show_long_list_format = false;
var show_all = false;
var show_human_readable = false;
var sort_field: ?entry.SortField = null;
var reverse_sort: bool = false;

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

    var tzdb = tempora.TZDB.init(init);
    defer tzdb.deinit();
    try tzdb.add(init.io, tempora.tz.all, .system(init.environ_map));

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
        try writeAndFlush(stdout, "{s}\n", .{help_text});
        return;
    }

    if (res.args.version == 1) {
        try writeAndFlush(stdout, "{s}\n", .{program_version});
        return;
    }

    if (res.args.sort) |s| {
        if (std.mem.eql(u8, s, "name")) {
            sort_field = .name;
        } else if (std.mem.eql(u8, s, "size")) {
            sort_field = .size;
        } else if (std.mem.eql(u8, s, "created")) {
            sort_field = .created;
        } else if (std.mem.eql(u8, s, "modified")) {
            sort_field = .modified;
        } else if (std.mem.eql(u8, s, "accessed")) {
            sort_field = .accessed;
        } else {
            try stderr.print("unsupported param value for sort: {s}\n", .{s});
            try stderr.flush();

            std.process.exit(1);
        }
    }

    if (sort_field) |_| {
        if (res.args.reverse == 1) {
            reverse_sort = true;
        }
    }

    const allocator = arena.allocator();
    var path: []const u8 = ".";

    if (res.positionals[0]) |path_arg| {
        path = path_arg;
    }

    show_all = res.args.all == 1;
    show_long_list_format = res.args.list == 1;
    show_human_readable = res.args.human == 1;

    var tz: tempora.Timezone = tempora.Timezone.utc;
    const tz_str: []const u8 = if (res.args.timezone) |t| t else if (init.environ_map.get("TZ")) |t| t else "";

    if (tzdb.timezone(tz_str)) |t| {
        tz = t.*;
    }

    var out_type: listing.OutputType = .table;
    const out_type_str = if (res.args.@"output-type") |o|
        o
    else if (init.environ_map.get("OUT_TYPE")) |o|
        o
    else
        "";

    if (std.mem.eql(u8, out_type_str, "csv")) {
        out_type = .csv;
    } else if (std.mem.eql(u8, out_type_str, "tsv")) {
        out_type = .tsv;
    }

    run(allocator, io, &stdout_impl.interface, path, tz, out_type) catch |err| switch (err) {
        error.FileNotFound => {
            stderr.print("No such file or directory: {s}\n", .{path}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

fn writeAndFlush(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    writer.print(fmt, args) catch |err| {
        std.log.warn("failed to print: {}\n", .{err});
        return err;
    };

    writer.flush() catch |err| {
        std.log.warn("failed to flush stdout: {}\n", .{err});
        return err;
    };
}

fn run(alloc: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8, tz: tempora.Timezone, out_type: listing.OutputType) !void {
    const basename = std.fs.path.basename(path);
    const dirname = std.fs.path.dirname(path) orelse ".";
    const open_dir_options: std.Io.Dir.OpenOptions = .{ .iterate = true, .follow_symlinks = false };
    const cwd = std.Io.Dir.cwd();

    const obj_stat = try cwd.statFile(io, path, .{ .follow_symlinks = false });

    var entries = std.ArrayList(entry.Entry).empty;
    defer entries.deinit(alloc);

    if (obj_stat.kind == .directory) {
        const dir = try cwd.openDir(io, path, open_dir_options);
        defer dir.close(io);

        var iterator = dir.iterate();

        while (try iterator.next(io)) |e| {
            if (!show_all and std.mem.startsWith(u8, e.name, ".")) {
                continue;
            }

            try entries.append(alloc, try entry.buildEntry(alloc, io, dir, e.name));
        }
    } else if (obj_stat.kind != .unknown) {
        const dir = try cwd.openDir(io, dirname, open_dir_options);
        defer dir.close(io);

        try entries.append(alloc, try entry.buildEntry(
            alloc,
            io,
            dir,
            basename,
        ));
    } else {
        return error.UnknownFile;
    }

    if (sort_field) |s| {
        const sort = entry.Sort.init(s, reverse_sort, entries.items);
        sort.sort();
    }

    if (show_long_list_format) {
        try listing.printLongListFormat(alloc, writer, entries, show_human_readable, tz, out_type);
    } else {
        try listing.printDefault(writer, entries);
    }
}

test {
    std.testing.refAllDecls(@This());
}
