# LinuxRunner Patches for Linux Desktop Support

Do not modify `upstreams/linuxrunner/` directly in this repository; apply these
patches onto a clean copy or staging checkout before building with Meson.

## Patch Series

1. **`0001-fakefs-case-insensitive-host.patch`**
   - **Why needed:** macOS APFS and the iOS Simulator host filesystem are
     case-insensitive (`fpathconf(root_fd, _PC_CASE_SENSITIVE) == 0`). Ubuntu
     26.04 packages required for Xfce (`perl-modules-5.40`: `Pod/` vs `pod/`,
     `libperl5.40`: `Sys/` vs `sys/`, `thunar`: `/usr/bin/Thunar` vs
     `/usr/bin/thunar`) contain sibling entries whose names differ only by ASCII
     case. Unpatched `fakefs` records case-sensitive paths in `meta.db` while
     passing unmangled names directly to `realfs`, causing `dpkg` unpack
     failures (`Directory not empty` / `No such file or directory`).
   - **How it works:**
     - Detects host case-insensitivity via `fpathconf(root_fd, _PC_CASE_SENSITIVE)`
       in `fake_db_init()` (`fs/fake-db.c`).
     - Adds a `case_aliases (guest_path blob primary key, host_path blob unique)`
       table in `meta.db`, cached in memory under `fs->lock` and invalidated
       on `fs->generation` / `db_rollback()`.
     - Translates guest paths to disambiguated host paths (`<name>.#ish#<seq>`)
       on collision during `open(O_CREAT)`, `mkdir`, `symlink`, `mknod`, `link`,
       and `rename`, while enforcing negative lookups against `meta.db` so
       non-existent lowercase paths never alias onto existing uppercase siblings.
     - Reverses aliases on `readdir` and `getpath` so guest directory listings,
       `getcwd()`, and `/proc/self/fd` always observe exact POSIX names.
     - Retries with `.#ish#<seq>` on host `EEXIST` (the iOS Simulator makes
       `fstatat` lookups case-sensitive while underlying APFS rejects
       case-colliding creates/renames with `EEXIST`).

2. **`0002-fakefs-import-case-aliases-and-filters.patch`**
   - **Why needed:** Rootfs archives for Debian (`PAM.7.gz` vs `pam.7.gz`),
     Fedora 45 (`terminfo/A` vs `a`, `_Exit.2.gz` vs `_exit.2.gz`,
     `NAN.3.gz` vs `nan.3.gz`), and custom `.tar.zst`/`.tar.bz2` images trigger
     three failures during archive import and first mount: `tools/fakefs.c`
     lacked `bzip2`/`zstd` filters, collided on APFS without recording
     `case_aliases` (and rejected newer `libarchive` UTF-8 PAX warnings
     lacking a trailing period), and `fs/fake-rebuild.c` passed raw guest
     paths to `fstatat`/`unlinkat`/`linkat` during initial `db_inode` rebuild,
     collapsing distinct aliased files onto the same host inode.
   - **How it works:**
     - Enables `archive_read_support_filter_bzip2` and
       `archive_read_support_filter_zstd` and accepts optional trailing `.`
       in `pax_original_names()`.
     - Allocates `.#ish#<seq>` host names (including `EEXIST`-fallback retry on
       the iOS Simulator) and populates `case_aliases` during
       `fakefs_import_contents()` when `_PC_CASE_SENSITIVE == 0`.
     - Resolves `case_aliases` inside `fakefs_rebuild()` before calling
       `fstatat`/`unlinkat`/`linkat` so distinct aliased files keep distinct
       host inodes and `stats` entries on first boot.

## Applying and Building (macOS Host Test Binary)

```sh
# Copy upstream engine to an isolated staging tree under build/
mkdir -p build/linux/src-patched
rsync -a --exclude='.git' --exclude='build' upstreams/linuxrunner/ build/linux/src-patched/

# Apply patches listed in series
while IFS= read -r patch; do
  [ -n "$patch" ] && git -C build/linux/src-patched apply "$PWD/engines/linux-desktop/patches/$patch"
done < engines/linux-desktop/patches/series

# Configure and build matching scripts/fetch-starter-rootfs.sh host options
meson setup build/linux/host-patched build/linux/src-patched \
  -Dengine=asbestos -Dguest_arch=arm64 -Djit=false -Dvdso_required=true
ninja -C build/linux/host-patched ish
```

## Notes for iOS Integration

- `0001-fakefs-case-insensitive-host.patch` can also be added to Triptych's
  `scripts/apply-upstream-fixes.sh` / Xcode build step when promoting
  `linux-desktop` out of staging (`engines/linux-desktop/`).
- No other blocking syscall or `ioctl` gaps were encountered while installing or
  running `xfce4` 4.20.1, `xvfb`, `tigervnc-standalone-server`, `dbus-x11`, or
  Mesa 26.0.8 `llvmpipe`. Non-blocking `seccomp` (`277`), `setfsuid` (`151`),
  and `setfsgid` (`152`) stubs and `TCGETS2`/`TIOCGWINSZ`/`FICLONE` `ioctl`
  probes fall back gracefully in `/proc/ish/compat`.
