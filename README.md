# zadloop-bin — unofficial ZadLoop package for Arch Linux

`zadloop-bin` repackages the official [ZadLoop](https://zadloop.com/) Debian
package so it can be built and installed on Arch Linux and Arch-based
distributions such as [Omarchy](https://omarchy.org/).

This is an unofficial community package. It is **not** affiliated with,
endorsed by, or supported by ZadLoop.

## Contents

- [Disclaimer](#disclaimer)
- [What this package is](#what-this-package-is)
- [Supported platform](#supported-platform)
- [Prerequisites](#prerequisites)
- [Get the repository](#get-the-repository)
- [Build the package](#build-the-package)
- [Install the package](#install-the-package)
- [Run and remove ZadLoop](#run-and-remove-zadloop)
- [Update to a new ZadLoop version](#update-to-a-new-zadloop-version)
- [Checking and troubleshooting the build](#checking-and-troubleshooting-the-build)
- [Updating this package vs. updating the application](#updating-this-package-vs-updating-the-application)
- [Notes for maintainers](#notes-for-maintainers)
- [Links](#links)
- [License](#license)

## Disclaimer

ZadLoop is proprietary software published by its own authors. This repository
contains only packaging files (`PKGBUILD`, `zadloop.install`, `update-zadloop.sh`,
documentation); it does **not** redistribute any ZadLoop binary. The `.deb` file
is downloaded from ZadLoop's own release server at build time.

The official Linux downloads from ZadLoop currently target Debian/Ubuntu and
Fedora. Arch Linux is not an officially supported distribution. Use this
package for evaluation, and report packaging problems through
[this repository](https://github.com/muhamedwalied/zadloop-bin) — not to ZadLoop.

## What this package is

- Package name: `zadloop-bin`
- It `provides` and `conflicts` with `zadloop`
- Application format: Electron desktop application, installed into `/opt/ZadLoop`
- A `/usr/bin/zadloop` symlink, so you can start it with the `zadloop` command
- A desktop entry and icons taken from the upstream package
- Upstream version currently packaged: `0.7.0`
- Installed size: roughly 1.1 GiB (the application bundles its own Node and
  Python runtimes)

The in-app updater is disabled during packaging: `app-update.yml` is removed, so
updates are delivered by your package manager instead of ZadLoop modifying
`/opt/ZadLoop` behind pacman's back.

## Supported platform

- Architecture: **`x86_64` only**. ZadLoop publishes only an x64 Linux `.deb`;
  there is no `aarch64` build to repackage.
- Arch Linux and Arch-based distributions, built with `makepkg`.
- A working desktop session (GTK 3, X11 or Wayland) is required to run the GUI.

## Prerequisites

Build tools and the download/verification tools:

```sh
sudo pacman -S --needed base-devel git curl coreutils libarchive binutils file
```

Optional but recommended:

```sh
sudo pacman -S --needed dpkg openssl
```

- `dpkg` provides `dpkg-deb`, used by `update-zadloop.sh` to read the Debian
  package's embedded metadata. Without it, the script falls back to
  `ar`/`bsdtar`.
- `openssl` lets the update script compare the download against the SHA-512 that
  ZadLoop publishes in its own release metadata.

You also need free disk space: about 300 MiB for the `.deb`, several GiB while
building, and about 1.1 GiB installed. `namcap` is optional and only useful for
linting the recipe.

> `makepkg` must **not** be run as root.

## Get the repository

```sh
git clone https://github.com/muhamedwalied/zadloop-bin.git
cd zadloop-bin
```

## Build the package

Building and installing are two separate steps. Building needs no root
privileges.

```sh
makepkg -f          # just build
makepkg -si         # build, then install with pacman (asks for sudo)
```

Expected outcome: `makepkg` downloads `ZadLoop-0.7.0-x64.deb` from
`releases.zadloop.com`, verifies it against the `sha256sums` value in
`PKGBUILD`, and produces a `zadloop-bin-0.7.0-2-x86_64.pkg.tar.zst` archive in
the repository directory.

Useful variants:

```sh
makepkg -f --noconfirm     # build without prompts
makepkg -sf                # rebuild, re-extracting the cached .deb
makepkg -C                 # clean up build leftovers afterwards
makepkg --verify           # verify the finished package after building
```

## Install the package

Only do this after a successful build. Pick whichever method you normally use:

```sh
# Install the archive you just built, with dependencies, via pacman
sudo pacman -U zadloop-bin-0.7.0-2-x86_64.pkg.tar.zst

# Or let makepkg drive the install
makepkg -si
```

> There is **no** `pacman -S zadloop-bin`. This package is not in the official
> Arch repositories and is not published on the AUR (see
> [AUR status](#aur-status)), so `pacman -S zadloop-bin` will fail. Build and
> install the archive with `makepkg` / `pacman -U` as shown above.

During installation, `zadloop.install` fixes up `/opt/ZadLoop/chrome-sandbox`:
it becomes setuid only when your system cannot create unprivileged user
namespaces. On systems with working user namespaces (the usual case on Arch) it
is left non-setuid, which is the safer arrangement.

## Run and remove ZadLoop

Start it from the application menu or from a terminal:

```sh
zadloop
```

Remove it with:

```sh
sudo pacman -Rns zadloop-bin
```

This removes the application and the dependencies installed only for it. It does
not normally delete your personal application data in your home directory.

## Update to a new ZadLoop version

`update-zadloop.sh` is the supported way to move this package to a new upstream
release. It works from the repository directory regardless of your current
working directory and never needs root.

```sh
./update-zadloop.sh 0.7.0               # explicit version
./update-zadloop.sh --latest            # discover the current stable release
./update-zadloop.sh --latest --build    # update metadata, then build
./update-zadloop.sh --help
```

What it does, in order:

1. Resolves the version — from your argument, or, with `--latest`, from
   ZadLoop's own download redirect.
2. Downloads `ZadLoop-<version>-x64.deb` into `src/`, the directory `makepkg`
   uses as its source cache.
3. Verifies the file is a real Debian package (`file`, then `dpkg-deb` or
   `ar`/`bsdtar`) and that its embedded `Version:` matches the requested
   version.
4. Computes the SHA-256 of that exact file — the same file `makepkg` verifies
   and extracts, so the checksum cannot describe a different copy.
5. Cross-checks the download against the SHA-512 ZadLoop publishes in
   `latest-linux.yml` when `openssl` is installed.
6. Rewrites `pkgver`, `pkgrel` and `sha256sums` in `PKGBUILD` (only those lines),
   then regenerates `.SRCINFO` with `makepkg --printsrcinfo`.
7. Optionally builds with `makepkg -f`, adding `makepkg --verify` when you pass
   `--build --verify`.

It never installs anything, never touches `pacman`, `/etc/pacman.conf` or the
system package database, never commits or pushes, and never requires root. If a
critical step fails, it restores `PKGBUILD` and `.SRCINFO` and exits non-zero.

Frequently used options: `--build`, `--verify`, `--dry-run` (do everything
except edit and build), `--force` (repackage the same upstream version),
`--sha256 HASH` (compare against a checksum you obtained yourself).

After a successful run, review and publish as usual:

```sh
git diff                 # confirm only pkgver/pkgrel/sha256sums changed
namcap PKGBUILD          # optional lint
git add PKGBUILD .SRCINFO
git commit -m "Update ZadLoop to <version>"
git push
```

### AUR status

Not published on the AUR yet. If it is published later, updates are pushed with
the standard `ssh aur@aur.archlinux.org` workflow from a checkout of the AUR
repository; this repository stays the development copy.

## Checking and troubleshooting the build

Verify the finished package before installing:

```sh
makepkg --verify                        # integrity check of the archive
pacman -Qip zadloop-bin-*.pkg.tar.zst   # metadata: version, size, dependencies
pacman -Qlp zadloop-bin-*.pkg.tar.zst   # file list
bsdtar -tf zadloop-bin-*.pkg.tar.zst    # raw archive listing
```

`namcap` reports many warnings about the bundled Python/Node runtime and about a
setuid binary. These come from the upstream package, not from this recipe.

**Download fails (404 or connection error).** The version does not exist on
`releases.zadloop.com`, or the URL pattern changed. Confirm the exact file name
on the [official download page](https://zadloop.com/download), then re-run with
that version. The URL pattern is
`https://releases.zadloop.com/desktop/v1/stable/linux/x64/ZadLoop-VERSION-x64.deb`.

**`ERROR: One or more files did not pass the validity check`.** The downloaded
`.deb` does not match `sha256sums`. Usually a truncated download or an upstream
re-release under the same version number. Delete
`src/ZadLoop-<version>-x64.deb` and re-run `./update-zadloop.sh <version>` to
download again and record a fresh checksum.

**Checksum mismatch reported by `update-zadloop.sh`.** The script stopped before
editing anything, deliberately: the file it downloaded is not the file it
expected. Do not force a checksum you cannot explain. Re-download; if the
mismatch persists, investigate the upstream release instead of bypassing the
check.

**`chrome-sandbox` permission errors on launch.** Check the current mode and
whether user namespaces work:

```sh
ls -l /opt/ZadLoop/chrome-sandbox
unshare --user true && echo "user namespaces OK"
```

If user namespaces are unavailable, the sandbox binary needs to be setuid:

```sh
sudo chmod 4755 /opt/ZadLoop/chrome-sandbox
```

`zadloop.install` already does this at install time; you only need it again if
the binary was replaced by a rebuild that skipped the install script.

**Not enough disk space.** Building needs several GiB in the repository
directory. `makepkg -C` frees build leftovers; `pkg/` and `src/` are gitignored
and safe to delete, though deleting `src/` means re-downloading the `.deb`.

**About checksums in `PKGBUILD`.** ZadLoop does not publish a SHA-256. The
`sha256sums` value here is calculated locally from the downloaded file, so it
detects a changed, truncated or corrupted download and pins the exact build
input — it does **not** independently prove that ZadLoop produced that file.
Real publisher verification would need an upstream signature, and none is
published today. The SHA-512 cross-check that `update-zadloop.sh` performs is
the strongest check currently available, because that hash does come from
ZadLoop's own release metadata.

## Updating this package vs. updating the application

These are different operations, and knowing which one you want matters:

- **Updating this package** means editing `PKGBUILD`/`.SRCINFO` to point at a
  newer upstream release and rebuilding. `update-zadloop.sh` does this; it is
  maintainer work.
- **Updating the application you have installed** means installing the newer
  package you built, with `sudo pacman -U ...` or `makepkg -si`. Nothing else
  upgrades it on your system, because the in-app updater is intentionally
  disabled.

In short: a new ZadLoop release does not update your installed copy by itself.
The package must be updated, rebuilt, and reinstalled.

## Notes for maintainers

Before committing and pushing a change:

1. Leave the working tree clean or clearly intentional. `update-zadloop.sh`
   warns when `PKGBUILD`, `.SRCINFO` or itself are dirty, and asks before
   editing.
2. Update metadata and rebuild:

   ```sh
   ./update-zadloop.sh --latest --build --verify
   ```

3. Review the diff — only `pkgver`, `pkgrel` and `sha256sums` should change, and
   `.SRCINFO` must match `PKGBUILD`:

   ```sh
   git diff
   makepkg --printsrcinfo | diff - .SRCINFO && echo ".SRCINFO is in sync"
   bash -n update-zadloop.sh
   git diff --check
   ```

4. Lint and inspect the package:

   ```sh
   namcap PKGBUILD zadloop-bin-*.pkg.tar.zst
   pacman -Qip zadloop-bin-*.pkg.tar.zst
   ```

5. `pkgrel` semantics: bump it when packaging changes but the upstream version
   does not. Use `pkgrel=1` for a newly packaged upstream release.

6. Never commit the `.deb` or the built `*.pkg.tar.zst` — `.gitignore` covers
   both.

7. Test the install on a real system before pushing, and do not force-push or
   rewrite history on this branch.

## Links

- Official ZadLoop website: <https://zadloop.com/>
- Official download page: <https://zadloop.com/download>
- Official documentation: <https://docs.zadloop.com/>
- This repository: <https://github.com/muhamedwalied/zadloop-bin>
- Original upstream packaging repository: <https://github.com/bassam-alaraby/zadloop-bin>

## License

The packaging files in this repository (`PKGBUILD`, `zadloop.install`,
`update-zadloop.sh`, this README) are licensed under the MIT License — see
[LICENSE](LICENSE). ZadLoop itself is proprietary software distributed under its
own terms; this repository does not redistribute it.
