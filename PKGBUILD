# Maintainer: Bassam Tarek Al-Araby <bassamalarabii@gmail.com>
# Contributor: Mohamed Walied <https://github.com/muhamedwalied>
#
# Unofficial repackaging of the official ZadLoop Debian package for Arch Linux.
# Not affiliated with, endorsed by, or supported by ZadLoop.
#
# The sha256sums entry is calculated locally from the downloaded .deb by
# update-zadloop.sh. ZadLoop does not publish a SHA-256, so this checksum
# detects a changed or corrupted download; it does not independently prove
# that the publisher produced the file. ZadLoop publishes SHA-512 hashes in
# https://releases.zadloop.com/desktop/v1/stable/linux/x64/latest-linux.yml,
# which update-zadloop.sh verifies when openssl is available.
pkgname=zadloop-bin
_pkgname=zadloop
pkgver=0.7.0
pkgrel=1
pkgdesc='ZadLoop desktop coding agent (unofficial repackaging of the official Debian package)'
arch=('x86_64')
url='https://zadloop.com/'
license=('LicenseRef-ZadLoop')
depends=(
  alsa-lib
  at-spi2-core
  bubblewrap
  cairo
  dbus
  expat
  gcc-libs
  glib2
  'glibc>=2.39'
  gtk3
  hicolor-icon-theme
  libcups
  libnotify
  libsecret
  libx11
  libxcb
  libxcomposite
  libxdamage
  libxext
  libxfixes
  libxkbcommon
  libxrandr
  libxss
  libxtst
  mesa
  nspr
  nss
  pango
  systemd-libs
  util-linux
  util-linux-libs
  xdg-utils
)
optdepends=('libappindicator: system tray integration')
makedepends=('binutils' 'libarchive')
provides=("${_pkgname}")
conflicts=("${_pkgname}")
options=('!strip' '!debug')
install="${_pkgname}.install"
source=("ZadLoop-${pkgver}-x64.deb::https://releases.zadloop.com/desktop/v1/stable/linux/x64/ZadLoop-${pkgver}-x64.deb")
noextract=("ZadLoop-${pkgver}-x64.deb")
sha256sums=('11b681efada88f73b272f8eaa9c565ba92a98d195593144526eac5a950e0a437')


package() {
  local deb="$srcdir/ZadLoop-${pkgver}-x64.deb"
  local payload

  payload=$(ar t "$deb" | awk '/^data\.tar(\..*)?$/ { print; exit }')
  [[ -n "$payload" ]] || {
    echo 'No Debian data.tar payload found' >&2
    return 1
  }

  install -d "$pkgdir"
  ar p "$deb" "$payload" | bsdtar -xpf - --no-same-owner -C "$pkgdir"

  # Disable the in-app updater: updates are handled by the package manager
  rm -f "$pkgdir/opt/ZadLoop/resources/app-update.yml"

  install -d "$pkgdir/usr/bin"
  ln -s /opt/ZadLoop/zadloop "$pkgdir/usr/bin/zadloop"
}
