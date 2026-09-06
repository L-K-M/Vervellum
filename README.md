# Vervellum

A hotkey-summoned research panel for macOS and Linux — it looks things up, then shows its work.

**Latest release:** v<!-- version -->0.1.0<!-- /version --> · [Download](https://github.com/L-K-M/Vervellum/releases/latest)

> [!IMPORTANT]
> LLM Disclosure: Vervellum was built with substantial help from large language models.

Press ⌃⌥⌘Space anywhere — including over a full-screen app — and a panel slides in at
the edge of the screen. Type a question. Vervellum plans web searches, runs them,
streams an answer that cites only what it actually found, and then grades its own
claims against that same evidence.

## Why it is not a chat window

Most floating LLM panels answer from the model's weights. The result is fluent, and
you cannot tell which sentences are load-bearing facts and which are plausible
reconstruction. Vervellum inverts that: the answer is the cheap part, the evidence is
the product.

- **The model cannot invent a link.** Vervellum runs the searches, so it owns the
  numbered source list. The answer may refer to evidence only as `[1]` or `[2, 5]` —
  there is no syntax in which a fabricated URL could be written.
- **Every claim gets a verdict.** A second pass grades the answer's own claims against
  the same evidence: *supported*, *contradicted*, *mixed*, *not established*, or
  *opinion*. A verdict that cites no source is discarded, and you are told one was.
- **"We found nothing" is an answer.** *Not established* is a first-class outcome, not
  an error state, so the model has an honest place to put a claim it cannot support.
- **The process is visible.** What it decided to look up, what it searched for, how
  many sources it kept, how many it cited. Loud while it runs, one line afterwards.
- **Sources are shown as what they are.** Search summaries, not full articles — said
  plainly on every source, because a citation cannot prove the page supports the
  reading of it.

## Features

- **Summon from anywhere.** A global shortcut that needs **no permission** and works
  over another app's full-screen window without switching Spaces.
- **Threaded.** Follow-up questions carry the thread's context, including which earlier
  claims were left unsettled. Threads are searchable and kept, or not kept at all.
- **Keyboard-first.** `Return` asks, `Esc` clears then closes, `↑`/`↓` walk back through
  earlier questions, `/` opens commands. Everything in the header is also a command.
- **Research the selection.** An optional second shortcut opens the panel with whatever
  text you had selected — with credential-shaped values stripped out first.
- **`/direct`** answers with no search at all, clearly badged as unsourced.
- **Bring your own providers.** Any OpenAI-compatible Chat Completions endpoint, and a
  Model Context Protocol web-search server. Keys live in your Keychain.
- **Native.** SwiftUI and AppKit, Liquid Glass on macOS 26, no dependencies at all.

## Getting started

### macOS

1. Launch Vervellum. It appears as a magnifier in the menu bar.
2. Open **Settings ▸ Providers** and fill in a model endpoint, a model name, and a
   web-search key. The panel offers this on first launch, because nothing works
   without it.
3. Press **⌃⌥⌘Space** and ask something.

### Linux (Ubuntu 24.04+)

```bash
sudo apt install ./vervellum_0.1.0_amd64.deb
vervellum --install-shortcut          # binds ⌃⌥⌘Space in GNOME
```

Configure it by editing `~/.config/vervellum/settings.json`:

```json
{
  "modelEndpoint": "https://api.example.com/v1",
  "modelName": "your-model",
  "searchEndpoint": "https://api.z.ai/api/mcp/web_search_prime/mcp"
}
```

The behaviour toggles are the same keys the macOS Settings window writes:
`historyEnabled`, `showProcessTrail`, `submitOnReturn` (booleans) and `textScale`
(0.85–1.4). The file is read at launch.

Then store the keys in your login keyring, or export them:

```bash
secret-tool store --label "Vervellum model-api-key" \
    service ch.lkmc.Vervellum account model-api-key
export VERVELLUM_MODEL_KEY=…  VERVELLUM_SEARCH_KEY=…
```

No desktop at all? `vervellum --ask "your question"` runs the whole pipeline and prints
the answer, its verdicts and its sources. It needs no display and no session bus.

> [!NOTE]
> On GNOME Wayland the Linux build is an ordinary window, not an edge-docked overlay.
> A Wayland client cannot position its own window or keep it above others, and GNOME
> does not implement the layer-shell protocol that would allow it — `gtk_window_move`
> and `set_keep_above` do not exist in GTK4 at all. The shortcut, the pipeline and the
> evidence UI all work; the window placement is the compositor's.

## Build & Run

### Linux

Needs a **Swift 6.0+** toolchain (earlier ones lack the async `URLSession` methods on
Linux) plus `libgtk-4-dev` and `pkg-config`.

```bash
swift build -c release --product vervellum
swift test --parallel            # the shared core's tests
packaging/build-deb.sh 0.1.0     # -> build/vervellum_0.1.0_<arch>.deb
```

### macOS

Requires **Xcode 26** (for Liquid Glass) and **macOS 14+** (Liquid Glass renders on
macOS 26; older systems get a blurred fallback).

```bash
# Build
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum -configuration Debug build

# Release build
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum -configuration Release build

# Run unit tests
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum -destination 'platform=macOS' test
```

`scripts/build.sh` does a convenient incremental Release build via the shared
`lkm-build` engine (`scripts/build.sh --clean` for a clean rebuild).

## Permissions

**macOS: the core app needs none.** The global shortcut uses the system's own hotkey
registration rather than a keyboard monitor, so it works the moment you launch the
app — which matters, because the menu bar is hidden in full screen and the shortcut is
the only way in there.

One optional feature needs one permission: **Research the Selection** reads the
frontmost app's selected text through **Accessibility**. It is off by default,
explains itself before macOS shows its own prompt, and everything else works without
it.

> [!NOTE]
> Release builds are ad-hoc signed (see Distribution). macOS ties an Accessibility
> grant to an app's code signature, and an ad-hoc signature changes with every build —
> so **every update resets this one permission**. Vervellum detects that and tells you
> what happened instead of failing quietly. Remove it from the Accessibility list and
> add it again to restore the feature.

## Privacy

Your question, its thread, and the search results go to the two providers you
configured, and nowhere else. There is no account, no telemetry, no analytics. Threads
and preferences stay on your machine. API keys go in the Keychain on macOS, and on Linux
in your login keyring — or, if no keyring is running, in an environment variable or a
mode-0600 file, and the app tells you which. Text captured by the macOS selection
shortcut is scanned for credential-shaped values before it reaches the composer, and you
are told how many were removed. See [PRIVACY.md](PRIVACY.md).

## Distribution

Non-sandboxed, outside the Mac App Store — the sandbox cannot grant the Accessibility
access the selection feature needs. CI publishes an **unsigned, un-notarized**
build for each tag, ad-hoc signed only so it will launch on Apple Silicon. Gatekeeper
will warn on first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Vervellum.app
```

Or right-click the app → **Open** → **Open**.

The Linux `.deb` is unsigned too. It is built in the official Swift container for
Ubuntu 24.04, links the Swift runtime statically, and declares its remaining
dependencies with `dpkg-shlibdeps` rather than a hand-written list.
