# zadloop-bin

An unofficial Arch Linux package for [ZadLoop](https://zadloop.com/), repackaged from its official Debian package for Arch Linux and Arch-based distributions such as [Omarchy](https://omarchy.org/).

This project is community-maintained and is **not affiliated with, endorsed by, or supported by ZadLoop**.

## Features

- Installs ZadLoop under `/opt/ZadLoop`.
- Provides the `zadloop` command and upstream desktop entry.
- Downloads the original application package from ZadLoop's release server during the build.
- Disables the application's built-in updater so updates can be managed through package installation.

## Supported platform

- **Architecture:** x86_64 only.
- **Distributions:** Arch Linux and compatible Arch-based distributions.
- **Desktop:** A working graphical session using X11 or Wayland.

ZadLoop does not currently provide an upstream Linux package specifically for Arch Linux. This repository adapts its Debian package for Arch-based systems.

## Requirements

Install the required build and download tools:

```sh
sudo pacman -S --needed base-devel git curl coreutils libarchive binutils file
```

Optional tools for additional package checks:

```sh
sudo pacman -S --needed dpkg openssl
```

- `makepkg` builds the Arch package.
- `dpkg-deb` provides additional Debian package metadata checks.
- `openssl` enables verification against the SHA-512 checksum published in ZadLoop's release metadata.

You will need several GiB of free disk space for building, plus approximately 1.1 GiB for the installed application. Actual requirements may vary by release.

**Do not run `makepkg` as root.**

## Build and install

Clone the repository and enter its directory:

```sh
git clone https://github.com/muhamedwalied/zadloop-bin.git
cd zadloop-bin
```

Build the package:

```sh
makepkg -f
```

After a successful build, install the generated package:

```sh
sudo pacman -U ./zadloop-bin-*.pkg.tar.zst
```

Alternatively, build and install in one step:

```sh
makepkg -si
```

The build downloads the version specified in `PKGBUILD`, verifies it against the configured SHA-256 checksum, and creates an Arch package in the current directory.

This package is not available through the official Arch repositories. You must build and install it using one of the methods above.

## Run ZadLoop

Launch ZadLoop from your desktop application menu or run:

```sh
zadloop
```

## Update ZadLoop

The built-in application updater is disabled in this package. To use a newer upstream release, the package must be updated, rebuilt, and installed again.

### For maintainers: prepare a package update

The included `update-zadloop.sh` script updates the packaging metadata. It does not install the application or modify the system package database.

Discover the latest stable release:

```sh
./update-zadloop.sh --latest
```

Update to a specific release:

```sh
./update-zadloop.sh 0.7.0
```

Update the metadata and build the package:

```sh
./update-zadloop.sh --latest --build
```

To see all available options:

```sh
./update-zadloop.sh --help
```

The script can discover the stable release through ZadLoop's official download endpoint, validate the downloaded Debian package, calculate its SHA-256 checksum, and regenerate `.SRCINFO`. When the required verification tool is available, it also checks the SHA-512 value published in ZadLoop's release metadata.

Review the generated changes and test the resulting package before distributing it.

### Install an updated package

After building a newer version, install the generated archive:

```sh
sudo pacman -U ./zadloop-bin-*.pkg.tar.zst
```

Make sure the selected archive is the version you intend to install.

## Troubleshooting

### Download errors

The requested release may not exist, or ZadLoop may have changed its download URL. Check the [official download page](https://zadloop.com/download) and confirm the version.

### Checksum verification fails

A checksum mismatch can indicate an incomplete download or a changed upstream file. Do not bypass the check without understanding the cause. Re-download the package and investigate persistent mismatches.

The SHA-256 in `PKGBUILD` pins the build input and detects unexpected changes, but a locally calculated checksum does not independently authenticate the publisher. The SHA-512 cross-check uses the value published in ZadLoop's release metadata when verification is available.

### `chrome-sandbox` permission errors

Check the sandbox file:

```sh
ls -l /opt/ZadLoop/chrome-sandbox
```

Check whether unprivileged user namespaces are available:

```sh
unshare --user true
```

The package's `zadloop.install` script configures the sandbox permissions during installation. Avoid changing the permissions manually unless you have confirmed that it is necessary and understand the security implications.

### Insufficient disk space

Building requires additional space for the downloaded Debian package and extracted build files. Clean up temporary build files when they are no longer needed, while keeping any files you want to preserve.

## Uninstall

Remove the package with:

```sh
sudo pacman -Rns zadloop-bin
```

Your personal application data in your home directory may remain after uninstalling.

## Links

- [ZadLoop website](https://zadloop.com/)
- [Official download page](https://zadloop.com/download)
- [ZadLoop documentation](https://docs.zadloop.com/)
- [This repository](https://github.com/muhamedwalied/zadloop-bin)
- [Original packaging project](https://github.com/bassam-alaraby/zadloop-bin)

## License

The packaging files and maintenance scripts in this repository are licensed under the MIT License. See [LICENSE](LICENSE).

ZadLoop itself is proprietary software distributed under its own terms. This repository does not redistribute the application binary.
