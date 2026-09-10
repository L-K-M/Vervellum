# AGENTS.md

Guidance for AI coding agents working in the **Vervellum** repository.

## What Vervellum Is

Vervellum is a hotkey-summoned **research** panel. Press a shortcut anywhere and a
panel appears. Type a question. Vervellum plans web searches, runs them against a Model
Context Protocol search server, streams an answer that can cite only the sources it
actually retrieved, and then grades its own claims against that same evidence.

It ships for **two platforms from one core**:

- **macOS** — a menu-bar agent (`LSUIElement`), non-sandboxed, SwiftUI + AppKit, built
  from `Vervellum.xcodeproj`. The panel floats over another app's full-screen window.
- **Linux (Ubuntu 24.04+)** — a GTK4 window plus a `--ask` command line, packaged as a
  `.deb`, built from `Package.swift`.

Everything that decides what a research turn *does* is shared; only the front ends
differ. See "The portability rule" below — it is the constraint most easily broken by a
one-line change.

See [`PLAN.md`](PLAN.md) for the full design and the feasibility analysis;
[`README.md`](README.md) for the user view; [`CICD.md`](CICD.md) for the pipeline;
[`SECURITY.md`](SECURITY.md) and [`PRIVACY.md`](PRIVACY.md) for the boundaries — all
four are kept honest against the code, not aspirational.

## The portability rule

**Nothing under `Sources/VervellumKit/Core/` may import a platform framework.** No
AppKit, no SwiftUI, no Combine, no `os`, no `Security`, no `CGtk`. Foundation and
Dispatch only, plus `FoundationNetworking` behind `#if canImport(...)`.

One exception exists, and it is deliberate: `CommandRunner` imports `Darwin` or
`Glibc` behind `#if canImport` for exactly one symbol, `kill(2)`. That is the C library
rather than a platform framework — it is present on both platforms, so the portability
the rule protects is untouched — and Foundation's `Process` offers only `terminate()`,
a signal a program may ignore. Without the escalation a search command that ignored it
would keep running with a dispatch thread parked on its pipe forever. Do not read this
as licence for a second exception: a platform *framework* in `Core/` is still the thing
the Linux job exists to catch.

That directory is compiled twice: into the macOS app target (through a
file-system-synchronized group in the Xcode project) and into the `VervellumKit`
SwiftPM module on Linux. There is no access-control boundary between it and the
front ends, which is deliberate — a real module would mean annotating several hundred
members `public` for no benefit that CI does not already provide. **The Linux build is
the boundary.** A stray `import AppKit` in Core compiles happily on a Mac and fails the
Linux job immediately, which is why that job runs on every pull request.

Four things in particular do not exist on Linux and must never appear in Core:

| Wanted | Why it is not there | Use instead |
|---|---|---|
| `os.Logger` | the `os` module does not exist | the `LogSink` seam |
| `ObservableObject` / `@Published` | Combine is Apple-only | a plain `onChange` callback; the front end republishes |
| `URLSession.bytes(for:)` | absent from swift-corelibs-foundation | `URLSessionDataDelegate` — already in `HTTPTransport` |
| `RelativeDateTimeFormatter` | not implemented in corelibs | format it yourself, or keep it in the macOS front end |

Two more traps that are not about missing API:

- **`DispatchQueue.main` and `@MainActor` never run under a GLib main loop.** A GTK app
  gives the main thread to GLib, which does not drain libdispatch's main queue, so a
  `MainActor` hop hangs *silently* — no warning, no crash, just a window that never
  updates. Core must therefore never marshal to the main actor itself; it hands work
  back through a plain callback and each front end marshals (`DispatchQueue.main.async`
  on macOS, `GTK.onMainLoop` on Linux). `ThreadArchive` uses its own private queue for
  the same reason.
- **`DateFormatter` is not thread-safe on Linux**, unlike Darwin. Create one per use.

## The one load-bearing design decision

**The model may not write URLs. It may only cite by number.**

Vervellum runs the searches, so Vervellum — not the model — owns the numbered source
list. The answer prompt forbids URLs, bare domains and markdown links outright, and
requires evidence to be referenced as `[1]` or `[2, 5]`. `CitationValidator` then
checks that every number is in range, and flags any literal URL that appeared anyway.

This makes a fabricated link *structurally impossible* rather than merely discouraged:
there is no syntax in which the model could express one. It is also more robust than
allow-listing URLs and string-matching what the model wrote, because a model that
reformats a link (a tracking parameter, a dropped trailing slash, a percent-encoded
character) would fail an exact-match allow-list *even though it cited a real source*.

**Do not relax this** to "the model may write links if we check them". The check is
not the mechanism; the absence of expressible syntax is.

## Tech Stack

- **Language:** Swift (Swift 5 language mode). The Xcode project sets
  `SWIFT_VERSION = 5.0`; `Package.swift` declares `swift-tools-version: 5.9`, which
  selects the same mode. They must stay in step, or a file compiles on one platform and
  fails strict-concurrency checking on the other. The Linux *toolchain* must be 6.0 or
  newer — the async `URLSession` methods landed in corelibs only then.
- **UI:** SwiftUI for the panel and Settings; AppKit for windowing (`NSPanel`,
  `NSStatusItem`, `NSVisualEffectView`, `NSHostingView`) and for the composer
  (`NSTextView` behind an `NSViewRepresentable` — see Critical Constraints).
- **System APIs:** Carbon `RegisterEventHotKey` (global shortcuts — no permission),
  `AXUIElement` / `kAXSelectedTextAttribute` (the one opt-in feature that needs
  Accessibility), `SMAppService` (launch at login), Security framework
  (`SecItem*` for the Keychain).
- **Networking:** one shared `HTTPTransport` built on `URLSessionDataDelegate` — the
  only streaming API that exists on both platforms — which refuses redirects, caps
  response size, and splits Server-Sent Events on the raw bytes.
- **Persistence:** a Codable `ThreadLibrary` as JSON in
  `~/Library/Application Support/Vervellum/threads.json` (atomic, debounced, one
  `.bak`, `0600`); settings in `UserDefaults`; **API keys only in the Keychain**. The
  model providers are a JSON list under one settings key, with the pre-profiles
  `modelEndpoint` / `modelName` kept as a mirror of the selected one — that mirror is
  what the Linux settings file documents and what a downgraded build reads, so keep
  writing it.
- **Min target:** macOS 14 (Liquid Glass gated `@available(macOS 26, *)` with an
  `NSVisualEffectView` fallback). **Build with Xcode 26** for Liquid Glass.
- **App type:** menu-bar agent (`LSUIElement = true`, `.accessory` policy, no Dock
  icon), **non-sandboxed**, Developer ID + notarization (no App Store).

## Build & Run

### Linux

```bash
swift build -c release --product vervellum   # needs libgtk-4-dev and pkg-config
swift test --parallel                        # the shared core's tests
packaging/build-deb.sh 0.1.0                 # produces build/vervellum_0.1.0_<arch>.deb
```

`swift test` runs the *same test files* the macOS suite runs, which is what stops the
two platforms drifting. Build the `.deb` on the oldest Ubuntu release you support: a
package links against the libraries present at build time.

### macOS

The Xcode project uses **file-system-synchronized groups**
(`PBXFileSystemSynchronizedRootGroup`), so new files under `Vervellum/` or
`VervellumTests/` are picked up automatically — no `project.pbxproj` edits. The
`Sources` and `Resources` build phases are deliberately empty; do not "fix" them by
adding `PBXBuildFile` entries. The known exception that *would* need a project change
is a build setting, such as adding a `SWIFT_OBJC_BRIDGING_HEADER`.

```bash
# Build
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum -configuration Debug build

# Run unit tests (pure logic: citations, parsers, placement, budgeting, persistence)
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum -destination 'platform=macOS' test
```

`scripts/build.sh` / `scripts/release.sh` are thin stubs over the shared `lkm-build` /
`lkm-release` engine (the `release-tool` repo). Never inline release logic into them.
Prefer building and running from Xcode during development — the panel, the activation
handoff, and the full-screen behaviour all need a real GUI session.

## Module Layout

```
Sources/VervellumKit/Core/   shared — Foundation only, compiled into BOTH targets
Sources/VervellumKit/Linux/  the GTK front end; every file is entirely #if os(Linux)
Sources/CGtk/                the GTK4 system-library shim (module map + C helpers)
Sources/vervellum/           three lines: the Linux executable's entry point
Vervellum/                   the macOS front end (Xcode target)
Tests/VervellumKitTests/     shared tests, run on both platforms
VervellumTests/              macOS-only tests (hotkeys, panel geometry, Accessibility)
```

`Sources/VervellumKit/Core/`:

- `Research/` — the pipeline. `ResearchRunner` orchestrates the stages and is
  driven by both front ends; `ChatCompletionsClient` talks to the model over
  `HTTPTransporting` — the seam every outbound call passes through, implemented in
  production by `HTTPTransport` and in `Tests/` by `StubTransport`, which is what lets
  a whole turn be run without a network — and search goes through the `SearchBackend`
  seam — `SearchMCPClient` for an MCP server, `SearXNGClient` for a SearXNG instance's
  own JSON API, `KagiCLIClient` for the `kagi` command-line tool, chosen by
  `SearchBackendFactory`. That last one is not a server: it runs a program through the
  `CommandRunning` seam (`CommandRunner` in production, `StubCommandRunner` in `Tests/`),
  which is to a subprocess what `HTTPTransporting` is to a request. `MCPSession` is the shared
  MCP-over-HTTP transport those clients and the page reader all speak; `PageReading`
  and `PageReaderFactory` (`DirectPageReader`, `ReaderMCPClient`) fetch the pages behind
  the top sources, and `HTMLTextExtractor` turns them into text.
  `ResearchPrompts` holds the prompts; `PlanParser` /
  `AssessmentParser`, `CitationValidator`, `SourceHarvester`, `EvidenceExtractor`,
  `ResearchContext` and `ProviderSettings` are pure and carry the validation rules.
  `Attachment` decides what a user may attach to a question and what its bytes turn out
  to be; the bytes themselves live in `Store/AttachmentStore`, beside the thread file
  rather than inside it, because a thread's history is what gets re-sent to the model on
  every later turn.
- `Store/` — `ThreadLibrary` (the versioned document) and `ThreadArchive`.
- `Text/` — `MarkdownParser`, `ComposerCommand`, `Formatting`, `TranscriptFormatter`.
- `Platform/` — the seams: `SecretStore`, `SettingsStore`, `LogSink`,
  `CorePreferences`, `SecretRedactor`.
- `Updates/` — the GitHub self-updater's portable half.

`Sources/VervellumKit/Linux/` — `GTK` (every raw C call), `PangoMarkup` (rendering),
`LinuxPanel`, `LinuxApp`, `LinuxEnvironment`, `LinuxPaths`, `LinuxSecretStore`,
`ShortcutInstaller`.

`Vervellum/` (macOS):

- `App/` — `VervellumApp` (the `@main` entry point, a plain `NSApplication` lifecycle
  rather than a SwiftUI `App` scene) and `AppDelegate`, which owns everything with a
  lifetime: preferences, store, engine, panel, status item, both shortcuts.
- `Panel/` — `ResearchPanel` (the `NSPanel` subclass and its flags), `PanelController`
  (show / hide / place / focus handoff), and the pure `PanelPlacement` geometry.
- `Research/` — `ResearchEngine`, an `ObservableObject` shell over the shared
  `ResearchRunner`. It owns the thread, publishes changes, and hops each of the
  runner's callbacks onto the main queue; every rule lives in Core.
- `Model/` — `Preferences` (the macOS-only settings, forwarding the shared ones to
  `CorePreferences`) and `HotkeyBinding`.
- `Store/` — `ThreadStore`, an `ObservableObject` shell over `ThreadArchive`. It also
  owns the `AttachmentStore` beside it and sweeps it where a thread can stop existing —
  a delete, a prune, an erase, and once at launch.
- `Attachments/` — `AttachmentIntake`, which turns what was pasted or dropped into
  attachments. The one place that decides what wins when a pasteboard carries several
  things, and the only layer allowed to re-encode a TIFF screenshot as PNG: `Core` may
  not import an imaging framework, which is why it refuses an image it cannot identify
  rather than converting one.
- `Security/` — `KeychainStore`, the macOS `SecretStore`.
- `Selection/` — `SelectedTextReader` (the Accessibility path).
- `Hotkeys/` — `CarbonHotkey`, `KeyCodes`.
- `Views/` — the SwiftUI panel: `PanelTheme` (all design tokens), `MarkdownText` (the
  renderer over Core's `MarkdownParser`), `ComposerView`, `ProcessTrailView`,
  `FindingsView`, `SourcesView`, `TurnView`, `HistoryView`, `EmptyStateView`,
  `PanelHeaderView`, `PanelRootView`.
- `Settings/` — the four panes (Providers, Shortcuts, General, About), the window
  controller, and `HotkeyRecorder`.
- `Updates/` — `UpdateChecker`, which needs `NSAlert`; the rest is in Core.

## Conventions

- Follow the Swift API Design Guidelines; one type per file, filename matching the
  primary type; `// MARK:` sections.
- Avoid force-unwraps outside tests.
- **Comments explain *why*.** This codebase is dense with load-bearing rationale —
  which API was rejected and what broke, which flag is a default that is stated anyway
  because the opposite is a hazard. Preserve them when editing; add them when you make
  a non-obvious choice. A reviewer will ask.
- Keep the logic backbone **pure** (no AppKit, no SwiftUI, no global state) so it stays
  unit-testable: `PanelPlacement`, `CitationValidator`, `SourceHarvester`,
  `EvidenceExtractor`, `ResearchContext`, `PlanParser`, `AssessmentParser`,
  `ProviderSettings`, `MarkdownParser`, `ComposerCommand`, `ThreadLibrary`,
  `SemanticVersion`, `HotkeyBinding`.
- No type is `@MainActor`. AppKit callbacks (hotkey handlers, notification observers,
  local event monitors) drive this app, and a type-level `@MainActor` makes those
  closures illegal in Swift 5 language mode. `ResearchEngine` instead hops each of the
  runner's callbacks onto the main queue with `DispatchQueue.main.async`, which is FIFO,
  so streamed chunks land in the order they were produced.

## Dependencies

**None.** No SwiftPM packages, no CocoaPods, no vendored source. Everything is system
frameworks, including the markdown renderer (`AttributedString(markdown:)` for inline
syntax, a hand-written block parser above it). Keep it that way: a research panel that
handles untrusted web content has a small enough attack surface to reason about, and a
dependency tree would end that.

## Critical Constraints

- **The citation rule above is not negotiable.** See "The one load-bearing design
  decision".
- **An evidential verdict without a citation is not a verdict.** `AssessmentParser`
  drops `supported` / `contradicted` / `mixed` findings that cite no source, and adds a
  notice saying one was dropped. Do not "improve" the parser by letting an uncited
  evidential verdict through with a warning.
- **`insufficient` and `opinion` are first-class outcomes** and must never be collapsed
  into "false". They carry no citation *requirement*, but citations on them are kept —
  naming the sources that failed to settle a claim is more useful than a bare verdict.
- **Never let context be truncated silently.** `ResearchContext` drops *whole turns*
  from the oldest end and reports it as a `contextTrimmed` notice. A silently
  over-long prompt produces a confidently wrong answer, which is the failure this
  whole app exists to avoid.
- **Never log or display a provider's own error text.** Gateway messages have been
  observed echoing request data and credentials. Catch, discard, and throw a
  `ResearchError` Vervellum wrote. `ResearchError.safeLabel(for:)` is the only thing
  that may reach the log for a foreign error, and it emits a type name.
- **Never follow a redirect.** `HTTPTransport` refuses every one, because `URLSession`
  would re-send the `Authorization` header to the new host. The one place a redirect is
  *honoured* is `DirectPageReader`, which reads the `Location` off the refused 3xx and
  starts a **fresh, credential-free** request — at most twice, re-validating each hop as
  an absolute `http(s)` URL. That preserves the rule's actual reason rather than
  relaxing it, and applies only to requests that carry no key. Nothing that sends a
  credential may use `HTTPTransport.fetch`.
- **A page Vervellum read is still untrusted data.** Extracted page text goes into the
  same evidence block, under the same prompt, and cannot become a citation — Vervellum
  still owns the numbered list. And a source is marked as read **only when the model
  actually saw its text**: when the evidence budget withholds a page, `ResearchRunner`
  clears `Source.fullText` so the panel, the transcript and the model agree. Do not
  "optimise" that by keeping the text for display.
- **A search backend never leaves the model guessing at a schema.** An MCP server
  advertises its tool and `SearchMCPClient` fetches it rather than assuming; a plain
  JSON API and a CLI have nothing to advertise, so `SearXNGClient` and `KagiCLIClient`
  supply a schema and check the model's arguments back against it. All of them go
  through `SearchBackend.validate(_:required:properties:)`. Do not add a backend that
  sends model-written arguments unchecked.
- **A model-written value never becomes a command.** `KagiCLIClient` is the only
  backend that runs a program, and three rules make that safe: no shell anywhere in
  `CommandRunner` (an argument vector, never a command string), the query passed after
  `--` so it cannot be read as a flag, and every other model-influenced value checked
  against a fixed set *in the client* — `SearchBackend.validate` checks argument names,
  and an `enum` in a JSON Schema is a description rather than a gate. A page found by
  an earlier search is talking to that planner; treat its output accordingly.
- **Keys live in the Keychain only.** Never in `UserDefaults`, never in a thread,
  never in a log line, never in a URL's userinfo. **One item per configured provider**:
  `SecretAccount.modelAPIKey` / `.searchAPIKey` are the accounts every pre-profiles
  build wrote and belong to the migrated first provider, and every provider added since
  gets its own through `SecretAccount.derived(from:for:)`. Never read a fixed account
  for "the model key" — ask `SecretStore.modelKey(for:)`, or one provider's credential
  is sent to another.
- **Show on every Space / over full-screen:** keep `collectionBehavior` =
  `[.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient]` and
  `hidesOnDeactivate = false` on the panel. Level is *not* the lever — see PLAN.md §2 —
  so do not "fix" a coverage problem by raising `level` above `.floating`; that only
  starts covering system menus and turns a modal `NSAlert` into an invisible one.
- **The panel must be able to become key** (`canBecomeKey` overridden to `true`) and
  must **not** become main. Do not override `canBecomeMain` to `true`; that is what
  steals main-window status from the app underneath.
- **The composer stays an `NSTextView`.** A SwiftUI `TextField` cannot reliably retake
  focus in a reused `NSHostingView`, and a field editor maps Shift-Return to
  `insertNewlineIgnoringFieldEditor:`, which never fires `.onSubmit`. Do not "simplify"
  `ComposerView` into a `TextField`.
- **No permission for the core app.** The global shortcut uses Carbon's
  `RegisterEventHotKey`. **Never** add a `CGEventTap` (Input Monitoring) or a global
  `NSEvent` key monitor (Accessibility) to the summon path. The menu bar is hidden in
  full screen, so the shortcut is the only entry point there — it has to work on first
  launch, with no trip to System Settings.
- **Liquid Glass is macOS 26 only.** Gate it `@available(macOS 26, *)`, fall back to
  `NSVisualEffectView`, honour Reduce Transparency, and never nest glass inside glass
  or stack it on a `VisualEffectBlur` — both sample behind-window content and you get a
  double blur. The legibility scrim behind panel content is mandatory, not decoration.
- **Keep `LSUIElement = true`.** Settings temporarily goes `.regular` and reverts to
  `.accessory` on close via the shared `ActivationPolicy` guard. The panel never
  changes activation policy.
- **Keep the main menu.** `AppDelegate.installMainMenu` exists because AppKit routes
  ⌘C, ⌘V, ⌘A, ⌘Z and ⌘Q through main-menu items even in an agent whose menu bar is
  never shown. Remove it and every one of those keys is silently dead in the composer
  and in Settings.
- **The Linux window is not the macOS panel, and cannot be.** On GNOME Wayland — the
  Ubuntu default — a client cannot position its own window, cannot keep it above others,
  and has no layer-shell protocol to fall back on; `gtk_window_move`,
  `set_position` and `set_keep_above` do not exist in GTK4 at all. Do not add an
  X11-only escape hatch for it: GTK deprecated the X11 backend in 4.17 and plans to
  remove it. Say what the platform does instead of implying parity.
- **Linux does not grab the shortcut itself.** The GlobalShortcuts portal has no GNOME
  backend before GNOME 48, and Mutter no longer honours XWayland global grabs. The
  desktop runs `gapplication action ch.lkmc.Vervellum toggle` on the key press and
  `GtkApplication` routes it to the running instance. Do not replace that with an
  in-process grab.
- **One identity string.** `ch.lkmc.Vervellum` is the D-Bus name, the `.desktop`
  basename and `StartupWMClass`. Single-instance handling, the dock icon and desktop
  activation all key off it and all three break silently when they diverge.
- **Desktop action identifiers are GApplication action names.** With
  `DBusActivatable=true` GNOME never runs a `[Desktop Action …]` group's `Exec` line; it
  calls `org.freedesktop.Application.ActivateAction` with the group's identifier, and
  `GApplication` looks that up in its action map. `toggle` and `install-shortcut` exist
  in both `LinuxApp` and the `.desktop` file; add a new action to both or it silently
  does nothing.
- **An `OpaquePointer` does not convert to `gpointer`.** Swift imports every GTK
  *final* type (`GtkCssProvider`, `GtkEventController`, …) as `OpaquePointer`, and
  unlike a typed pointer it has no implicit conversion to the `UnsafeMutableRawPointer`
  that `g_object_unref` and friends take. Spell `UnsafeMutableRawPointer(p)`.
- **An ad-hoc signature resets the Accessibility grant on every update.** TCC keys the
  grant to the code signature, and CI ad-hoc signs, so the cdhash changes with every
  build and macOS silently drops the permission. `SelectedTextReader.grantWasRevoked()`
  detects it and the alert explains it. Do not "fix" this by re-prompting on launch or
  by auto-requesting — the real fix is a Developer ID signature, which TCC keys by Team
  ID and bundle ID instead. Keep the detection until then.
- **Text captured from another app is redacted before it reaches the composer**, not
  before it is sent. The user has to be able to see and correct what will leave the Mac.
  `SecretRedactor` errs toward redacting, because a false positive costs a re-typed word
  and a false negative sends a live credential to a third party.
- **`URLSession.AsyncBytes.lines` cannot parse SSE.** `AsyncLineSequence` yields nothing
  for an empty line, and in Server-Sent Events the blank line is what dispatches the
  event — framing on `.lines` silently merges every frame in the stream into one.
  `HTTPTransport.readLines` splits the raw bytes itself. Do not "simplify" it back.
- **`Accept` is per-call.** A non-streaming request must not advertise
  `text/event-stream`: a gateway may content-negotiate on it and answer a `"stream":
  false` call with a stream, which the buffered reader would then mis-report.

## Testing Notes

- The shared tests live in `Tests/VervellumKitTests/` and run on **both** platforms —
  under `swift test` on Linux and in the Xcode test target on macOS, which pulls the
  same directory in through a second synchronized group. That is what keeps one
  platform's copy of a rule from drifting. Each file picks its module with
  `#if canImport(VervellumKit)`, because the code is a module on Linux and part of the
  app target on macOS.
- `VervellumTests/` is macOS-only: hotkey bindings, panel geometry, the Accessibility
  reader, and the `UserDefaults`-backed preference shell.
- Unit-test the pure logic listed under Conventions, plus the archive's crash-safety
  behaviours: atomic write, `.bak` recovery, `0600` permissions, read-only handling of
  a document from a newer build, and that turning history off *deletes* the file.
- `AppDelegate.applicationDidFinishLaunching` is guarded by `isRunningTests`, so the
  test host does not register global shortcuts, install a status item, or read the real
  user's preferences.
- Tests inject their own `UserDefaults` suite and their own file URL. Never let a test
  touch `.standard` or the real Application Support path.
- Needs a **real GUI session** and is verified by hand: panel placement over a
  full-screen app, the activation handoff, multi-display re-summon, Liquid Glass, the
  Accessibility selection path, and IME composition in the composer.

## Do / Don't

- **Do** update `PLAN.md` when the design changes, and keep `README.md`,
  `SECURITY.md` and `PRIVACY.md` in step with what the code actually does. These get
  fact-checked in review — state what is implemented, never what is aspirational.
- **Do** treat every prompt in `ResearchPrompts` as product surface. Each one enforces
  a named property, documented at the top of the file. Changing a prompt without
  saying which property it defends is a regression waiting to happen. The `trust`
  prompt's evidence paragraph is per-*entry* for a reason: `snippet` alone is a search
  summary and may not be quoted, `page_text` is the page and may be. Do not collapse
  the two back into one rule in either direction.
- **Do** assume Developer ID + notarization, not the App Store — the sandbox cannot
  grant the Accessibility access the selection feature needs.
- **Don't** add dependencies; prefer system frameworks.
- **Don't** run the assessment stage in parallel with the answer stage. It does not
  depend on the prose, so it looks like free latency — but assessing the answer that
  was *actually written* is the whole reason the verdict table can be trusted. The
  revision stage sits *after* the assessment for the other half of the same reason: a
  correction made against a check that has actually run. That ordering is what makes
  the findings describe the draft rather than the prose above them, which is why
  `draftAnswer` is kept and a notice says which is which.
- **Don't** widen what sends an answer back for revision. `contradicted` and `mixed`
  are the answer being wrong about the evidence in front of it; `insufficient` is a
  hedge the answer prompt asks for, and triggering on it would put a second long model
  call on nearly every turn. The reviser is shown those findings; it is not woken by
  one.
- **Don't** let a revision reach the screen unvalidated. It arrives after the citation
  validation the reader's trust in `[n]` rests on, so it is checked *before* it is
  accepted and dropped whole if it invents a number or writes a URL. A failed or
  discarded revision must leave the answer exactly as the assessment left it — the
  prose has already been streamed and read, and losing it to a bad rewrite is the
  worst outcome available there.
- **Don't** make the panel dismiss on focus loss by default. A run takes tens of
  seconds and the answer is meant to be read while working. The preference exists for
  people who want the Spotlight feel, and even then a run in flight keeps the panel up.
- **Don't** reach for private APIs. There is currently no use of one, and that is worth
  keeping.
- **Do** put every GTK cast, macro and variadic in `Sources/CGtk/shim.h` as a
  `static inline` function, not in Swift. Swift cannot import function-like macros
  (`GTK_WINDOW`, `G_OBJECT`, `g_signal_connect`) or call C variadics at all, and it
  represents an opaque GTK type as `OpaquePointer` but a complete one as
  `UnsafeMutablePointer<T>` — casting in C means the Swift side never has to know which
  is which, and a mistake is a C compile error rather than a silent reinterpretation.
- **Don't** add a second Linux settings file, secret store or thread format. Both
  platforms go through `SettingsStore`, `SecretStore` and `ThreadArchive`; a new
  backend implements the protocol and says which one it is in
  `backendDescription`.
- **Don't** write an aspirational claim into `SECURITY.md`, `PRIVACY.md`, `README.md` or
  the entitlements comment. Releases are ad-hoc signed, unsigned and un-notarized;
  redaction is a safety net, not a guarantee; the updater checks an asset's size and not
  its signature. Each of those is stated plainly, and each has a "What is *not*
  protected" home in `SECURITY.md`. Reviewers fact-check these against the code.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->
