
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 VERSION"
    echo "Example: $0 0.7.1"
    exit 1
fi

VERSION="$1"
CURRENT="$(sed -n 's/^pkgver=//p' PKGBUILD)"
DEB="ZadLoop-${VERSION}-x64.deb"
URL="https://releases.zadloop.com/desktop/v1/stable/linux/x64/${DEB}"
PKG="zadloop-bin-${VERSION}-1-x86_64.pkg.tar.zst"
DB="/var/lib/local-zadloop/local-zadloop.db.tar.gz"

if [[ "$VERSION" == "$CURRENT" ]]; then
    echo "Version $VERSION is already in PKGBUILD."
    echo "This script is for a new upstream version."
    exit 1
fi

mkdir -p src

echo "==> Downloading ZadLoop $VERSION..."
curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 "$URL" -o "src/$DEB"

echo "==> Checking package version..."
CONTROL="$(bsdtar -xOf "src/$DEB" control.tar.xz \
    | xz -dc | tar -xOf - ./control)"
ACTUAL="$(printf '%s\n' "$CONTROL" | sed -n 's/^Version: //p')"

if [[ "$ACTUAL" != "$VERSION" ]]; then
    echo "ERROR: Expected $VERSION, but downloaded package reports '$ACTUAL'."
    exit 1
fi

SHA="$(sha256sum "src/$DEB" | awk '{print $1}')"
echo "==> SHA-256: $SHA"

echo "==> Updating PKGBUILD..."
sed -i \
    -e "s/^pkgver=.*/pkgver=$VERSION/" \
    -e 's/^pkgrel=.*/pkgrel=1/' \
    -e "s/^[[:space:]]*sha256sums=.*/sha256sums=('$SHA')/" \
    PKGBUILD

echo "==> Updating .SRCINFO..."
makepkg --printsrcinfo > .SRCINFO

echo "==> Building package..."
makepkg -f

if [[ ! -f "$PKG" ]]; then
    echo "ERROR: Expected package was not created: $PKG"
    exit 1
fi

echo "==> Adding package to local repository..."
sudo install -m 644 "$PKG" /var/lib/local-zadloop/
sudo repo-add "$DB" "/var/lib/local-zadloop/$PKG"

echo
echo "Done! ZadLoop $VERSION-1 is in local-zadloop."
echo "Install/update with: sudo pacman -S zadloop-bin"

