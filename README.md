# Media Tool

`MediaTool.app` — a drag-and-drop macOS GUI for video compression / GIF generation, built on top of `ffmpeg`. Source lives in `MediaTool/`, built via `MediaTool/build_app.sh`.

Output is written to **`~/Desktop/MediaTool Output/`** and the original file is never overwritten.

## Requirements

- macOS.
- **ffmpeg** installed and on one of these paths (the app hardcodes this lookup, no `$PATH` search):
  - `/opt/homebrew/bin/ffmpeg` (Homebrew on Apple Silicon)
  - `/usr/local/bin/ffmpeg` (Homebrew on Intel)
  - `/usr/bin/ffmpeg`

  Install with:
  ```bash
  brew install ffmpeg
  ```
  If ffmpeg is installed anywhere else, the app won't find it.
- To **rebuild** `MediaTool.app` from source: Xcode Command Line Tools (`swift build` must be available) — not needed just to run the already-built app.

## Setup

Already built at `~/Desktop/MediaTool.app`. First launch will be blocked by Gatekeeper because the app is **ad-hoc signed** (no Apple Developer certificate): **right-click → Open** the first time, then confirm in the dialog. Subsequent launches work normally (double-click).

To rebuild after changing the Swift source (`MediaTool/Sources/MediaTool/MediaToolApp.swift`):

```bash
cd ~/Desktop/MediaTool
./build_app.sh
```

This compiles in release mode, repackages `~/Desktop/MediaTool.app` from scratch, and re-signs it ad-hoc.

## `MediaTool/` folder (source project)

This is a Swift Package Manager project — it is the *only* source of truth for `MediaTool.app`. The `.app` bundle is a generated artifact; don't edit it directly, edit the source here and rebuild.

```
MediaTool/
├── Package.swift                  # SwiftPM manifest: executable target "MediaTool", macOS 13+
├── build_app.sh                   # Builds + packages + ad-hoc signs -> ~/Desktop/MediaTool.app
├── Sources/MediaTool/
│   ├── App/MediaToolApp.swift     # App entry, AppDelegate, sidebar (RootView)
│   ├── Media/MediaView.swift      # Media Tool UI + ffmpeg pipeline logic
│   └── Chat/                      # LAN chat: Bonjour discovery, TCP framing, history, views
├── .build/                        # swift build output (release binary lives here pre-packaging)
└── .swiftpm/                      # Xcode/SwiftPM tooling metadata
```

- **`Package.swift`**: defines the package as a single executable target with no external dependencies (only `SwiftUI`, `AppKit`, `UniformTypeIdentifiers` from the system). Requires macOS 13 minimum.
- **`Sources/MediaTool/MediaToolApp.swift`**: single-file app containing:
  - `AppDelegate` — handles files handed to the app via `application(_:open:)` (drag onto Dock icon, `open -a`, Folder Action automation) and force-closes any extra window macOS creates for the same open event, as a safety net.
  - `ContentView` — the entire UI (drop zone, process/quality pickers, log pane).
  - `findFFmpeg()` — the hardcoded ffmpeg path lookup described above.
  - `runPipeline()` — shells out to ffmpeg with `Process` (GIF palette pass, then compression pass, then optional delete).
- **`build_app.sh`** is the *only* supported way to produce/update `~/Desktop/MediaTool.app`. It always does a full rebuild-and-replace (`rm -rf` on the old `.app`), so any manual edits made directly to `MediaTool.app/Contents/*` will be lost on the next build.
- **`.build/`** and **`.swiftpm/`** are SwiftPM/Xcode-generated caches — safe to delete (`rm -rf .build .swiftpm`) if a build gets into a bad state; `swift build` regenerates them.
- To iterate on the UI without packaging as an `.app` each time, `swift run` from inside `MediaTool/` launches it directly (though `open -a` and the Folder Action automation only work against the packaged `.app`, since those require a real bundle registered with Launch Services).

## Usage

1. Open `MediaTool.app`.
2. Drag one or more video/GIF files onto the drop zone (or click it to open a file picker). The app can also be opened directly with a file already loaded — via `open -a MediaTool.app file.mov`, or automatically via the [screen-recording automation](#automate-auto-open-after-a-screen-recording) below.
3. Pick Process (Compress / GIF / Both) and Quality (High / Medium / Low / Custom — custom CRF, GIF width, GIF fps), plus an optional output prefix.
4. Toggle "delete originals after compressing" if desired.
5. Click **Run**. Progress and results stream into the log pane at the bottom.

> **Note:** Finder's right-click **"Open With → Media Tool"** does *not* list the app. Early on it did (via `CFBundleDocumentTypes` in `Info.plist`), but that declaration made macOS spawn an extra document window on every file-open in addition to the one our own handler populates — a duplicate-window bug. Removing it fixed the duplicate window at the cost of that Finder menu entry. Drag-and-drop, the file picker, `open -a`, and the Folder Action automation are unaffected and are the supported ways to hand it a file.

## Quality presets

| Quality | CRF | GIF width | GIF fps |
|---------|-----|-----------|---------|
| High    | 18  | 720 px    | 20      |
| Medium  | 23  | 480 px    | 15      |
| Low     | 28  | 320 px    | 10      |
| Custom  | custom | custom | custom |

Lower CRF = better quality / larger file.

## Automate: auto-open after a screen recording

macOS's built-in screen recorder (**Cmd+Shift+5**) saves each recording as `Screen Recording <date> at <time>.mov`, by default straight to `~/Desktop`. This automation watches that folder and, the instant a new recording lands, opens it directly in `MediaTool.app` — pre-loaded in the drop zone, ready for you to pick Process/Quality/prefix and click **Run**. It does **not** auto-run the compression — you still choose settings per recording.

It's built on **Folder Actions**, a native macOS mechanism where a folder has a script attached to it that fires whenever a new item is added — no polling, no login item, no background daemon of our own.

### How it works

1. `~/Library/Scripts/Folder Action Scripts/MediaTool Recording Watcher.scpt` — a compiled AppleScript attached to `~/Desktop`. On every new item added to Desktop, it checks whether the name starts with `Screen Recording` and ends with `.mov`; if so, it waits 1 second (so `screencapture` has finished writing the file) and runs `open -a MediaTool.app <the file>`.
2. Everything else (unrelated files dropped on Desktop, screenshots, etc.) is ignored.

Source of the script:
```applescript
on adding folder items to thisFolder after receiving addedItems
	repeat with anItem in addedItems
		set itemPath to POSIX path of anItem
		try
			set itemName to do shell script "basename " & quoted form of itemPath
		on error
			set itemName to ""
		end try

		if itemName starts with "Screen Recording" and itemName ends with ".mov" then
			-- Small delay so screencapture finishes writing the file first.
			delay 1
			try
				do shell script "open -a '/Users/leonarpv/Desktop/MediaTool.app' " & quoted form of itemPath
			end try
		end if
	end repeat
end adding folder items to
```

### Step-by-step setup

**1. Confirm recordings still save to the default location** (skip this if you've never changed it in the Cmd+Shift+5 options bar):
```bash
defaults read com.apple.screencapture location
```
No output (`does not exist`) means the default `~/Desktop` is in effect. If it prints a path, replace `~/Desktop` with that path everywhere below.

**2. Compile the watcher script** (only needed once, or when setting this up on a new Mac — skip if `MediaTool Recording Watcher.scpt` already exists at the path below):
```bash
mkdir -p ~/Library/Scripts/"Folder Action Scripts"
osacompile -o ~/Library/Scripts/"Folder Action Scripts"/"MediaTool Recording Watcher.scpt" /path/to/the/applescript/above.applescript
```
(Save the AppleScript source block above to a `.applescript` file first, adjusting the `open -a` path if `MediaTool.app` doesn't live at `~/Desktop/MediaTool.app`.)

**3. Attach the script to Desktop — must be done via the GUI, not a shell command.** Attaching Folder Actions to protected folders (Desktop/Documents/Downloads) via `osascript`/System Events fails silently (TCC blocks it for non-GUI processes; verified — attaching the identical command to an unprotected folder like `/tmp` works instantly, but to `~/Desktop` it returns `missing value` and never registers). Apple's own Folder Actions Setup app already has the needed permission, so use that instead:

   1. Open **Folder Actions Setup**:
      ```bash
      open "/System/Library/CoreServices/Applications/Folder Actions Setup.app"
      ```
   2. Check **"Enable Folder Actions"** (top-left checkbox).
   3. Click **+** under the folder list (left column) → choose **Desktop**.
   4. A script picker appears for that folder → select **"MediaTool Recording Watcher.scpt"**.
   5. Close the window. The action stays attached — nothing needs to keep running.

**4. Test it.** Record a few seconds with Cmd+Shift+5 → Record Screen, stop the recording, and within ~1–2 seconds `MediaTool.app` should open with the new recording already in the drop zone.

### Troubleshooting

- **Nothing happens after recording:** re-open Folder Actions Setup and confirm both "Enable Folder Actions" is checked *and* Desktop shows the watcher script listed under it — a `defaults read com.apple.foldermanager` -style check isn't reliable here since the GUI is the source of truth for per-folder attachment.
- **It worked once, then stopped:** the dispatcher process (`FolderActionsDispatcher`) can be checked with `ps aux | grep FolderActionsDispatcher`; if it's not running, reattaching the action via Folder Actions Setup restarts it.
- **Wrong app opens, or "MediaTool.app not found":** the script hardcodes the path `/Users/leonarpv/Desktop/MediaTool.app` in its `open -a` call — if you move the app, recompile the script (step 2) with the corrected path.
- **To disable:** reopen Folder Actions Setup, select Desktop, and remove the script (or uncheck "Enable Folder Actions" to pause all folder actions globally without detaching anything).

## Sharing with someone on a different Mac

The app depends on things that exist on *this* machine but won't exist on a fresh one. What to send and what the recipient needs to do depends on whether they only need to **run** the app or also **rebuild** it.

### What to send

- To just run it: `MediaTool.app`. The `MediaTool/` source folder is only needed if they might rebuild.
- Zip the app rather than sending the raw `.app` bundle over some transports (e.g. plain email attachments can mangle bundle structure); AirDrop, a zip, or a shared drive/cloud link all work fine otherwise.

### Recipient prerequisites

1. **macOS 13 (Ventura) or newer**.
2. **Homebrew**, if not already installed:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
3. **ffmpeg**:
   ```bash
   brew install ffmpeg
   ```
   The app only looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` — a Homebrew install lands in the right place automatically; nothing else to configure.

### ⚠️ CPU architecture: the prebuilt `.app` is Apple Silicon–only

This machine's build produced an **arm64-only** binary (confirmed via `file MediaTool.app/Contents/MacOS/MediaTool`). It will **not launch on an Intel Mac**. If the recipient has an Intel Mac (or you're unsure), either:

- Have them build it themselves from the `MediaTool/` source folder (requires Xcode Command Line Tools: `xcode-select --install`, then `cd MediaTool && ./build_app.sh`), or
- Rebuild a **universal binary** yourself before sending:
  ```bash
  cd ~/Desktop/MediaTool
  swift build -c release --arch arm64 --arch x86_64
  ./build_app.sh
  ```
  (`build_app.sh` will pick up the universal binary from `.build/apple/Products/Release/` — verify with `file` afterwards that both `arm64` and `x86_64` are listed.)

### ⚠️ Gatekeeper on a transferred (not locally built) app

`MediaTool.app` is **ad-hoc signed**, not notarized. On this machine that just means a right-click → Open the first time. But once the file crosses the internet or an app store/quarantine-aware transport (AirDrop, Messages, browser download, some cloud-sync clients), macOS tags it with a **quarantine attribute**, and Gatekeeper can be stricter — sometimes showing *"MediaTool.app is damaged and can't be opened"* instead of the normal unidentified-developer prompt, with no right-click bypass offered.

If the recipient hits that, they need to strip the quarantine flag once from Terminal:
```bash
xattr -cr /path/to/MediaTool.app
```
Then right-click → Open should work normally. (Alternatively: System Settings → Privacy & Security → "Open Anyway", if that button appears instead of "damaged".)

## Considerations

- **Compression re-encodes video only** (`libx264`) — audio is stream-copied (`-c:a copy`), so the output keeps the original audio codec/container compatibility as-is; it is not re-encoded or dropped.
- **GIF generation is a two-pass palette workflow** (`palettegen` + `paletteuse`) for better color quality than a naive single-pass GIF; the intermediate palette PNG is deleted automatically.
- **Outputs are silently overwritten** (`ffmpeg -y`) if you reuse the same input/prefix combination — no confirmation prompt.
- **Deleting the original** only happens after compression succeeds, and only if you explicitly toggle it on. It is never deleted if only a GIF was generated.
- Output filenames: `<prefix_>name.gif`, `<prefix_>name_compressed.<original-ext>`.
- Multiple dropped files are processed sequentially in one run, using the same settings for all of them.
