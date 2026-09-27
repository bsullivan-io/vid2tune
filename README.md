# Vid2Tune

A small macOS app that turns video links and video files into audio.

- Paste a link from YouTube, Vimeo, SoundCloud, TikTok and [many other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md), or drag in a video file
- Save as **MP3** (128–320 kbps or best VBR), **WAV** or **AIFF**
- Adds title, artist and album art automatically
- Keeps a history of your conversions

Vid2Tune is a native SwiftUI front end for [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org), which come bundled with it. There's nothing else to install.

## Install

Requires macOS 14 (Sonoma) or later on an Apple silicon Mac.

1. Download `Vid2Tune-<version>-arm64.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Vid2Tune** into your **Applications** folder.
3. Open Vid2Tune. The first time, macOS will say it **“Not Opened”**, because the app isn't notarized by Apple. Click **Done**, then:
   - open **System Settings → Privacy & Security**,
   - scroll down to *“Vid2Tune” was blocked…* and click **Open Anyway**, then confirm.

   You only need to do this once. Alternatively, run this in Terminal before opening it:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Vid2Tune.app
   ```

## Using it

- **Links:** paste one or more links into the box and press **Convert**, click the clipboard button, or drag links onto the window.
- **Files:** drag video or audio files onto the window or onto Vid2Tune's Dock icon, or use *Open With → Vid2Tune* in Finder.
- Files are saved to `~/Music/Vid2Tune` by default. Click **Change…** to pick another folder.
- Sites change often. If downloads start failing with “403 Forbidden”, click **Update yt-dlp** when Vid2Tune offers it.

Only download content you have the right to. Many sites' terms of service prohibit downloading, and DRM-protected services such as Spotify or Netflix aren't supported.

## Building from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh            # quick development build; uses yt-dlp and ffmpeg from Homebrew
./build.sh --release  # bundles yt-dlp, FFmpeg and QuickJS, and zips the app into dist/
```

The development build expects `brew install yt-dlp ffmpeg`. Release builds download pinned, checksum-verified versions of the bundled tools (see the top of `build.sh`).

Pushing a tag such as `v1.0.0` runs the [release workflow](.github/workflows/release.yml), which builds the app and publishes it as a GitHub release.

### How the bundled tools run

The tools live in `Vid2Tune.app/Contents/Resources/bin`. On launch, Vid2Tune copies them to `~/Library/Application Support/Vid2Tune/bin` and runs them from there. That's because macOS blocks quarantined command-line tools inside an unsigned, downloaded app, and because yt-dlp needs to be able to update itself. If you have Homebrew's yt-dlp or ffmpeg, the bundled copies are still preferred. YouTube requires a JavaScript runtime: Vid2Tune bundles [QuickJS](https://github.com/quickjs-ng/quickjs), and yt-dlp uses [Deno](https://deno.com) instead if it's installed.

## License

Vid2Tune is MIT-licensed; see [LICENSE](LICENSE). The bundled tools keep their own licenses. FFmpeg's is GPL v3; see [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and [licenses/](licenses/).
