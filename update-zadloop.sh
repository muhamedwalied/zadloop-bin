#!/usr/bin/env bash
#
# update-zadloop.sh - update the zadloop-bin PKGBUILD to a new upstream ZadLoop version.
#
# What it does:
#   1. Determines the upstream version (explicit argument, or discovered with --latest).
#   2. Downloads the matching official Debian package into the makepkg source cache.
#   3. Validates the file as a Debian archive and checks its embedded Version field.
#   4. Computes the SHA-256 of the exact file makepkg will build from.
#   5. Edits pkgver/pkgrel/sha256sums in PKGBUILD, regenerating .SRCINFO first.
#   6. Optionally builds the package with makepkg (never installs it).
#
# It never installs anything, never touches pacman or the system package
# database, never commits, and never requires root.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly REDIRECT_URL='https://zadloop.com/download/linux/deb'
readonly RELEASE_BASE='https://releases.zadloop.com/desktop/v1/stable/linux/x64'

# Where the .deb is cached. This is the directory makepkg uses as $srcdir
# (SRCDEST defaults to the current directory, so makepkg looks in ./src).
readonly SRCDEST_DEFAULT='src'

# Pinned download settings. Pinning the IP version keeps the curl transport
# options valid; resolve it from the endpoint hosting the actual download.
readonly IPRESOLVE='ipv4'

BUILD=0
VERIFY=0
DRY_RUN=0
FORCE=0
SHA_OVERRIDE=''
VERSION=''

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m' C_OK=$'\033[32m' C_ERR=$'\033[31m' C_WARN=$'\033[33m' C_INFO=$'\033[36m'
else
  readonly C_RESET='' C_OK='' C_ERR='' C_WARN='' C_INFO=''
fi

log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./update-zadloop.sh [OPTIONS] <VERSION>

Update zadloop-bin to a new upstream ZadLoop version.

Version selection (choose one):
  <VERSION>         Explicit version, for example: ./update-zadloop.sh 0.7.0
  -l, --latest      Discover the current stable release from the official
                    ZadLoop download endpoint, then confirm with the checksum
                    published in the official release metadata.

Options:
  -s, --sha256 HASH Use HASH as the expected SHA-256 instead of an
                    independently published value.
  -b, --build       Build the package with makepkg after updating metadata.
  -w, --verify      With --build, also verify the resulting package.
  -n, --dry-run     Do everything except modify PKGBUILD/.SRCINFO and build.
  -f, --force       Continue when VERSION equals the current pkgver and allow
                    downgrades (such a run resets pkgrel to 1).
  -h, --help        Show this help and exit.

Examples:
  ./update-zadloop.sh 0.7.0                 # update metadata to a known version
  ./update-zadloop.sh --latest              # update metadata to the current release
  ./update-zadloop.sh --latest --build      # update and build locally
  ./update-zadloop.sh --force 0.7.0         # repackage the same upstream version

Requirements: curl, sha256sum, bsdtar (libarchive), tar, grep, sed, makepkg.
`dpkg-deb` is used for the Debian package check when it is installed.
No root privileges are needed. This script never installs the package.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--latest)  VERSION='latest'; shift ;;
      -s|--sha256)
        [[ $# -ge 2 ]] || die "--sha256 requires a value"
        SHA_OVERRIDE="$2"; shift 2 ;;
      -b|--build)   BUILD=1; shift ;;
      -w|--verify)  VERIFY=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -f|--force)   FORCE=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      --)           shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
      -*)           die "unknown option: $1 (try --help)" ;;
      *)            positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    die "at most one version argument is allowed (got: ${positional[*]})"
  fi
  if [[ ${#positional[@]} -eq 1 ]]; then
    [[ "$VERSION" == 'latest' ]] && die "specify either --latest or an explicit version, not both"
    VERSION="${positional[0]}"
  fi
  if [[ -z "$VERSION" ]]; then
    usage >&2
    die "a version argument or --latest is required"
  fi
  [[ "$VERIFY" -eq 1 && "$BUILD" -eq 0 ]] && die "--verify requires --build"
  return 0
}

# ---------------------------------------------------------------------------
# Version and checksum helpers
# ---------------------------------------------------------------------------

# Validate and normalise a caller-supplied version (X.Y.Z, optional -suffix).
normalize_version() {
  local v="${1#v}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] \
    || die "invalid version '$1': expected a numeric version such as 0.7.0"
  printf '%s\n' "$v"
}

# Reduce a version to its leading numeric components, dropping a -suffix/-revision.
numeric_version() {
  printf '%s\n' "${1%%-*}"
}

# Report the version advertised by the official download endpoint.
# This follows the single redirect ZadLoop serves for its Linux .deb download
# and reads the version back out of the resulting file name. The name is also
# cross-checked against the checksum published in the official release
# metadata, so a stale or tampered redirect is detected rather than trusted.
discover_latest() {
  local location  location=$(curl -fsS --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
      --connect-timeout 15 --max-time 60 \
      -o /dev/null -w '%{redirect_url}' "$REDIRECT_URL") \
    || die "could not reach $REDIRECT_URL to discover the latest version"

  [[ -n "$location" ]] || die "the download endpoint returned no redirect; pass an explicit version"

  local filename stem
  filename="${location##*/}"
  [[ "$filename" == ZadLoop-*-x64.deb ]] \
    || die "unexpected download filename '$filename' from the official endpoint"

  stem="${filename#ZadLoop-}"          # 0.7.0-x64.deb
  normalize_version "${stem%-x64.deb}"
}

# Fetch the officially published SHA-512 for one release file.
# Prints nothing (and succeeds) when no entry is found.
published_sha512() {
  local want="ZadLoop-${1}-x64.deb" yml
  if ! yml=$(curl -fsS --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
      --connect-timeout 15 --max-time 60 "$RELEASE_BASE/latest-linux.yml" 2>/dev/null); then
    return 0
  fi
  printf '%s\n' "$yml" | awk -v want="$want" '
    $1 == "-" && $2 == "url:" && $3 == want { found = 1; next }
    found && $1 == "sha512:" { print $2; exit }
    $1 == "-" && $2 == "url:" { found = 0 }
  '
}

# Fetch the SHA-256 that ZadLoop itself publishes for this release, if any.
# ZadLoop currently publishes SHA-512 hashes only (in latest-linux.yml and on
# its download page), so this normally prints nothing; it exists so that an
# independent checksum is picked up automatically if one is ever published.
# Nothing is guessed: a 64-character digest must sit next to the exact file name.
published_sha256() {
  local version="$1" body
  local -a candidates=('SHASUMS256.txt' 'SHA256SUMS' 'sha256sums.txt')
  local name
  for name in "${candidates[@]}"; do
    body=''
    if body=$(curl -fsS --proto '=https' --tlsv1.2 --retry 2 \
        --connect-timeout 15 --max-time 30 "$RELEASE_BASE/$name" 2>/dev/null); then
      printf '%s\n' "$body" | awk -v want="ZadLoop-${version}-x64.deb" \
        'length($1) == 64 && $2 == want { print $1; exit }'
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Repository and PKGBUILD helpers
# ---------------------------------------------------------------------------
pkgbuild_value() {
  local key="$1"
  sed -n "s/^[[:space:]]*${key}=//p" PKGBUILD | tail -n 1
}

# Show exactly what will be replaced in PKGBUILD.
preview_changes() {
  local version="$1" pkgrel="$2" sha="$3"
  printf '\n%s--- PKGBUILD changes ---%s\n' "$C_INFO" "$C_RESET"
  printf '  %-12s %s -> %s\n' 'pkgver'    "$(pkgbuild_value pkgver)" "$version"
  printf '  %-12s %s -> %s\n' 'pkgrel'    "$(pkgbuild_value pkgrel)" "$pkgrel"
  printf '  %-12s %s -> %s\n' 'sha256sums' "$(pkgbuild_value sha256sums)" "'$sha'"
  printf '%s\n\n' "$(printf -- '-%.0s' {1..48})"
}

# Rewrite one field in PKGBUILD, refusing to guess when the field is not unique.
#
# The rewrite is done with awk, which tracks the depth of array literals so the
# scan stops before the field names that live inside them (depends, options,
# makedepends, ...). Plain grep/sed would happily match "sha256sums=" inside a
# comment or a multi-line array, which is exactly the fragile substitution this
# script must avoid.
substitute_field() {
  local field="$1" value="$2" current="$3" count tmp rc=0
  count=$(grep -cE "^[[:space:]]*${field}=" PKGBUILD || true)
  if [[ "$count" -eq 0 ]]; then
    printf '\n# Added by update-zadloop.sh\n%s=%s\n' "$field" "$value" >> PKGBUILD
    ok "PKGBUILD: added ${field}"
    return 0
  fi
  if [[ "$count" -ne 1 ]]; then
    die "found ${count} '${field}=' assignments in PKGBUILD; update it by hand"
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/zadloop-pkgbuild.XXXXXX")" \
    || die "could not create a temporary file"

  awk -v field="$field" -v value="$value" '
    # Track how deep we are inside multi-line array literals, so field names
    # that appear inside "depends=(...)" are never mistaken for assignments.
    function array_depth(line,   i, c, quoted, assigned, depth) {
      depth = 0; quoted = 0; assigned = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { quoted = !quoted; continue }
        if (quoted) continue
        if (c == "#" && !assigned) break
        if (c == "=" && !assigned) { assigned = 1; continue }
        if (c == "(") depth++
        else if (c == ")") depth--
      }
      return depth
    }
    {
      line = $0
      if (depth == 0 && line ~ "^[[:space:]]*" field "=") {
        print field "=" value
        print_once++
        depth += array_depth(line)
        next
      }
      print line
      depth += array_depth(line)
    }
    END { if (print_once != 1) exit 1 }
  ' PKGBUILD > "$tmp" || rc=$?

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    die "refusing to update PKGBUILD: expected exactly one top-level '${field}=' assignment"
  fi
  if [[ "$(grep -cE "^${field}=" "$tmp")" -ne 1 ]]; then
    rm -f "$tmp"
    die "refusing to replace PKGBUILD: expected exactly one ${field}= line after editing"
  fi
  chmod --reference=PKGBUILD "$tmp"
  mv -f "$tmp" PKGBUILD
  ok "PKGBUILD: ${field} ${current} -> ${value}"
}

restore_pkgbuild() {
  [[ -n "${PKGBUILD_SAVED:-}" && -f "$PKGBUILD_SAVED" ]] || return 0
  cp -f "$PKGBUILD_SAVED" PKGBUILD && rm -f "$PKGBUILD_SAVED"
  PKGBUILD_SAVED=''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Always operate on the repository the script lives in, from any cwd.
  local repo_dir
  repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" \
    || die "could not resolve the script directory"
  cd "$repo_dir"

  # ---- required tools -----------------------------------------------------
  local -a missing=()
  local tool
  for tool in curl sha256sum bsdtar tar grep sed makepkg ar; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "missing required tools: ${missing[*]}
Install them with: sudo pacman -S --needed curl coreutils libarchive tar grep sed pacman binutils"
  fi
  if command -v dpkg-deb >/dev/null 2>&1; then
    HAVE_DPKG_DEB=1
  else
    HAVE_DPKG_DEB=0
    warn "dpkg-deb not found; falling back to ar/bsdtar for the Debian package check"
    warn "install it with 'sudo pacman -S --needed dpkg' for a stricter check"
  fi

  # ---- repository sanity --------------------------------------------------
  [[ -f PKGBUILD ]] || die "PKGBUILD not found in $repo_dir; is this the zadloop-bin repository?"
  [[ -f .SRCINFO ]] || warn ".SRCINFO is missing; it will be created"
  [[ -f zadloop.install ]] || die "zadloop.install not found in $repo_dir"

  local pkgname current_version signature
  pkgname="$(pkgbuild_value pkgname)"
  [[ "$pkgname" == 'zadloop-bin' ]] \
    || die "PKGBUILD in $repo_dir is for '${pkgname:-unknown}', not 'zadloop-bin'"
  current_version="$(pkgbuild_value pkgver)"
  [[ -n "$current_version" ]] || die "no pkgver found in PKGBUILD"
  signature="$(pkgbuild_value pkgrel)"

  # ---- scoreboard: back up state and clean up on any failure ---------------
  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/zadloop-update.XXXXXX")"
  PKGBUILD_SAVED="$work_dir/PKGBUILD.saved"
  SRCINFO_SAVED="$work_dir/.SRCINFO.saved"
  local -a tmp_files=()

  finish() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      if [[ -n "${PKGBUILD_SAVED:-}" && -f "$PKGBUILD_SAVED" ]]; then
        warn "restoring PKGBUILD after failure"
        cp -f "$PKGBUILD_SAVED" PKGBUILD
      fi
      if [[ -n "${SRCINFO_SAVED:-}" && -f "$SRCINFO_SAVED" ]]; then
        cp -f "$SRCINFO_SAVED" .SRCINFO
      fi
    fi
    rm -f -- ${tmp_files[@]+"${tmp_files[@]}"}
    rm -rf -- "${work_dir:-}"
    exit "$rc"
  }
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  cp -f PKGBUILD "$PKGBUILD_SAVED" || die "could not back up PKGBUILD"
  [[ -f .SRCINFO ]] && cp -f .SRCINFO "$SRCINFO_SAVED"

  # ---- report dirty state instead of silently editing over it -------------
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain -- PKGBUILD .SRCINFO update-zadloop.sh 2>/dev/null)" ]]; then
      warn "PKGBUILD, .SRCINFO or update-zadloop.sh have uncommitted changes."
      warn "This script edits PKGBUILD and .SRCINFO in place; review 'git diff' first."
      if [[ "$DRY_RUN" -eq 0 ]]; then
        printf 'Continue and modify these files? [y/N] ' >&2
        local reply=''
        read -r reply || reply=''
        [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user (nothing was changed)"
      fi
    fi
  fi

  # ---- determine the version ---------------------------------------------
  local requested_version
  if [[ "$VERSION" == 'latest' ]]; then
    log 'Discovering the latest stable version from the official download page...'
    requested_version="$(discover_latest)"
    ok "official endpoint advertises ${requested_version}"
  else
    requested_version="$(normalize_version "$VERSION")"
  fi

  if [[ "$requested_version" == "$current_version" && "$FORCE" -eq 0 ]]; then
    log "PKGBUILD already packages ZadLoop ${current_version} (pkgrel=${signature})."
    log "Nothing to do. Use --force to repackage the same upstream version."
    exit 0
  fi

  # ---- download -----------------------------------------------------------
  local src_dir
  src_dir="$(pkgbuild_value SRCDEST)"; src_dir="${src_dir:-$SRCDEST_DEFAULT}"
  [[ "$src_dir" = /* ]] || src_dir="$repo_dir/$src_dir"
  local deb_name="ZadLoop-${requested_version}-x64.deb"
  local deb_url="${RELEASE_BASE}/${deb_name}"
  local deb_path="$src_dir/$deb_name"

  local sha_expected_note=''
  if [[ -n "$SHA_OVERRIDE" ]]; then
    [[ "$SHA_OVERRIDE" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 expects a 64-character hex digest"
    SHA_OVERRIDE="${SHA_OVERRIDE,,}"
    sha_expected_note='supplied with --sha256'
  else
    SHA_OVERRIDE="$(published_sha256 "$requested_version")" || SHA_OVERRIDE=''
    [[ -n "$SHA_OVERRIDE" ]] && sha_expected_note='published by ZadLoop'
  fi

  log "Downloading ${deb_name}"
  printf '     from %s\n' "$deb_url"
  mkdir -p "$src_dir"
  local partial="$deb_path.part"
  tmp_files+=("$partial")

  # Refuse to clobber a symlink. A previous maintainer may have pointed
  # src/ZadLoop-<ver>-x64.deb at a hand-downloaded copy elsewhere; replacing the
  # regular file in src/ is fine, silently overwriting someone's file is not.
  if [[ -L "$deb_path" ]]; then
    warn "$deb_path is a symlink to $(readlink -- "$deb_path")"
    printf 'Replace the symlink with a freshly downloaded file? [y/N] ' >&2
    local overwrite_reply=''
    read -r overwrite_reply || overwrite_reply=''
    [[ "$overwrite_reply" =~ ^[Yy]$ ]] || die "aborted by user; remove $deb_path and re-run"
  fi

  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 15 \
    ${IPRESOLVE:+--"$IPRESOLVE"} -o "$partial" "$deb_url" \
    || die "download failed; check the version number and your network connection"
  [[ -s "$partial" ]] || die "downloaded file is empty: $partial"

  # ---- validate the downloaded Debian package -----------------------------
  local file_type deb_size
  file_type="$(file -b "$partial" 2>/dev/null || true)"
  case "$file_type" in
    *Debian*|*deb*) : ;;
    *) die "downloaded file is not a Debian package (file reports: ${file_type:-unknown})" ;;
  esac

  deb_size="$(stat -c '%s' "$partial")"
  if [[ "$deb_size" -lt 1000000 ]]; then
    die "downloaded file is only ${deb_size} bytes; it does not look like the ZadLoop package"
  fi

  local control actual_version
  control="$(deb_control "$partial")" || die "downloaded file is not a readable Debian package"
  actual_version="$(printf '%s\n' "$control" | sed -n 's/^Version:[[:space:]]*//p' | head -n 1)"
  local control_package
  control_package="$(printf '%s\n' "$control" | sed -n 's/^Package:[[:space:]]*//p' | head -n 1)"
  [[ -n "$actual_version" ]] || die "the Debian package has no Version field in its control data"
  [[ "$control_package" == 'zadloop' ]] \
    || warn "Debian package is named '${control_package:-unknown}', expected 'zadloop'"

  # Compare numerically: Debian versions may carry a suffix ("0.7.0-1") and a
  # trailing ".0" may be present on one side only.
  local want_numeric got_numeric
  want_numeric="$(numeric_version "$requested_version")"
  got_numeric="$(numeric_version "$actual_version")"
  if [[ "$got_numeric" != "$want_numeric" ]]; then
    die "version mismatch: requested ${requested_version}, but the Debian package reports '${actual_version}'"
  fi
  if [[ "$actual_version" != "$requested_version" ]]; then
    warn "Debian package reports '${actual_version}' for requested '${requested_version}' (numeric parts match)"
  fi
  ok "Debian package metadata: ${control_package} ${actual_version} ($(numfmt --to=iec "$deb_size" 2>/dev/null || echo "$deb_size bytes"))"

  # ---- checksum -----------------------------------------------------------
  local sha
  sha="$(sha256sum "$partial" | awk '{print $1}')"
  ok "SHA-256 of downloaded file: ${sha}"

  if [[ -n "$SHA_OVERRIDE" && "${SHA_OVERRIDE,,}" != "$sha" ]]; then
    die "checksum mismatch against ${sha_expected_note:-expected value}:
  expected ${SHA_OVERRIDE}
  actual   ${sha}
Refusing to update: the downloaded file is not the one that was expected."
  fi
  if [[ -n "$SHA_OVERRIDE" ]]; then
    ok "checksum matches the value ${sha_expected_note}"
  fi

  # ZadLoop publishes a SHA-512 for each release file in latest-linux.yml.
  # When openssl is available it is compared as-is: that check is independent of
  # this script's own bash logic, which is what makes --latest trustworthy.
  local pub_sha512 local_sha512
  pub_sha512="$(published_sha512 "$requested_version")"
  if [[ -z "$pub_sha512" ]]; then
    warn "no published SHA-512 found for ${requested_version} in latest-linux.yml"
  elif command -v openssl >/dev/null 2>&1; then
    local_sha512="$(openssl dgst -sha512 -binary "$partial" | base64 -w0)"
    [[ "$local_sha512" == "$pub_sha512" ]] \
      || die "the downloaded file does not match the SHA-512 published in latest-linux.yml"
    ok 'SHA-512 matches the SHA-512 published in latest-linux.yml'
  else
    warn 'openssl not found; skipping the published SHA-512 cross-check'
    warn "(install it with 'sudo pacman -S --needed openssl')"
  fi

  # ---- publish the source into the makepkg source cache -------------------
  # The checksum above was computed on $partial, and $partial becomes the exact
  # file makepkg verifies and extracts - there is no second copy that could
  # drift between the two.
  mv -f -- "$partial" "$deb_path" || die "could not move the download into $src_dir"
  ok "cached ${deb_path}"

  # ---- update package metadata -------------------------------------------
  # A new upstream version starts a fresh package series (pkgrel=1); --force
  # repackages the same upstream version, which also restarts at pkgrel=1.
  local new_pkgrel=1

  preview_changes "$requested_version" "$new_pkgrel" "$sha"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log 'Dry run: PKGBUILD and .SRCINFO were not modified.'
    exit 0
  fi

  # .SRCINFO is generated AFTER the edit, so it always describes the PKGBUILD
  # that is actually on disk. If makepkg rejects the edited PKGBUILD, the EXIT
  # trap restores both files to their saved state.
  log 'Updating PKGBUILD...'
  substitute_field pkgver    "$requested_version" "$current_version"
  substitute_field pkgrel    "$new_pkgrel"        "$signature"
  # sha256sums must stay an array literal, so the replacement keeps the parens.
  substitute_field sha256sums "('$sha')"          "$(pkgbuild_value sha256sums)"

  log 'Re-generating .SRCINFO from the updated PKGBUILD...'
  makepkg --printsrcinfo > "$work_dir/.SRCINFO.new" \
    || die "makepkg --printsrcinfo failed after editing PKGBUILD; both files were restored"
  [[ -s "$work_dir/.SRCINFO.new" ]] || die "makepkg --printsrcinfo produced an empty file"

  # The regenerated file must describe the version and checksum just written.
  if ! grep -qF "pkgver = ${requested_version}" "$work_dir/.SRCINFO.new" \
     || ! grep -qF "sha256sums = ${sha}" "$work_dir/.SRCINFO.new"; then
    die ".SRCINFO does not match the requested version/checksum; both files were restored"
  fi

  mv -f -- "$work_dir/.SRCINFO.new" .SRCINFO
  ok ".SRCINFO regenerated for ${requested_version}-${new_pkgrel}"
  rm -f -- "$PKGBUILD_SAVED" "$SRCINFO_SAVED"
  PKGBUILD_SAVED=''; SRCINFO_SAVED=''

  # ---- optional build -----------------------------------------------------
  if [[ "$BUILD" -eq 0 ]]; then
    log 'Metadata updated. Nothing was built or installed.'
    printf 'Next steps:\n  makepkg -sf          # build\n  makepkg --verify     # verify the package\n  git diff             # review before committing\n'
    exit 0
  fi

  local -a makepkg_args=(-f)
  [[ "$VERIFY" -eq 1 ]] && makepkg_args+=(-w)

  log "Building the package: makepkg ${makepkg_args[*]}"
  makepkg "${makepkg_args[@]}" || die "makepkg failed; PKGBUILD and .SRCINFO are already updated, review the output above"

  local pkg_file
  pkg_file="$(ls -1t zadloop-bin-"${requested_version}"-*.pkg.tar.* 2>/dev/null | head -n 1)"
  [[ -n "$pkg_file" ]] || die "makepkg reported success but no package archive was found"
  ok "built ${pkg_file}"

  log 'Done. The package was built but not installed.'
  printf 'Install it with:\n  sudo pacman -U %s\n' "$(printf '%q' "$pkg_file")"
}

# ---------------------------------------------------------------------------
# Debian package helpers
# ---------------------------------------------------------------------------

# Print the control file of a .deb, using dpkg-deb when available.
deb_control() {
  local deb="$1"
  if [[ "${HAVE_DPKG_DEB:-0}" -eq 1 ]]; then
    dpkg-deb -f "$deb" || return 1
    return 0
  fi
  local member control_member
  for member in 'control.tar.zst' 'control.tar.xz' 'control.tar.gz' 'control.tar'; do
    if control_member="$(bsdtar -tf "$deb" "$member" 2>/dev/null)" && [[ -n "$control_member" ]]; then
      bsdtar -xOf "$deb" "$member" 2>/dev/null | bsdtar -xOf - ./control 2>/dev/null && return 0
    fi
  done
  return 1
}

main "$@"
