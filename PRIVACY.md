# Vervellum Privacy Policy

Effective September 5, 2026

Vervellum does not operate an account or analytics service, and it does not sell
personal data. It contains no advertising, telemetry, or tracking. There is no
Vervellum server: the app talks only to the endpoints you configure and to GitHub.

## What leaves this Mac

Vervellum makes network requests in exactly three cases, each with a fixed purpose.

- **Research.** Requested research sends your question, earlier thread context, and
  retrieved evidence to the model provider selected when you asked — and to no other
  configured provider. `/direct` uses that same provider without searching. Provider
  handling is governed by its own policy; Vervellum cannot recall what was sent.
- **Search queries.** Model-written queries derived from your question and context go
  to the search provider selected when you asked — an MCP server, or a SearXNG instance
  queried directly — and to no other configured provider. They are shown to you in the
  panel's process trail before the answer arrives.
- **Update checks.** Vervellum asks GitHub's public releases API whether a newer version
  exists — on launch and about once a day while automatic checks are enabled (they can
  be turned off in Settings), or when you choose Check for Updates. The request contains
  no system profile or identifiers; the app identifies itself only by its bundle
  identifier. Choosing **Download** saves the release file from GitHub to `~/Downloads`
  and reveals it in the Finder — Vervellum never installs updates automatically.

Like any network request, these services receive ordinary connection metadata such as
your IP address.

## What stays on your machine

- **Threads.** Questions, answers, verdicts and source lists are stored as JSON,
  readable only by your account — in Vervellum's Application Support folder on macOS,
  and under `$XDG_DATA_HOME` (usually `~/.local/share/vervellum`) on Linux. Turning
  history off or choosing "Delete all…" deletes the primary and backup files,
  including when launched with history disabled. Failed deletion is reported and
  blocks further writes until resolved. Active runs are checkpointed while history
  is enabled. Newer history schemas stay untouched at launch; explicit deletion
  still removes them. Deletion cannot remove copies in external backups.
- **Preferences.** Panel position, size, text scale, shortcuts and behaviour toggles
  live in Vervellum's application preferences on macOS, and in
  `~/.config/vervellum/settings.json` on Linux.
- **API keys.** In your login Keychain on macOS, one item per configured provider, so
  one provider's key is never sent to another. On Linux, explicit `VERVELLUM_MODEL_KEY`
  and `VERVELLUM_SEARCH_KEY` override reads for the first model provider and the search
  server, and `VERVELLUM_READER_KEY` for a reader service; otherwise the keyring is
  tried before the mode-0600 file. Writes prefer the keyring, then the file. In every case they are never written to
  preferences, never included as configuration in a stored thread, and never logged.
  Typed or pasted secrets are still ordinary user text; review what you send.

## The selection shortcut (macOS only)

The optional "Research the Selection" shortcut reads the selected text from the app you
were using, through macOS's Accessibility permission. There is no Linux equivalent. It is off by default and reads
the selection only at the moment you press the shortcut — never in the background, and
never anything else the permission would allow.

Before that text reaches the composer, Vervellum removes values that look like
credentials — API keys, tokens, private-key blocks, `KEY=value` lines, URLs with
embedded passwords — and tells you how many it removed. This reduces accidental
disclosure; it cannot catch a secret that looks like ordinary text, so read what you
are about to send. The behaviour can be turned off in Settings ▸ Shortcuts.

Because macOS ties this permission to an app's code signature and released builds are
ad-hoc signed, the grant is reset by every update. Vervellum says so when that happens.

## Logging

Vervellum writes diagnostic lines to the unified system log under its own subsystem:
stage names, durations, counts and sizes, tagged with a short per-run identifier.
Questions, answers, search queries, retrieved content, API keys, provider-controlled
tool names, and provider error text are deliberately excluded. Result diagnostics print only known schema field names and
aggregate counts; arbitrary field names are omitted because they can contain secrets.

## The keyboard shortcut on Linux

Vervellum does not monitor the keyboard. On first launch it asks GNOME to run
`gapplication action ch.lkmc.Vervellum toggle` on a key combination, by writing one custom
keybinding through `gsettings`; the desktop owns the grab and Vervellum only sees the
resulting request. It writes that binding once and never overwrites a shortcut you have
since changed. `vervellum --install-shortcut` re-runs it; the entry is visible and
removable in Settings ▸ Keyboard ▸ Custom Shortcuts.

## Removal

Removing Vervellum and its application data removes the stored threads and preferences —
`~/.config/vervellum` and `~/.local/share/vervellum` on Linux. API keys are removed by
clearing them in Settings ▸ Providers on macOS, by deleting the "Vervellum" items from
Keychain Access, or on Linux with
`secret-tool clear service ch.lkmc.Vervellum account model-api-key`.

Questions can be asked through the project's GitHub repository; please report security
vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
