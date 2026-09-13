# Vervellum Privacy Policy

Effective September 5, 2026

Vervellum does not operate an account or analytics service, and it does not sell
personal data. It contains no advertising, telemetry, or tracking. There is no
Vervellum server: the app talks only to the endpoints you configure and to GitHub.

## What leaves this Mac

Vervellum makes network requests in exactly five cases, each with a fixed purpose.

- **Research.** Requested research sends your question, earlier thread context, and
  retrieved evidence to the model provider selected when you asked. The **No search**
  level (`/no-search`, formerly `/direct`) uses that same provider without searching. Provider handling is governed by its own policy;
  Vervellum cannot recall what was sent.

  If that provider fails — no response, a rejected key, an error — the same material is
  sent to the next model provider you have configured, and so on down the list, until
  one answers. Two failures are the exception and reach nobody else: a question you
  stopped, and one too large for Vervellum's own size limit. The second is measured
  before anything leaves the machine and the limit is the same whichever provider is
  next, so there is no second attempt to make. That is **Try the next provider if one fails** in Settings ▸ Providers;
  it is on by default and only ever reaches providers you configured yourself. Turn it
  off and a failing provider fails the question instead. When it happens the turn says
  so, and the model recorded on the turn is the one that actually answered. A question
  you cancel is never re-sent.
- **Search queries.** Model-written queries derived from your question and context go
  to the search provider selected when you asked — an MCP server, a SearXNG instance
  queried directly, or the `kagi` command-line tool on this machine — and to no other
  configured provider. They are shown to you in the panel's process trail before the
  answer arrives. With **Kagi CLI** selected the query reaches Kagi through that tool,
  under the credential you gave it with `kagi auth` rather than one held here, so the
  search is attributed to your Kagi account exactly as a search you typed there would
  be. Vervellum runs the program, and normally never sees the credential — unless you
  store a key against this provider yourself, in which case it is handed to the command
  as `KAGI_API_KEY` and nothing else changes.
- **Reading pages.** Only while page reading is on, and only for two kinds of address:
  one a search just returned, and one you pasted into the question yourself. A link in
  your question is read *before* the searches are planned, so the plan can account for
  what that page says; the page then becomes one of the turn's numbered sources.
  **Fetch pages directly** (Settings ▸ Providers) sends a plain `GET` from this Mac to
  each of those sites, so their text can be read rather than only their search snippet
  — the one case in which Vervellum contacts a host you did not configure. Pasting a
  link is a request to contact that host, but it does not override the setting: with
  page reading off, a link in a question is left unread and the turn says so. Those requests carry no key and no cookie: the app refuses cookies
  entirely, and a redirect is followed by starting a fresh request at the new address
  rather than re-sending anything, at most twice. The sites learn your IP address and
  which page was asked for, as any browser visit would. A link to your own network — a
  loopback address, or a machine on your LAN — is fetched like any other, deliberately,
  so that a self-hosted wiki or a local documentation server can be researched, but only
  when *you* typed the address: a search result that names one is left unread, and a page
  that redirects to one ends the read there. A search result under a *hostname* that
  resolves into your network is not caught — see the limitation recorded in
  `SECURITY.md`. That page's text then travels the same road as
  any source: into the evidence, and on to your model provider. Do not paste a link to
  something you would not send them. **Use a reader service** sends
  the addresses to the reader endpoint you configured instead, with that endpoint's
  key — the sites then see the service rather than you, and the service sees the
  addresses. **Snippets only** fetches nothing at all.
- **Attachments.** An image or file you attach to a question goes to your model provider
  with that question — an image inline in the request as a `data:` URL, a text file as
  text in the payload. Nothing is uploaded anywhere else to make a link for it. It is
  sent **only on the turn you attached it to**: later questions in the same thread carry
  the file's *name* so the model knows something was attached, and nothing more, so a
  follow-up never re-bills you for a picture you sent once. The bytes are kept beside
  your threads in `attachments/` — a `0700` directory, the files inside it `0600` — and
  deleted once no thread refers to them any more, which also means an attachment you
  attached moments ago is never swept out from under you. An image is sent to the
  provider you ask with, unless you untick **Send attached images** for it; a provider
  that refuses the picture is retried without it, and the turn says so.
- **Listing a provider's models.** Only when you press the refresh button beside a
  model field in Settings ▸ Providers. It sends `GET <endpoint>/models` to that one
  provider, with that provider's key, and nothing else — no question, no thread, no
  context. Nothing is fetched when Settings merely opens, and no other provider is
  contacted. The reply is a list of model names, used to fill the picker; the field
  stays typeable whether it succeeds or not.
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
