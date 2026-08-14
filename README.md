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
| `--output-type <format>` | Change the long list output format to `csv` or `tsv` instead of the default aligned table. Only has an effect together with `-l`/`--list` |
| `-v, --version` | Print the `lsz` version |
| `--help` | Show this help message |

`lsz` also reads two environment variables as fallbacks:
- `TZ` — fallback for `-t`/`--timezone`. If both are set, `-t`/`--timezone` takes priority. Without either, dates are shown in UTC.
- `OUT_TYPE` — fallback for `--output-type`. If both are set, `--output-type` takes priority.

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
lsz /path -l --output-type csv
lsz /path -l --output-type tsv > files.tsv
lsz --version
```

## Installation

### Download a release

Prebuilt binaries for each tagged release are published on the [Releases page](https://github.com/dwadp/lsz/releases), covering Linux (x86_64, arm64) and macOS (Intel, Apple Silicon).

```bash
# example for macOS Apple Silicon, replace with the asset matching your platform
curl -LO https://github.com/dwadp/lsz/releases/latest/download/lsz-<version>-macos-arm64.tar.gz
curl -LO https://github.com/dwadp/lsz/releases/latest/download/lsz-<version>-macos-arm64.tar.gz.sha256

# verify the download is intact
shasum -a 256 -c lsz-<version>-macos-arm64.tar.gz.sha256

tar -xzf lsz-<version>-macos-arm64.tar.gz
sudo mv lsz-<version>-macos-arm64/lsz /usr/local/bin/lsz
```

### Build from source

Building from source gets you the latest unreleased features on `main`, ahead of the next tagged release. Requires [Zig 0.16.0](https://ziglang.org/download/).

```bash
git clone https://github.com/dwadp/lsz.git
cd lsz
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/lsz /usr/local/bin/lsz
```

## Supported Platforms

- [x] macOS
- [x] Linux
- [ ] Windows

## Roadmap

Planned features:

- Filter capabilities
- Windows support
