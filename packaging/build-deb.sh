#!/usr/bin/env bash
# Builds Vervellum for Linux and packages it as a .deb.
#
#   packaging/build-deb.sh [version]
#
# Run it on the oldest Ubuntu release you intend to support: a .deb links against the
# library versions present at build time, so building on a newer release produces a
# package that will not install on an older one.
set -euo pipefail

VERSION="${1:-0.1.0}"
# The package's own version. Debian reads the *last* hyphen in a version as the start
# of a Debian revision, and a revision sorts above no revision at all — so 1.1.0-beta.1
# would outrank the 1.1.0 that follows it, and apt would refuse the stable package as
# a downgrade. A tilde sorts below everything, which is exactly what a pre-release is:
# 1.1.0~beta.1 < 1.1.0. The tag keeps its hyphen; only the package sees the tilde.
# (Escaped, because bash tilde-expands an unquoted `~` in the replacement to $HOME.)
DEB_VERSION="${VERSION/-/\~}"
APP_ID="ch.lkmc.Vervellum"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/build/deb/vervellum_${DEB_VERSION}"
ARCH="$(dpkg --print-architecture)"

echo "==> Building (release, static Swift runtime)"
# --static-swift-stdlib links Swift's runtime and Foundation into the binary. It does
# *not* statically link glibc, GTK or libcurl, which stay dynamic and are declared as
# dependencies below. The alternative — shipping the toolchain's fourteen .so files —
# would mean owning their security updates.
#
# The musl Static Linux SDK is not an option: it forbids dlopen entirely, and GTK needs
# it for GIO modules, input methods and pixbuf loaders.
cd "$ROOT"
swift build -c release --static-swift-stdlib --product vervellum

BINARY="$(swift build -c release --show-bin-path)/vervellum"
[ -x "$BINARY" ] || { echo "error: $BINARY was not built" >&2; exit 1; }

echo "==> Staging"
rm -rf "$STAGE"
install -d "$STAGE/DEBIAN" \
           "$STAGE/usr/bin" \
           "$STAGE/usr/share/applications" \
           "$STAGE/usr/share/dbus-1/services" \
           "$STAGE/usr/share/doc/vervellum"

install -m 0755 "$BINARY" "$STAGE/usr/bin/vervellum"
strip --strip-unneeded "$STAGE/usr/bin/vervellum" 2>/dev/null || true

sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/debian/$APP_ID.desktop" \
    > "$STAGE/usr/share/applications/$APP_ID.desktop"

# The hicolor tree is exported by media-sources/make_appicon.py from the same
# artwork as the macOS icon, at the sizes GNOME indexes — including 48 and 64,
# which the asset catalog does not carry.
for src in "$ROOT"/packaging/icons/hicolor/*/apps/"$APP_ID.png"; do
    [ -f "$src" ] || continue
    size="$(basename "$(dirname "$(dirname "$src")")")"
    install -D -m 0644 "$src" "$STAGE/usr/share/icons/hicolor/$size/apps/$APP_ID.png"
done

# `DBusActivatable=true` in the desktop entry is a promise the session bus has to be
# able to keep. Without this file, `gapplication action …` — which is what the keyboard
# shortcut runs — fails whenever Vervellum is not already running, so the shortcut works
# only the second time you press it.
cat > "$STAGE/usr/share/dbus-1/services/$APP_ID.service" <<SERVICE
[D-BUS Service]
Name=$APP_ID
Exec=/usr/bin/vervellum --gapplication-service
SERVICE
chmod 0644 "$STAGE/usr/share/dbus-1/services/$APP_ID.service"

install -m 0644 "$ROOT/packaging/debian/copyright" "$STAGE/usr/share/doc/vervellum/copyright"

# A version with no Debian revision makes this a *native* package, and lintian then
# requires changelog.gz — not changelog.Debian.gz. (The tilde above is what keeps a
# pre-release native too: a hyphen would have made it a revision.)
printf 'vervellum (%s) unstable; urgency=low\n\n  * Release %s.\n\n -- L-K-M <noreply@lkmc.ch>  %s\n' \
    "$DEB_VERSION" "$VERSION" "$(date -R)" \
    | gzip -9n > "$STAGE/usr/share/doc/vervellum/changelog.gz"
chmod 0644 "$STAGE/usr/share/doc/vervellum/changelog.gz"

echo "==> Resolving dependencies"
# Never hand-write Depends. Ubuntu 24.04's 64-bit time_t transition renamed
# libglib2.0-0 to libglib2.0-0t64 and libcurl4 to libcurl4t64, so a Depends line copied
# from a 22.04 example produces an uninstallable package with no build-time error.
# dpkg-shlibdeps reads the actual ELF and gets it right per release.
DEPENDS=""
if command -v dpkg-shlibdeps >/dev/null; then
    workdir="$(mktemp -d)"
    mkdir -p "$workdir/debian"
    # A real stanza, not an empty file. dpkg-shlibdeps parses debian/control to find the
    # binary package it is resolving for, and gives up on one it cannot read.
    cat > "$workdir/debian/control" <<'SHLIBS'
Source: vervellum
Section: utils
Priority: optional
Maintainer: L-K-M <noreply@lkmc.ch>

Package: vervellum
Architecture: any
Description: Hotkey-summoned research panel
SHLIBS
    ( cd "$workdir" && dpkg-shlibdeps -O --ignore-missing-info "$STAGE/usr/bin/vervellum" \
        2>/dev/null || true ) > "$workdir/deps" || true
    DEPENDS="$(sed -n 's/^shlibs:Depends=//p' "$workdir/deps" | head -1)"
    rm -rf "$workdir"
fi
if [ -z "$DEPENDS" ]; then
    echo "    dpkg-shlibdeps produced nothing; falling back to a minimal GTK dependency" >&2
    DEPENDS="libgtk-4-1, libglib2.0-bin"
else
    # libglib2.0-bin supplies `gapplication`, which the keyboard shortcut runs. It is
    # not linked, so shlibdeps cannot know about it.
    DEPENDS="$DEPENDS, libglib2.0-bin"
fi

INSTALLED_SIZE="$(du -ks "$STAGE" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: vervellum
Version: $DEB_VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: $DEPENDS
Recommends: libsecret-tools
Installed-Size: $INSTALLED_SIZE
Maintainer: L-K-M <noreply@lkmc.ch>
Homepage: https://github.com/L-K-M/Vervellum
Description: Hotkey-summoned research panel
 Vervellum plans web searches, runs them, and writes an answer that can cite only
 the sources it actually retrieved — it refers to them by number, so it has no way
 to express a link it did not find. It then grades its own claims against that
 evidence and shows every verdict, including the ones the evidence could not settle.
 .
 The panel is summoned by a desktop keyboard shortcut. Vervellum can also answer on
 the command line with "vervellum --ask", which needs no display.
 .
 Install libsecret-tools to keep API keys in your login keyring; without it they are
 read from VERVELLUM_MODEL_KEY and VERVELLUM_SEARCH_KEY, or from a mode-0600 file.
CONTROL

echo "==> Packaging"
mkdir -p "$ROOT/build"
OUTPUT="$ROOT/build/vervellum_${DEB_VERSION}_${ARCH}.deb"
# --root-owner-group, or every file is owned by the building user's uid — a lintian
# error and a real permissions bug when building in a container.
dpkg-deb --root-owner-group --build "$STAGE" "$OUTPUT"

echo "==> Built $OUTPUT"
dpkg-deb --info "$OUTPUT" | sed 's/^/    /'
