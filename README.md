# Journal

A private, single-user journal for iPhone. Everything is processed and stored on the phone, in an encrypted database unlocked with Face ID. The build brief is [SPEC.md](SPEC.md).

**Status:** phases 1–4 are built:
- **Vault:** app lock, encrypted database, typed entries, entry list, export.
- **Voice:** recording with pause/resume and a waveform, and on-device transcription.
- **Cleanup:** on-device AI cleanup with a review diff, using Qwen3.5-4B through llama.cpp.
- **Mood and categories:** background mood, summary, themes and categories; the mood calendar; the category filter; manual overrides.

## Install on the iPhone

The app is never published. It is installed straight from the Mac.

### From Xcode
1. Connect the iPhone by cable (or the same Wi-Fi once paired) and unlock it.
2. Open `Journal.xcodeproj` in Xcode.
3. Choose the **Journal** scheme and your iPhone as the run destination.
4. Press **Run** (⌘R).

Signing uses the paid developer team set in the project (`DEVELOPMENT_TEAM`), so an install lasts a year. With a free Apple ID instead, set your personal team under Signing & Capabilities. That install expires after 7 days and has to be re-run from Xcode.

The first time, the iPhone may ask you to turn on **Developer Mode** (Settings → Privacy & Security → Developer Mode, then restart).

### From the terminal
```sh
xcodebuild -project Journal.xcodeproj -scheme Journal -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl list devices            # find the phone's identifier
xcrun devicectl device install app --device <identifier> build/Build/Products/Release-iphoneos/Journal.app
```

Reinstalling over an existing install keeps the journal. **Deleting the app deletes the journal**, because its data is kept out of iCloud backups. Export first.

### The AI model
Cleanup needs the 2.7 GB model file. Either let the app download it (Settings → AI model, over Wi-Fi), or copy it from the Mac. The app checks its checksum the first time it finds it:
```sh
xcrun devicectl device copy to --device <identifier> --source Qwen3.5-4B-Q4_K_M.gguf \
  --destination "Library/Application Support/Models/Qwen3.5-4B-Q4_K_M.gguf" \
  --domain-type appDataContainer --domain-identifier com.diarmuidbrady.journal
```
The download URL and checksum are in `Journal/AI/ModelSpec.swift`.

## Development

- Requires Xcode 26.3 or later; deployment target iOS 26.0.
- Tests: `xcodebuild test -project Journal.xcodeproj -scheme Journal -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- Tests use invented sample entries only (`JournalTests/SampleEntries.swift`). Never add real journal text, exports or recordings to the repo.
- Debug builds launched with `-seed-sample-entries` fill an empty journal with invented entries, for trying the UI in the simulator.
- Debug builds launched with `-ai-benchmark` load the model, clean one invented entry, print timings and free memory, then exit. They never open the journal. Run it on the phone with: `xcrun devicectl device process launch --device <identifier> --console com.diarmuidbrady.journal -ai-benchmark`
- **The AI model doesn't run in the Simulator:** llama.cpp ships no Simulator build. The app links it for device builds only, and in the Simulator, cleanup reports "not available".
- **Model checks on a Mac:** these run the app's real AI code with llama.cpp over `JournalTests/Fixtures/cleanup-samples.json`.
  - `Tools/cleanup-quality.sh path/to/Qwen3.5-4B-Q4_K_M.gguf` checks that cleanup keeps names, numbers and negations.
  - `Tools/analysis-check.sh path/to/Qwen3.5-4B-Q4_K_M.gguf` prints the mood, categories and summary for each sample.
- `-open-tab mood` (debug builds only) starts on the Mood tab.
- Dependencies:
  - GRDB with SQLCipher, copied into `Packages/GRDB` (see [VENDORED.md](Packages/GRDB/VENDORED.md)).
  - llama.cpp's prebuilt XCFramework, pinned in `Packages/LlamaCpp`.
  - There are no others.

## Layout

```
Journal/
  App/        App entry point, Vault (lock state)
  Security/   Keychain key store, privacy cover
  Storage/    Encrypted database, Entry/Category models, EntryStore
  Export/     Zip export (JSON + audio)
  Voice/      Recorder, player, on-device transcription, waveform
  AI/         TextModel, llama.cpp runner, model download, cleanup, diff
  Features/Mood/  Mood calendar, colour scale, month summary
Tools/        Model checks that run on a Mac (cleanup quality, analysis)
  Features/   Lock, EntryList, EntryEditor, Settings screens
JournalTests/ Unit tests (Swift Testing)
Packages/     GRDB (with SQLCipher), llama.cpp
```
