const std = @import("std");
const clap = @import("clap");
const builtin = @import("builtin");
const stat = @import("stat.zig");
const tempora = @import("tempora");
const table = @import("table.zig");
const file_entry = @import("file_entry.zig");
const listing = @import("listing.zig");

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

const main_params = clap.parseParamsComptime(
    \\--help        Display this help and exit.
    \\-l, --list    Use a long listing format
    \\-a, --all     List all files and do not ignore entries starting with .
    \\-h, --human   Print a human readable format information. Will print sizes like 1K 234M 2G etc
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
    var path: []const u8 = ".";

    if (res.positionals[0]) |path_arg| {
        path = path_arg;
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
    const basename = std.fs.path.basename(path);
    const dirname = std.fs.path.dirname(path) orelse ".";
    const open_dir_options: std.Io.Dir.OpenOptions = .{ .iterate = true, .follow_symlinks = false };
    const cwd = std.Io.Dir.cwd();

    const obj_stat = try cwd.statFile(io, path, .{ .follow_symlinks = false });

    var entries = std.ArrayList(file_entry.Entry).empty;
    defer entries.deinit(alloc);

    switch (obj_stat.kind) {
        .directory => {
            const dir = try cwd.openDir(io, path, open_dir_options);
            defer dir.close(io);

            var iterator = dir.iterate();

            while (try iterator.next(io)) |entry| {
                if (!show_all and std.mem.startsWith(u8, entry.name, ".")) {
                    continue;
                }

                try entries.append(alloc, try file_entry.buildEntry(alloc, io, dir, entry.name));
            }
        },
        .file, .unix_domain_socket, .sym_link => {
            const dir = try cwd.openDir(io, dirname, open_dir_options);
            defer dir.close(io);

            try entries.append(alloc, try file_entry.buildEntry(
                alloc,
                io,
                dir,
                basename,
            ));
        },
        else => return error.UnknownFile,
    }

    if (show_long_list_format) {
        try listing.printLongListFormat(alloc, writer, entries, show_human_readable);
    } else {
        try listing.printDefault(writer, entries);
        try writer.flush();
    }
}
