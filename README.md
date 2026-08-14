# lsz

A very minimal implementation of the `ls` command.

`lsz` currently supports macOS only. Linux and Windows support are planned.

## Usage

```
lsz [path] [options]
```

If `path` is not provided, `lsz` lists the current directory.

### Options

| Option | Description |
|--------|-------------|
| `-a, --all` | Show all files, including hidden files |
| `-l, --list` | Show output in long list format |
| `-h, --human` | Print file sizes in human readable format (e.g. `1K`, `234M`, `2G`) |
| `-s, --sort <field>` | Sort the result by one of: `name`, `size`, `created`, `modified`, `accessed` |
| `-r, --reverse` | Reverse the sort order (only has an effect together with `-s`/`--sort`) |
| `-t, --timezone <tz>` | Show dates in a specific timezone using tz database names (e.g. `Asia/Makassar`). Only has an effect together with `-l`/`--list` |
| `--help` | Show this help message |

`lsz` also reads the `TZ` environment variable as a fallback for `-t`/`--timezone`. If both are set, `-t`/`--timezone` takes priority. Without either, dates are shown in UTC.

### Examples

```
lsz /path -l -a
lsz /path -la
lsz -la /path
lsz
lsz /path -l
lsz /path -a
lsz -l
lsz -a
lsz -lh /path
lsz /path -la --sort name
lsz /path -lar --sort created
lsz -s size -r
lsz /path -lah -t Asia/Makassar
TZ=Asia/Makassar lsz /path -lah
```

## Supported Platforms

- [x] macOS
- [ ] Linux
- [ ] Windows

## Roadmap

Planned features:

- Linux and Windows support
