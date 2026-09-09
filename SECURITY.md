# Security Policy

## Supported versions

Security fixes are provided for the latest released version of Vervellum.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not
include passwords, private keys, or other secrets in a report. If private reporting is
unavailable, open an issue that contains no sensitive details and request a private
contact channel.

## Security boundary

Vervellum sends user text to two third-party endpoints and renders content retrieved
from the open web. Those are the two boundaries, and they are treated separately.

### Credentials

Configured API keys are never written to settings, stored threads, or logs. They are attached as request headers only.

Where they live depends on the platform, and the platforms are **not** equally strong:

| Platform | Store | Protection |
|---|---|---|
| macOS | login Keychain | encrypted at rest, access-controlled per application |
| Linux | login keyring, via `secret-tool` | encrypted at rest, unlocked with the login password |
| Linux | `VERVELLUM_MODEL_KEY` / `VERVELLUM_SEARCH_KEY` | as safe as the environment that sets them |
| Linux | a mode-0600 file in `~/.config/vervellum` | **not encrypted** — readable by anything running as you |

Explicit environment keys override reads on Linux, followed by the keyring and file.
Writes prefer the keyring, then the file; the backend label describes that write path. The bottom tier exists because a keyring fails predictably on
a machine set up for automatic login, on a headless session and in a container, and an
app that refused to start there would be broken for a large minority of users. The file
is created with `O_CREAT`-style restrictive permissions *before* the secret is written
to it, so there is no window in which it is world-readable.

Provider requests use one transport that enforces three rules:

- **Redirects are refused.** `URLSession` re-sends the `Authorization` header to a
  redirect target by default, so a provider — or anything that can answer for its
  hostname — could harvest a key with a single `302`. The delegate blocks every
  redirect, and because a blocked redirect completes *successfully* with the 3xx
  response rather than failing, the status code is checked explicitly and reported.
- **Endpoints must be HTTPS**, with an exception for loopback so a local model server
  works without a certificate. A URL carrying userinfo (`https://key@host/`) is
  rejected, because that form leaks the credential into logs and `Referer` headers.
- **Responses are size-capped**, so a hostile or malfunctioning endpoint cannot stream
  unbounded data into the app.

Provider error text is never shown or logged. Gateway messages have been observed
echoing request data and credentials back, so every underlying error is caught,
discarded, and replaced with a message Vervellum wrote; a foreign error reaches the log
as its type name only.

### Untrusted content

Search results are attacker-controlled in the general case: anyone can put "ignore your
previous instructions" on a web page. Every system prompt opens by declaring retrieved
content and prior thread content to be untrusted data rather than instructions, and
names what such text tends to look like.

Prompting is a mitigation, not a guarantee, which is why the citation rule is
structural rather than instructional: the model is given a **numbered list** of sources
Vervellum itself fetched and may refer to evidence only by number. Both renderers
create actionable answer links only from those citations. Model-written links are
inert; literal URLs are flagged. Invalid numbers remain plain text and are reported.
Shared masking prevents raw placeholder characters from relocating real citations.
These controls establish link provenance, not whether a source supports a claim.

Retrieved text is never executed and never rendered as HTML. It is *read*: with page
reading on — the default — Vervellum fetches up to three of the pages the search
returned and extracts their text, which raises the evidential value of a citation and
adds one thing to reason about, so both are stated here rather than only the first.

Those requests are the only ones Vervellum makes to a host the user did not configure,
and they are built to have nothing worth stealing:

- **No credentials.** No `Authorization` header, no cookies (the shared session neither
  stores nor sends them) and no `Referer`. There is nothing for a hostile host to
  harvest.
- **Redirects are re-issued, not followed.** The transport still refuses every automatic
  redirect; the reader reads the `Location` and starts a *fresh* credential-free request,
  at most twice, and re-validates every hop as an absolute `http(s)` URL. `file:` and
  `data:` targets are rejected at each hop rather than only at the first.
- **Only text, and only some of it.** A non-text content type is skipped on its header
  rather than fetched and discarded, the body is capped, and the extracted text is
  truncated with a visible marker.
- **The page's own text is still untrusted data.** It reaches the model inside the same
  evidence block as a snippet, under the same system prompt, and cannot become a
  citation: Vervellum still owns the numbered list, and the model still refers to
  evidence only by number.
- **A private or loopback address you paste is fetched like any other.** There is no
  block on `127.0.0.1`, `localhost`, `169.254.x` or the RFC 1918 ranges, and that is a
  decision rather than an oversight: a self-hosted wiki, a local documentation server or
  a machine on your own network is a legitimate thing to ask about, and refusing those
  addresses would break the case without making the general one safer. Two things follow
  from it, and neither is hidden. **The page's text leaves your machine** — it becomes
  numbered evidence and is sent to your model provider like any other source, so a link
  to an internal admin page discloses that page's contents to them. And **a search result
  can redirect into private space**, at most twice and re-validated at each hop, which is
  the one path here you did not type yourself. If either matters for how you run
  Vervellum, set **Reading the page** to *Snippets only*: nothing is fetched at all, and
  a question that carried a link says so in a notice rather than having it read for you.

Setting **Reading the page** to *Use a reader service* moves the fetch to an MCP reader
endpoint; setting it to *Snippets only* is the behaviour of every build before this one.
Either way, a source that was read says so in the panel and in a copied transcript, and
a page that was fetched but did not fit the model's context is listed as a summary —
because that is what the answer actually had.

### Captured text

The optional "research the selection" shortcut reads the frontmost app's selection
through the Accessibility API. Before that text reaches the composer it is scanned for
credential-shaped values — vendor-prefixed keys, `Authorization` headers, `KEY=value`
lines, private-key blocks, JSON Web Tokens, URLs with embedded credentials — which are
replaced, with a visible count of how many.

## What is *not* protected

- **Redaction is a safety net, not a guarantee.** A secret with no recognisable shape —
  a dictionary-word password, a customer name, an internal hostname — passes straight
  through. Read what you are about to send.
- **The providers see your questions.** Vervellum has no way to make a remote model
  endpoint or a remote search server forget what was sent to it. Their handling is
  governed by their own policies.
- **A page you read learns you read it.** With direct page reading the site behind a
  search result — or behind a link you pasted into a question, which is read before the
  searches are planned — receives a request from your machine and therefore your IP
  address, plus whatever its own logs record. Nothing identifies Vervellum's user beyond that, but
  "the search provider saw the query" and "the site saw the visit" are different
  disclosures. A reader service moves the visit to the service and shows it the URLs
  instead; *Snippets only* makes neither request.
- **Released builds are not signed or notarized.** CI ad-hoc signs the app so it will
  launch on Apple Silicon; there is no Developer ID signature, no notarization, and the
  Hardened Runtime is not applied to the CI artifact. The in-app updater verifies a
  downloaded asset's size and nothing else — it does **not** verify a signature — and it
  never installs anything: the file is saved to `~/Downloads` and revealed in the
  Finder, with Gatekeeper applying as usual. Establishing a signed, notarized release
  and an authenticated update chain is the top backlog item.
- **An ad-hoc signature changes every build**, so macOS resets the Accessibility grant
  on every update. That is a usability consequence of the point above, not an
  independent issue.
- **The app is not sandboxed.** It cannot be: a sandboxed app can never hold the
  Accessibility permission the selection feature needs.
- **Stored threads are plain JSON.** The file is written `0600` — in Application Support
  on macOS, under `$XDG_DATA_HOME` on Linux — which protects it from other users but not
  from anything running as you. History can be turned off, and turning it off deletes the
  primary and backup files. Failed erasure is reported and blocks further writes
  until erasure succeeds. Session-only deletion markers reject late snapshots;
  deletion is not secure disk erasure and cannot remove external backups.
- **Downgrades are not history-safe.** Schema 2 adds notice values that older releases
  cannot decode. Those releases lack version preflight and can overwrite the file;
  a version bump cannot repair their reader. Back up history before downgrading.
  This build preserves newer primary or backup schemas without adopting either,
  unless you explicitly erase history.
- **The Linux file-backed key store is not encrypted.** See the table above. Install
  `libsecret-tools` and run a keyring, or supply the keys through the environment.
- **The Linux `.deb` is unsigned and unrepositoried.** There is no apt signing key and no
  update channel; the package is downloaded from a GitHub Release and installed by hand.
- **`secret-tool` is invoked as a subprocess.** The secret is written to its standard
  input, never passed as an argument, because arguments are visible in `ps` to every
  process on the machine.
