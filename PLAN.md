# Vervellum — Design & Plan

A hotkey-summoned **research** panel for macOS and Linux. Press a shortcut anywhere — including
over a full-screen app — and a panel slides in at the edge of the screen. Type a
question. Vervellum plans web searches, runs them, writes an answer that can cite only
the sources it actually retrieved, and then grades its own claims against that same
evidence.

---

## 1. What this is, and what it deliberately is not

There is a well-established shape for "LLM in a floating window": a hotkey, a text
field, a streamed reply. It is genuinely useful and it is also, structurally, a
chatbot in a smaller window. The model answers from its weights, the answer is fluent,
and the user has no way to tell which sentences are load-bearing facts and which are
plausible reconstruction.

Vervellum is built around the opposite premise: **the answer is the cheap part; the
evidence is the product.** Everything below follows from that.

| | A chat panel | Vervellum |
|---|---|---|
| Where the answer comes from | model weights | web sources retrieved this turn |
| What a citation is | a link the model wrote | an index into a list Vervellum fetched |
| What happens when evidence is thin | fluent hedging | an explicit `Not established` verdict |
| What the user sees of the process | a spinner | the plan, the queries, what was kept |
| What is checked | nothing | every claim the conclusion rests on |

### 1.1 The one load-bearing design decision

**The model may not write URLs. It may only cite by number.**

Every other trust mechanism in the app is downstream of this. Vervellum runs the
searches, so it — not the model — owns the source list. The answer prompt forbids
URLs, domains and markdown links outright, and requires evidence to be referenced as
`[1]` or `[2, 5]`.

Only numbered citations can become actionable answer links. Both renderers remove
model-origin link behavior, then resolve valid numbers through the retrieved source
list. Literal URLs are flagged; invalid numbers remain text. Shared placeholder
masking preserves citation placement, including through incomplete markdown.
This establishes provenance, not whether the cited evidence supports the claim.

It is also more robust than the obvious alternative — allow-listing the URLs the
search returned and string-matching what the model wrote. A model that reformats a
link (adds a tracking parameter, drops a trailing slash, percent-encodes a character)
would fail an exact-match allow-list *even though it cited a real source*. Integers do
not have that failure mode.

**Do not relax this** to "the model may write links if we check them". The check is
not the mechanism; the absence of expressible syntax is.

### 1.2 The second decision: verdicts are separate from prose

The answer and the verdict table come from two different calls with two different
prompts. The answer is asked to be readable; the assessment is asked to be *harder on
the answer than the answer was on itself*, and is bound by two rules the parser
enforces rather than the prompt:

- A verdict of `supported` / `contradicted` / `mixed` **must** cite at least one
  source. Without a citation it is the model's prior wearing a verdict's clothes, so
  it is dropped and the user is told one was dropped.
- `insufficient` ("not established") and `opinion` are first-class outcomes rather than
  error states, and carry no such requirement. They may still cite: "not established,
  and here are the two sources that failed to settle it" is strictly more useful than a
  bare verdict.

Source numbers must be an array of exact integers or integer strings. Boolean, fractional,
non-finite, overflow, and out-of-range references are discarded and reported.

That asymmetry is the point. It gives the model an honest place to put a claim it
cannot support, so it is not forced to choose between fabricating support and staying
silent. Collapsing "we found nothing" into "false" is the single most damaging thing a
research tool can do.

### 1.3 The third decision: the process is visible, then quiet

Showing the machinery builds trust; showing it forever is noise. So the process trail
is loud while a turn runs — naming the stage, the number of queries, what was kept —
and collapses to one line the moment the answer lands:

```
✓  4 searches · 17 sources · 6 claims checked · 0:41
```

Expandable, never gone.

---

## 2. Feasibility: showing a panel over a full-screen app

The hard requirement from the outset was that the shortcut must work while the user is
in a full-screen app on another Space, and must not yank them out of it. That is
achievable with public API, but only with a specific combination:

```swift
styleMask          = [.borderless, .nonactivatingPanel]
level              = .floating
collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                      .fullScreenAuxiliary, .transient]
hidesOnDeactivate  = false
override var canBecomeKey: Bool  { true }
override var canBecomeMain: Bool { false }
```

Each part earns its place:

- **`.canJoinAllSpaces`** — the panel exists on *every* Space, so showing it needs no
  Space switch. A `.moveToActiveSpace` panel would drag the user out of their
  full-screen app, which is precisely the failure being avoided.
- **`.canJoinAllApplications`** — the flag that actually covers *another app's*
  full-screen space, and the one Apple documents for floating windows and system
  overlays. `.fullScreenAuxiliary` is specified for the same app's own full-screen
  window; it is kept alongside for that case, but on its own it is not the lever.
- **`.transient`** — Mission Control hides the panel rather than floating it on top of
  the overlay, which is what `.stationary` would do.
- **`.nonactivatingPanel`** — showing the panel does not by itself make Vervellum the
  active app.
- **`canBecomeKey` overridden** — a borderless panel refuses key status by default,
  and a panel that cannot become key cannot receive typing. This one override is the
  difference between a working composer and one that silently swallows every
  keystroke.
- **`canBecomeMain` left false** — main status belongs to the app the user was working
  in; taking it would deactivate that app's title bar for no reason.
- **`hidesOnDeactivate = false`** — `NSPanel` overrides `NSWindow` and defaults this to
  *true*. Left alone, the panel vanishes the instant Vervellum stops being frontmost,
  which is immediately.

**Level is not the lever.** A window level orders windows only *within* a space, so no
amount of raising it will put a window into another app's full-screen space; that is
`collectionBehavior`'s job alone. `.floating` (3) sits above every ordinary window and
below all system chrome. Going higher — `.popUpMenu` is 101 — buys nothing for
full-screen coverage and costs real things: the panel would cover the menu bar, the
Dock, and genuine `NSMenu`s including the one this app's own status item pops, and a
modal `NSAlert` at `.modalPanel` (8) would render *behind* it as an invisible modal.

`NSApp.activate()` is still called on show, because the window server routes keystrokes
to the *active application's* key window — a non-activating panel alone would show a
caret and receive nothing. The panel is ordered in first, so that activation finds an
all-spaces window already on the current space and stays there.

On dismissal the previously-frontmost app is restored with
`NSApp.yieldActivation(to:)` followed by `activate(options:)` — the cooperative
handoff, which the window server does not treat as focus-stealing — and **only if
Vervellum is still the active app.** If the user dismissed the panel by clicking into
something else, that app is already frontmost and must not be yanked away. A separate
flag distinguishes "the captured app quit while the panel was open" (fall back to the
Finder, so an agent with no menu bar is not left frontmost with nothing to show) from
"there was deliberately nothing to restore".

### 2.1 Permissions

**The core app needs none.** The global shortcut uses Carbon's `RegisterEventHotKey`,
which requires no permission — unlike `CGEventTap` (Input Monitoring) or
`NSEvent.addGlobalMonitorForEvents` (Accessibility). This matters more than it sounds:
the menu bar is hidden in full screen, so the shortcut is the *only* entry point
there, and a feature that needs a trip to System Settings before it works at all is a
feature most people never see working.

Exactly one optional feature needs a permission: **research the selection**, which
reads the frontmost app's selected text through the Accessibility API. It is off by
default, explains itself in words before macOS shows its own one-time prompt, and
every other feature works without it.

The Accessibility API is used rather than synthesising a ⌘C keystroke. Synthetic
copying is worse in every way that matters: it clobbers the clipboard, it needs the
same permission anyway, it fails in apps that bind ⌘C to something else, and it races
the target app's own copy handling. Reading `kAXSelectedTextAttribute` is a passive
query with no side effects.

---

## 3. The research pipeline

Four calls, in this order. The order *is* the design.

```
     ┌─ 1. PLAN ────────────────────────────────────────┐
     │  one small JSON call: which factual questions     │
     │  does the answer depend on, and what searches      │
     │  would settle them — including one that could      │
     │  DISCONFIRM the likely answer                      │
     └───────────────────────┬──────────────────────────┘
                             ▼
     ┌─ 2. SEARCH ──────────────────────────────────────┐
     │  each planned query, run against the web-search   │
     │  MCP server; results become a NUMBERED source     │
     │  list that Vervellum, not the model, owns          │
     └───────────────────────┬──────────────────────────┘
                             ▼
     ┌─ 3. ANSWER (streamed) ───────────────────────────┐
     │  prose that may cite only those numbers;           │
     │  first tokens on screen in a second or two          │
     └───────────────────────┬──────────────────────────┘
                             ▼
     ┌─ 4. ASSESS ──────────────────────────────────────┐
     │  a second JSON call grading the answer's own       │
     │  claims against the same evidence, harder than     │
     │  stage 3 was asked to be                           │
     └──────────────────────────────────────────────────┘
```

**Why stage 1 is separate from stage 3.** A single call that searches and answers
turns the query into a keyword echo of the question. Planning as its own step is where
the "seek disconfirming evidence" instruction can actually bite, and it produces the
`reading` line — one sentence stating how the model understood the question — which is
often where a bad answer is caught before it costs a search.

The planner may also decide that a question needs no evidence at all — a definition, a
calculation, a request to transform text the user supplied — by returning an empty
plan. That is honoured rather than treated as a failure: the turn is answered from the
model alone and badged exactly as `/direct` is, with the reading kept as the
explanation of why nothing was searched.

**Why stage 4 runs after stage 3, not beside it.** It does not depend on the prose, so
it could run in parallel and halve the perceived latency. It does not, because
assessing *the answer that was actually written* is what keeps the verdict table
honest. Run in parallel, the table would quietly disagree with the paragraph above it,
and a reader would have no way to tell which one to believe. The user is reading the
streamed answer while stage 4 runs, so the latency that matters is already hidden.

If assessment fails, the completed answer remains with an `assessmentUnavailable`
notice. That qualification also travels with follow-up history. Missing or unknown
finish reasons, malformed SSE data, and provider error envelopes instead leave the
answer incomplete; only `finish_reason: stop` completes a model reply. Retained prose
is citation-validated after cancellation, failure, and checkpoint recovery.

**Why searches are sequential.** The MCP session is stateful — one JSON-RPC id
sequence over one connection is the only shape the server documents. Four searches at
about a second each is well inside the user's patience, and a failed search is logged
and skipped rather than losing the other three.

### 3.1 The search transport

Web search goes through a Model Context Protocol server over HTTP. The client
implements four messages — `initialize`, `notifications/initialized`, `tools/list`,
`tools/call` — and honours the transport quirks a real MCP gateway has:

- the server chooses the **protocol version** in the `initialize` result, which every
  later request must echo in `MCP-Protocol-Version`;
- it may open a **session** by returning `Mcp-Session-Id` on *any* response;
- a response may arrive as **JSON or as an SSE stream**, chosen per request;
  SSE lines are scanned once per byte, preserving empty lines across LF, CRLF, and
  CR boundaries, including split UTF-8 and a leading byte-order mark;
- `notifications/initialized` carries no `id`, so its acknowledgement is an empty
  `202` — not an error, though it looks like one;
- the gateway in front of the MCP server has its **own error envelope**
  (`{"success": false, "code": N}`) returned with HTTP 200, so a request can fail
  before it ever reaches the protocol layer.

Only recognized web-search tool names are selected, in a fixed preference order.
Descriptions and query-shaped arguments cannot establish an unknown operation's
purpose. Unknown tools are rejected; provider-controlled names never enter diagnostics.
The model sees the actual input schema; required and unknown argument names are
checked before calling the tool. This is not full JSON Schema validation.

A model request rejected with HTTP 400 is retried once without optional temperature
and JSON-mode fields. That fallback is remembered for the current turn's client.
Non-streaming calls allow 600 seconds of inactivity; streams allow 120 seconds.
Byte-reader deadline checks are not an absolute end-to-end timer.

### 3.2 Context budget

All model stages share a 110,000-byte serialized UTF-8 context ceiling; evidence has
its own 70,000-byte ceiling. These are not tokenizer guarantees. Historic answers
are shortened explicitly, then whole older turns are omitted as needed; both produce
a `contextTrimmed` notice. Evidence drops a suffix and reports it, preserving numbering.
Obsolete citation markers are removed from historic answers and finding claims.
Document validation uses the renderer's block and table-cell boundaries; inline
rendering validates only inline syntax, so backticks cannot suppress unrelated citations.

If fixed context still exceeds the ceiling, the request fails locally rather than
silently truncating the current question, answer, or evidence. Assessment failure
therefore retains the answer with an explicit limitation.

---

## 4. Security posture

Two threat models, treated separately.

### 4.1 Prompt injection

Search results are attacker-controlled in the general case: anyone can put "ignore
your previous instructions" on a web page. Every prompt therefore opens by declaring
all retrieved content, and all earlier thread content, to be **untrusted data, never
instructions**, and says explicitly what such text tends to look like.

Prompting is a mitigation, not a guarantee — which is exactly why the citation rule in
§1.1 is structural rather than instructional. Model-written URLs cannot become
actionable answer links; source support still requires inspection.

### 4.2 Credential handling

Provider requests share a transport built around three credential-protection rules:

1. **Redirects are never followed.** `URLSession` re-sends headers — including
   `Authorization` — to a redirect target by default. A provider, or anything that can
   answer for its hostname, could harvest the key with a single `302`. The session
   delegate refuses every redirect.
2. **Responses are capped**, so a hostile or malfunctioning endpoint cannot stream
   gigabytes into the app.
3. **Provider errors never escape verbatim.** Gateway messages have been observed
   echoing request data and credentials, so every underlying error is caught and
   replaced with a message Vervellum wrote. The logs get a type name, never a
   description. Search diagnostics print only known schema field names and aggregate
   counts; arbitrary keys are omitted because they can contain secrets too.

Keys live in the login Keychain, never in preferences and never in a thread. Endpoints
must be HTTPS (with a loopback exception for a local model server, which has no
certificate) and may not carry userinfo, because a `https://key@host/` URL leaks the
credential into every log line.

### 4.3 The user's own secrets

The selection shortcut is the one path where Vervellum can transmit something the user
did not type. Someone who presses it with a terminal focused can send an API key, a
`.env` line, or a private key without ever reading what they sent.

So captured text is scanned by `SecretRedactor` before it reaches the composer —
**before**, not before sending, because the user has to be able to see and correct what
will leave the Mac rather than trust that something downstream cleans it up. The
composer says how many spans were removed.

It is honest about being a safety net rather than a guarantee: a secret with no
recognisable shape passes straight through. Where a false positive and a false negative
conflict, the patterns are written to fire — a false positive costs a re-typed word, a
false negative sends a live credential to a third party.

### 4.4 What is not protected

Released builds are **ad-hoc signed, unsigned and un-notarized**. That has one
consequence worth stating in the design rather than discovering in a bug report: macOS
keys an Accessibility grant to the code signature, and an ad-hoc signature's hash
changes with every build — so **every update silently revokes the selection feature's
permission.** Vervellum detects the transition and explains it instead of failing
quietly. A Developer ID signature, which TCC keys by Team ID and bundle identifier
instead, is the fix and is the top backlog item.

---

## 5. Interaction design

### 5.1 Summoning

⌃⌥⌘Space by default — three modifiers, so it cannot collide with Spotlight (⌘Space) or
an input-source switch (⌃Space). Pressing it again dismisses. Pressing it while the
panel is open **on a different screen** moves the panel to the screen the pointer is
on rather than dismissing it, which is what Spotlight and Raycast both do and what
makes a shortcut usable on a multi-display desk.

The panel opens on the screen **under the pointer**, not `NSScreen.main` — which is
the screen with the key window, and on a multi-display desk is routinely not where the
user just pressed the shortcut.

### 5.2 Dismissal, and why it is not Spotlight's

Spotlight vanishes the instant it loses focus. That is right for a launcher, whose
whole interaction is over in two seconds, and wrong here: a research run takes tens of
seconds, and the answer is meant to be read *while working*. A panel that vanished the
moment the user clicked back into their editor would throw away exactly the thing they
asked for.

So the panel stays until deliberately dismissed — Escape, the shortcut, ⌘W, or the
close control. `Settings ▸ General` offers the Spotlight behaviour for people who want
it, and **even then a run in flight keeps the panel up**: a provider's own
authentication sheet, a system alert, or a glance at another window all resign key
status, and losing a 40-second answer to any of them would be indefensible.

### 5.3 Keyboard

| Key | Action |
|---|---|
| `⌃⌥⌘Space` | summon / dismiss (configurable) |
| `⌃⌥⌘J` | summon with the selection (off by default) |
| `Return` | ask — `Shift-Return` for a newline, swappable in Settings |
| `⌘Return` | ask, whichever way `Return` is configured |
| `Esc` | clear the draft; a second press closes |
| `↑` / `↓` | walk back through this thread's earlier questions |
| `⌘N` | new thread |
| `⌘Y` | earlier threads |
| `⌘.` | stop the running research |
| `⌘,` | Settings |
| `⌘W` | close |
| `/` | commands |

The Command-modified shortcuts are handled by the panel window's
`performKeyEquivalent(with:)` rather than by the composer or a SwiftUI modifier: a
Command-modified key never reaches `NSTextView`'s `doCommandBy(_:)`, so implementing
them anywhere else leaves them silently dead.

Copy and the Linux CLI include every source cited by either the answer or its
findings. Failed or stopped research keeps its partial answer, sources, and caveats;
incomplete turns are labelled so an exported answer cannot imply a finished check.

Everything reachable from the header is also reachable by typing: `/direct`, `/new`,
`/history`, `/settings`, `/copy`, `/help`. Slash parsing is deliberately strict — a
leading slash is only a command when the word after it is one Vervellum knows, so
"/etc/hosts is world readable, right?" stays a question.

### 5.4 The composer is an NSTextView, not a SwiftUI TextField

Three reasons, each of which costs a day to discover the hard way:

- **Focus.** A SwiftUI `@FocusState` inside a reused `NSHostingView` in a
  non-activating panel does not reliably retake first responder when the panel is
  shown again — the view never left the hierarchy, so nothing re-fires. Owning the
  text view means focus can simply be asserted, on a notification posted at every
  summon.
- **Return.** A single-line field editor maps Shift-Return and Option-Return to
  `insertNewlineIgnoringFieldEditor:`, which never fires the field's action. With a
  SwiftUI `TextField`, `.onSubmit` sees plain Return only and a modified Return
  silently does nothing.
- **Growth.** The composer grows from one line to about six and then stops. That is a
  layout-manager height calculation, not something `TextField` exposes.

### 5.5 Visual design

Liquid Glass on macOS 26, `NSVisualEffectView` below it — **plus a legibility scrim in
both cases**. Glass takes its colour from whatever is behind the window, and "whatever
is behind the window" is the user's entire desktop; without a scrim the same 13pt
paragraph is crisp over a dark editor and unreadable over a bright photo.

Glass is never nested. The panel background is glass; every card and chip inside it is
a flat translucent fill. Layering glass on glass produces mud and costs a render pass
per layer.

Verdict meaning is never carried by colour alone: each verdict has a distinct SF
Symbol, a text label, and an accessibility string that spells it out.

---

## 5.6 Two platforms, one core

Vervellum ships for macOS and for Ubuntu, and the split between them is drawn at the
point where the interesting decisions stop.

**Shared** (`Sources/VervellumKit/Core/`, Foundation only): the four-stage pipeline, all
four prompts, both response parsers, citation validation, source harvesting, evidence
extraction, context budgeting, the thread document and its archive, markdown parsing,
slash commands, transcript formatting, secret redaction, the preference schema and the
version comparison. That is roughly two thirds of the code and effectively all of the
rules — so a fix to a validation rule, a prompt or a parser reaches both platforms
without being ported.

**Per platform**: the window, and four seams behind protocols.

| Seam | macOS | Linux |
|---|---|---|
| `SecretStore` | login Keychain | login keyring, else an env var, else a `0600` file |
| `SettingsStore` | `UserDefaults` | JSON under `$XDG_CONFIG_HOME` |
| `LogSink` | `os.Logger` | standard error |
| observation | `ObservableObject` shells over the core types | direct callbacks |

The observation seam is the one that looks like duplication and is not. `ObservableObject`
comes from Combine, which does not exist on Linux, so an engine that published directly
could not be shared at all. Instead `ResearchRunner` and `ThreadArchive` hold the logic
and report through plain callbacks, and each platform wraps them in a few dozen lines —
`ResearchEngine` and `ThreadStore` on macOS, the panel itself on Linux.

### What the Linux build cannot do, and why

Not a matter of effort. On GNOME Wayland — Ubuntu's default — a client cannot position
its own window, cannot raise it above others, and has no layer-shell protocol to fall
back on. `gtk_window_move`, `set_position` and `set_keep_above` were removed in GTK4
outright. So the Linux front end is an ordinary window that the compositor places, not
an edge-docked overlay, and the documentation says so rather than implying parity.
Native close, Escape, and the panel's Close button hide the window rather than
destroying it; the next shortcut reuses the same window and thread. Quit is separate.

The shortcut is registered *with the desktop* instead of grabbed by the app: the
GlobalShortcuts portal has no GNOME backend before GNOME 48, and Mutter no longer
honours XWayland global grabs. GNOME runs
`gapplication action ch.lkmc.Vervellum toggle` on the key press, and `GtkApplication`
delivers it to the running instance over D-Bus. This works identically on X11 and
Wayland, and over full-screen windows, because the compositor owns the grab.

Two Swift-on-Linux facts shaped the shared code rather than the Linux code:

- **`URLSession.bytes(for:)` does not exist in swift-corelibs-foundation.** Rather than
  keep two streaming implementations — one of which would only run on the platform with
  less coverage — `HTTPTransport` uses `URLSessionDataDelegate` on both. It is the older
  API, and it is the one that actually streams: a completion-handler task buffers the
  whole body before returning.
- **A GLib main loop does not drain libdispatch's main queue.** A `MainActor` hop under
  GTK hangs silently. So the core never marshals to the main actor itself; it reports
  through a callback and each front end marshals — `DispatchQueue.main.async` on macOS,
  `g_idle_add` on Linux.

There is also a headless mode, `vervellum --ask "…"`, which runs the whole pipeline with
no display, no session bus and no GTK. It is useful in a script, and it is the cheapest
way to exercise the shared core end to end on a machine with no desktop at all.

## 6. Module layout

The shared core (`Sources/VervellumKit/Core/`) and the Linux front end are laid out in
§5.6 and, file by file, in `AGENTS.md`. The macOS front end, `Vervellum/`:

- `App/` — `VervellumApp` (the `@main` entry point) and `AppDelegate`, which owns
  everything with a lifetime: preferences, store, engine, panel, status item, both
  shortcuts, and the main menu that an agent still needs for ⌘C/⌘V/⌘Q to work.
- `Panel/` — `ResearchPanel` (the `NSPanel` subclass and its flags), `PanelController`
  (show / hide / place / focus handoff), and the pure `PanelPlacement` geometry.
- `Research/` — `ResearchEngine`, an `ObservableObject` shell over the shared
  `ResearchRunner`. The pipeline itself — the clients, the prompts, both parsers, the
  validators — lives in Core.
- `Model/` — `Preferences` (the macOS-only settings, forwarding the shared ones to
  `CorePreferences`) and `HotkeyBinding`.
- `Store/` — `ThreadStore`, an `ObservableObject` shell over Core's `ThreadArchive`
  (atomic checkpointed JSON with one `.bak`).
- `Security/` — `KeychainStore`, the macOS `SecretStore`. `SecretRedactor` is shared.
- `Selection/` — `SelectedTextReader` (the Accessibility path).
- `Hotkeys/` — `CarbonHotkey`, `KeyCodes`.
- `Views/` — the SwiftUI panel: theme tokens, markdown parser and renderer, composer,
  process trail, findings, sources, history, empty state.
- `Settings/` — the four panes and their window controller.
- `Updates/` — the GitHub self-updater, shared with the sibling apps.

The logic backbone is deliberately free of AppKit and SwiftUI so it can be
unit-tested: placement geometry, citation validation, source harvesting, evidence
extraction, context budgeting, both response parsers, the markdown block parser,
slash-command parsing, preference clamping, and the version comparison.

---

### History durability

Both front ends submit active snapshots. The first pending checkpoint keeps its
one-second deadline, so continuous prose cannot postpone persistence indefinitely.
macOS coalesces prose publication at 10 Hz; Linux keeps its model current and throttles
rendering at the same rate. Structural classification is shared. Core chooses no UI
queue. Dismissal flushes pending work; Stop rejects late callbacks.

Schema 2 uses tolerant notice decoding and checks both primary and backup versions
before adoption. Erasure is serialized with writes, failures block persistence, and
session-only tombstones reject snapshots of deleted threads. Older released readers
lack this protection: downgrades with the same history file are unsupported.

## 7. Testing

Unit tests cover the pure logic listed above, plus the store's crash-safety
behaviours (atomic write, `.bak` recovery, owner-only permissions, read-only handling
of a newer document, and that turning history off deletes the file rather than hiding
it).

`AppDelegate.applicationDidFinishLaunching` is guarded by an `isRunningTests` check, so
the test host does not register global shortcuts, add a status item, or read the real
user's preferences.

Loopback CLI fixtures exercise the real transport: complete research, optional-field
fallback, repeated rejection, premature EOF, malformed/error frames and delta shapes, whole-response
fallback, failed assessment, redirect refusal, and oversized context. GTK native-close
is tested under Xvfb; macOS tests inspect citation link attributes and control runner
callbacks and UI timers to reproduce Stop races without sleeps.

Still requiring a real desktop session: panel
placement over a full-screen app, the activation handoff, multi-display re-summon,
Liquid Glass rendering, the Accessibility selection path, and IME composition in the
composer.

---

## 8. Known limits

- **Search summaries are not articles.** Vervellum reads what the search tool returns,
  which is a paragraph, not the page. The UI says so on every source, and the prompts
  forbid claiming otherwise — but a citation still cannot prove the source supports the
  model's reading of it. Open the sources.
- **One provider each.** The model endpoint is any OpenAI-compatible Chat Completions
  service; search is a Model Context Protocol server. Native Anthropic or Gemini APIs
  need a compatible gateway.
- **No page fetching.** Vervellum never retrieves a source's full text. That is the
  most valuable single addition and the largest open design question — it changes the
  cost profile, the latency, and the injection surface all at once.
- **English-first prompts.** The prompts are written in English and have not been
  tuned for other languages.
- **The Linux window is a window, not a panel.** See §5.6. It also has no Settings
  interface yet: configuration is a JSON file plus the keyring or two environment
  variables.
- **Linux keys are weaker than a Keychain** whenever no keyring is running. The app
  says which tier it is on rather than implying otherwise.
- **Redaction cannot see shapeless secrets.** See §4.3.

Current consolidation decisions and remaining verification limits:
[PR-REVIEW.md](PR-REVIEW.md). Earlier proposals remain in [ANALYSIS.md](ANALYSIS.md).

## 9. Backlog

1. **A signed, notarized release and an authenticated update chain.** Everything in
   §4.4 follows from not having one, including the Accessibility grant being reset by
   every update, and the updater verifying only an asset's size.
2. Fetch and quote the full text of a small number of decisive sources, with the
   injection surface treated explicitly.
3. A Settings interface for Linux, so the JSON file is not the only way to configure it.
4. Per-turn model override, so a cheap model can plan and a strong one can assess.
5. Export a thread as markdown with its sources.
6. A "watch this question" mode that re-runs a thread and reports what changed.
7. Local-model presets (Ollama, llama.cpp) with sensible endpoint defaults.
