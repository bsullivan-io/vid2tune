#!/bin/zsh
# Builds Vid2Tune.app into ./build.
#
#   ./build.sh            Development build. Uses yt-dlp/ffmpeg from Homebrew at runtime.
#   ./build.sh --release  Bundles yt-dlp, ffmpeg and QuickJS into the app and zips it
#                         into ./dist for a GitHub release. Set VERSION=1.2.3 to override
#                         the version from Resources/Info.plist.
#
# Requires the Xcode Command Line Tools. Release builds are Apple silicon (arm64) only,
# because the bundled ffmpeg and QuickJS are arm64 builds.
set -euo pipefail
cd "$(dirname "$0")"
# Use the Command Line Tools toolchain if the full Xcode license hasn't been accepted.
if ! swiftc --version >/dev/null 2>&1; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

# Pinned third-party tools (bump these together with their checksums).
YTDLP_VERSION=2026.08.19
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos"
YTDLP_SHA256=0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202
QJS_VERSION=v0.17.0
QJS_URL="https://github.com/quickjs-ng/quickjs/releases/download/$QJS_VERSION/qjs-darwin-arm64"
QJS_SHA256=8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11
FFMPEG_VERSION=9.0.2
FFMPEG_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_$FFMPEG_VERSION/ffmpeg.zip"
FFMPEG_SHA256=c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924

VENDOR=vendor
APP=build/Vid2Tune.app

# fetch <url> <dest> <sha256>: download once into ./vendor and verify.
fetch() {
  local url=$1 dest=$2 sha=$3
  if [[ ! -f "$dest" ]] || ! echo "$sha  $dest" | shasum -a 256 -c --status; then
    echo "Downloading $url"
    curl -sSfL -o "$dest.part" "$url"
    echo "$sha  $dest.part" | shasum -a 256 -c --status || { echo "Checksum mismatch for $url" >&2; rm -f "$dest.part"; exit 1; }
    mv "$dest.part" "$dest"
  fi
}

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH=$(uname -m)
(( RELEASE )) && ARCH=arm64
swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" \
  -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Vid2Tune"

swift Resources/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
# CFBundleVersion changes every build so the app knows to refresh its installed tools.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION.$(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"

if (( RELEASE )); then
  mkdir -p "$VENDOR"
  fetch "$YTDLP_URL" "$VENDOR/yt-dlp" "$YTDLP_SHA256"
  fetch "$QJS_URL" "$VENDOR/qjs" "$QJS_SHA256"
  fetch "$FFMPEG_URL" "$VENDOR/ffmpeg-$FFMPEG_VERSION.zip" "$FFMPEG_SHA256"

  BIN="$APP/Contents/Resources/bin"
  mkdir -p "$BIN"
  cp "$VENDOR/yt-dlp" "$VENDOR/qjs" "$BIN/"
  unzip -oq "$VENDOR/ffmpeg-$FFMPEG_VERSION.zip" ffmpeg -d "$BIN"
  echo "$YTDLP_VERSION" > "$BIN/yt-dlp.version"
  chmod +x "$BIN/yt-dlp" "$BIN/qjs" "$BIN/ffmpeg"
  cp -R THIRD_PARTY_NOTICES.txt LICENSE licenses "$APP/Contents/Resources/"
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if (( RELEASE )); then
  mkdir -p dist
  ZIP="dist/Vid2Tune-$APP_VERSION-arm64.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  (cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
fi
