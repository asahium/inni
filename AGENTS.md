# AGENTS.md

Inni is a native, Anki-compatible spaced-repetition app for macOS and iPhone. It works directly on Anki's files (`collection.anki2`, `.apkg`, `.colpkg`, `collection.media.db2`), schedules like Anki's v3 scheduler and syncs with AnkiWeb. Swift 6 toolchain (language mode 5), SwiftUI, no third-party dependencies. Keep it that way: zstd, zip, protobuf and SQLite access are implemented in `InniCore`.

## Layout

- `Sources/InniCore` – everything that touches data, no UI. Builds for macOS and iOS.
  - `Collection/` – opening, creating and writing collections (schema 18), models, schema-11 upgrade.
  - `Scheduler/` – v3 scheduler, SM-2 and FSRS-6 (`States.swift` computes next states, `Scheduler.swift` applies answers, undo, limits).
  - `Template/` – Anki's template language, cloze, card HTML.
  - `Search/` – Anki search syntax to SQL.
  - `Package/` – `.apkg`/`.colpkg`, zip reader/writer, zstd.
  - `Sync/` – sync protocol 11: `SyncClient.swift` (HTTP, auth, errors), `CollectionSync.swift` (normal and full sync), `Schema11.swift` (sync JSON), `MediaSync.swift`.
  - `Storage/` – SQLite wrapper (registers Anki's `unicase` collation), protobuf.
- `Sources/InniUI` – SwiftUI shared by both apps. `AppModel` is the single `@MainActor @Observable` state object.
- `Sources/Inni` – macOS app entry (`Window("Inni")`, `Window("Browse")`, Settings).
- `iOS/` – iPhone app entry plus `project.yml` for XcodeGen; it links `InniCore` and `InniUI` from the package.
- `Tests/InniCoreTests` – unit, compatibility and sync tests.
- `scripts/` – bundling, DMG, screenshots, Anki reference scripts (Python with the `anki` package).
- `docs/` – GitHub Pages site (`index.html`, `img/`).

## Commands

```sh
make app          # build/Inni.app (release, ad-hoc signed)
make debug        # debug bundle, opened
make test         # swift test
make verify       # Inni writes a collection and packages, Anki's backend opens, checks and imports them
make sync-test    # starts anki.syncserver locally and syncs Inni against Anki's backend as the second device
make ios-sim      # build, install and launch in the simulator (IOS_SIM="iPhone 17 Pro")
make ios-device   # signed build for a connected iPhone (free Apple ID works; fails to launch if the phone is locked)
./scripts/dmg.sh  # build/Inni-<version>.dmg
```

`make verify` and `make sync-test` need a Python with `pip install anki`, passed as `ANKI_PY=...` (default `/tmp/inni-ref/venv/bin/python`). `SYNC_LARGE=<collection.anki2>` adds a large-collection sync run.

Before committing anything in `Sources/InniCore`, run `swift test`; for sync changes also `make sync-test`; for anything that writes files also `make verify`.

## Compatibility testing

Correctness means "does what Anki does", checked against the real Anki backend:

- `scripts/oracle.py <collection> <outdir>` and `scripts/oracle_synthetic.py <outdir>` write reference data (due counts, rendered cards, FSRS states, next intervals). Tests read it from `INNI_ORACLE` (default `/tmp/inni-ref/oracle`) and skip when it is absent. Oracles from a real collection go stale after the day rollover (04:00 by default); regenerate them instead of loosening tests.
- Fuzz differs on purpose: Inni draws fuzz from its own generator, so tests check that Anki's interval is reachable by Inni's formula for some fuzz factor, not that the picks are equal.
- `SyncHTTPTests` (in `SyncTests.swift`) run without a server; `SyncTests` need `INNI_SYNC_SERVER` and are run by `make sync-test`.
- CI (`.github/workflows/ci.yml`) installs `anki`, generates synthetic oracles, and runs tests, `make verify`, `make sync-test`, the macOS bundle and an unsigned iOS simulator build.

## Sync notes

- AnkiWeb checks the client version. The `anki-sync` header's `c` and the meta body's `cv` must look like a released Anki build (`26.09.4,<hash>,<platform>` and `anki,26.09.4 (<hash>),<platform>`); anything else gets `400` on `sync/meta`. A local `anki.syncserver` doesn't check this, so tests can't catch it.
- AnkiWeb answers `403` for a bad host key before it reads the body, so a `400` means the key was accepted and something in the request was rejected.
- Redirects are not followed: a `308` from `sync/meta` sets the new endpoint, which is stored with the account (`SyncAuth.endpoint`).
- All requests share one static `URLSession`; the no-redirect delegate is per task. Don't give `SyncHTTP` its own session or make it the delegate: a client released without sending a request crashed the app on launch.
- `HTTP` errors name the failing step (`Sync server error 400: sync/meta: …`).
- Media sync is idempotent and retries network errors; network failures of syncs the user didn't start are silent, and media sync resumes when the app becomes active. To see what real Anki sends, point the `anki` Python package at a local server that logs requests.

## Data safety

- Never modify a real Anki profile (`~/Library/Application Support/Anki2/...`) while experimenting or testing. Copy the collection together with its `-wal` file and work on the copy.
- Don't sync personal data against AnkiWeb from tests; use `make sync-test` (local server).
- Running the macOS app with `-collectionPath` writes `collectionPath` into the `dev.inni.app` defaults; remove it afterwards (`scripts/mac-shot.sh` does) so the installed app keeps its own collection.
- Public screenshots use a demo collection, never a personal one.

## UI conventions

- Dark only, Nord palette from `Theme.swift` (`Nord.*`), Kveikur's look: monospaced lists on macOS, pill selection, `CountsView` for New/Learn/Due colours.
- Use `NordForm { … }` instead of `Form` and `.nordList()` on lists so rows don't fall back to system grey; sheets and windows get `.nordWindow()`.
- macOS: `NavigationSplitView` with `DeckSidebar` (vim keys) and a detail pane showing `DeckOverview`, the reviewer, or a page (`AppModel.page`), plus a status bar. iOS: `NavigationStack`. Platform splits use `#if os(macOS)` inside shared views.
- Card web views always render in night mode.
- Keyboard: every reviewer and main-window action has a key; keep `README.md` and `docs/index.html` in sync when adding one.

## Debugging and screenshots

- `-InniOpen <target>` opens a screen on launch (`study:<deck>`, `deck:<deck>`, `browse`, `stats`, `notetypes`, `settings`, `add:<deck>`, `options:<deck>`) and disables sync on open.
- DEBUG macOS builds: `-InniSnapshot out.png [-InniSnapshotWindow Browse] [-InniSnapshotDelay 3]` draws a window into a PNG and quits; `scripts/mac-shot.sh` wraps it. Works without screen-capture access, but card web views come out blank. `-InniSyncLogin user:pass@http://host:port/` logs in to a test server.
- iOS: `scripts/sim-shot.sh`; crash logs from a device: `xcrun devicectl device copy from --device <id> --domain-type systemCrashLogs --source / --destination <dir>`.
- The system `sqlite3` lacks the `unicase` collation; inspect collections with the `anki` package or Inni itself.

## Release

- Tag `vX.Y.Z` and push: `release.yml` tests, builds the DMG, publishes the GitHub release, and bumps `Casks/inni.rb` in `asahium/homebrew-tap` when the `HOMEBREW_TAP_TOKEN` secret exists (otherwise update `version` and `sha256` there by hand).
- The app is ad-hoc signed, not notarized; the cask clears the quarantine flag. Installing needs `brew trust`.
- Bump `Resources/Info.plist` and `MARKETING_VERSION` in `iOS/project.yml` together.

## Style

- Match the surrounding code. Comments only for constraints the code can't show; doc comments are one or two plain sentences.
- Commit messages: short imperative subject, no prefixes.
- README and site text: plain, specific, no marketing language; keep feature claims true and checked.
