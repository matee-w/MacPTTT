# MacPTTT (Mac Push Talk to Text)

macOS menu-bar app: push-to-talk Thai/English dictation (hold a configurable key, default Left Option; text is typed while speaking) using the built-in Speech framework (SFSpeechRecognizer, th-TH). No start/stop sounds. Single file: Sources/main.swift. Build: ./build.sh (swiftc + ad-hoc codesign), ./build.sh --install copies to /Applications.

Status: builds cleanly; Thai + English (auto-detect), on-device only (offline), configurable hotkey (cancels if used as a shortcut), waveform overlay, types while speaking (LiveTyper), Thai voice commands (VoiceCommands), launch at login (SMAppService), app icon from Tools/make-icon.swift. ./build.sh --dist makes a universal DMG in dist/

Testing without a mic: generate Thai speech with `say -v Kanya "..." -o /tmp/t.aiff` (check `say -v '?' | grep th_TH` for the voice name), and test transcription with a small separate Swift script using SFSpeechURLRecognitionRequest + th-TH. Report whether supportsOnDeviceRecognition is true for th-TH on this Mac.

The user must grant Microphone, Speech Recognition and Accessibility permissions themselves; ask them when needed. Ad-hoc signing means Accessibility must be re-granted after each rebuild.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for matee-w/macpttt (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` + `docs/adr/` at the repo root (created lazily). See `docs/agents/domain.md`.
