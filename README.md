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
| `-a` | Show all files, including hidden files |
| `-l` | Show output in long list format |

### Examples

```
lsz /path -l -a
lsz
lsz /path -l
lsz /path -a
lsz -l
lsz -a
```

## Supported Platforms

- [x] macOS
- [ ] Linux
- [ ] Windows

## Roadmap

Planned features:

- Linux and Windows support
- `-h` for human readable file sizes & timestamps
- `-s` for sorting by one of the following criteria:
  - filesize
  - name
  - created date
  - modified date
  - accessed date
- `-sr` for reverse sort
