# MacPTTT — Mac Push Talk to Text

**English** · [ภาษาไทย](README.th.md)

Push-to-talk dictation for the macOS menu bar, in Thai and English. Hold a key and speak: the text is typed at the cursor as you talk, in whatever app you are using. It uses Apple's built-in Speech framework (`SFSpeechRecognizer`) and makes no start/stop sounds.

## Features
- **Push-to-talk** with a key you choose (Right Option by default)
- **Types while you speak**, word by word, then corrects the tail to the final result when you release the key
- **Live waveform** of the microphone input at the bottom-center of the screen while you speak
- **Automatic language selection** between Thai and English, or a fixed language
- **On-device recognition** when the Mac supports it, so no audio leaves the Mac
- Restores your clipboard after pasting

## Install
1. Download **MacPTTT-x.y.dmg** from [Releases](https://github.com/matee-w/MacPTTT/releases/latest), open it and drag **MacPTTT** to Applications.
2. The app is not notarized by Apple, so macOS blocks the first launch. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacPTTT.app
   ```
3. Grant permissions (see below).

Requires macOS 13 or later. Universal app (Apple Silicon and Intel).

## Permissions
1. **Microphone** and **Speech Recognition**: click Allow when asked.
2. **Accessibility**: System Settings → Privacy & Security → Accessibility → turn on MacPTTT. This lets the app listen for the push-to-talk key in other apps and type or paste the text.
3. **Quit and reopen MacPTTT** after granting Accessibility. The global key monitor only starts at launch.

The second line of the menu shows the current state, e.g. `On-device · Mic ✓ · Speech ✓ · Accessibility ✓`.

## Usage
Hold the push-to-talk key → speak (words appear at the cursor about half a second after you say them) → release.

Menu bar icon: 🎙 ready · 🎙 (filled) listening · ⋯ processing · 🎙 (slashed) could not start

## Menu
- **Push-to-Talk Key**: Right Option, Left Option, Right Command, Right Control, Right Shift or Fn (Globe).
  If you use Fn, set System Settings → Keyboard → "Press 🌐 key to" to "Do Nothing".
- **Language**
  - **Automatic (Thai / English)**: transcribes live in the language detected last time. If its confidence is below 0.6, the recorded audio is transcribed again in the other language and the result with higher confidence wins. On-device Speech cannot run two languages at the same time, so this is done one after the other; switching languages adds a short delay.
  - **Thai** / **English (US)**: always use one language.
- **Type While Speaking** (on by default): types words that the recognizer has stopped revising, plus the last word after a short pause. When you release the key it compares with the final result and fixes only the part that differs. Turn it off to paste everything at once on release (via the clipboard).

## On-device vs Apple servers
The status line shows whether recognition runs on the Mac ("On-device") or on Apple's servers ("Apple servers"). If it shows Apple servers, add the language in System Settings → Keyboard → Dictation so macOS downloads the on-device model.

## Build from source
Needs Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./build.sh             # build MacPTTT.app for this Mac
./build.sh --install   # build, install to /Applications and launch
./build.sh --dist      # universal build + dist/MacPTTT-<version>.dmg
```

> The app is ad-hoc signed, so macOS treats every rebuild as a new app. Remove MacPTTT from the Accessibility list and add it again after each rebuild.

## Configuration (`Sources/main.swift` → `Config`)
- `autoAcceptConfidence`: confidence at which Automatic mode accepts the first language without trying the other
- `addsPunctuation`: automatic punctuation
- `finalResultTimeout`: how long to wait for the final result after releasing the key

## License
[MIT](LICENSE)
