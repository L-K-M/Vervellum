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
- **A redirect cannot cross into private address space.** A chain that started on a
  public address must stay on one. A hop to loopback, link-local, an RFC 1918 block or
  carrier NAT ends the read, in IPv4 and in IPv6 alike — `::1`, `fc00::/7`, and
  `fe80::/9`, which is link-local plus the deprecated site-local block above it,
  and the forms that carry an IPv4 address inside them (`::ffff:192.168.1.1`, 6to4,
  NAT64) are decided by what they actually name. So do the reserved local names
  (`localhost`, `.local`, `.localdomain`), and so does any host that cannot be read as
  either an ordinary name or a provably public literal: `http://2130706433/` and
  `http://0x7f.0.0.0x1/` are `127.0.0.1` to a resolver, and `http://012.0.0.1/` is
  `10.0.0.1` — a leading zero is octal there and decimal to most parsers. The rule is
  "not provably public" rather than a list of the spellings anyone has thought of yet.
- **What that check cannot see.** It reads the address the URL *states*, not the address
  the connection reaches, so a *hostname* that resolves into private space still passes:
  the name is resolved inside `URLSession`, where the answer is neither visible here nor
  bindable to the socket that follows. Closing it means resolving the host first,
  checking every address that comes back, and connecting to the checked address with the
  original `Host` — a custom connection path, which is not built here. Until it is, this
  boundary stops addresses, not names.
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
  to an internal admin page discloses that page's contents to them. And the licence is
  yours alone: **an address you did not type never reaches private space.** A search
  result that names one is left unread with its snippet, and a page that answers a
  redirect with one ends the read, so no page that wins a search slot can turn Vervellum
  into a probe of your network by naming it. That sentence is deliberately about an
  *address*: a **hostname** that resolves into private space is not caught, which is the
  gap described three bullets up — nothing here sees what a name resolved to. If any of
  this matters for how you run Vervellum, set **Reading the page** to
  *Snippets only*: nothing is fetched at all, and a question that carried a link says so
  in a notice rather than having it read for you.

### Running a search command

One search provider is not a server. Selecting **Kagi CLI** makes Vervellum run the
`kagi` program on this machine for each search, because Kagi sells its Search API
separately and the tool is how its subscribers already reach the index from a terminal.
That is the only place Vervellum executes anything, and the query it carries is written
by a *model* which, in deep research, has read pages an earlier search returned. So the
rules are about the argument vector:

- **There is no shell.** `CommandRunner` is given an executable and an array of
  arguments, which reach the child as separate strings. No code path in Vervellum builds
  a command *string*, so a semicolon, a backtick or a `$(…)` in a query is text.
- **The query is passed after `--`**, where every argument parser stops reading flags.
  A query that begins with a dash is a query, not an option — `--follow`, which would
  make the tool fetch pages outside every rule above, is not reachable from one.
- **Every other model-written value is checked against a fixed set** before it becomes
  an argument. A recency window must be one Kagi defines; a region must be two letters.
  A value that is neither is dropped and the search still runs. This check lives in the
  client, not in the schema: an `enum` in a JSON Schema describes what a model *should*
  write, and the shared argument validation checks names rather than values.
- **The child gets a built environment, not this one.** Exactly `PATH`, `HOME`,
  `XDG_CONFIG_HOME`, `LANG`, `TMPDIR`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`,
  `NO_PROXY` and their lowercase spellings, and `KAGI_SESSION_TOKEN`, `KAGI_API_KEY`,
  `KAGI_API_TOKEN` — nothing else. A third-party binary is not handed the model key or
  the reader key. (The proxy variables are listed so that a search behind a corporate
  proxy works the way the same command works in your terminal.)
- **Bounded, and the command is not left running.** Standard output is capped, and going
  over it fails the search rather than parsing a truncated document. On a timeout the
  command is asked to stop with `SIGTERM`, which a program may catch; two seconds later
  it is killed with `SIGKILL`, which it cannot. The search ends with an error either way.
  Standard error is attached to the null device and never read, so a diagnostic that
  echoes a credential cannot reach a log line or the panel; a failure is reported as an
  exit status and nothing more, and the same holds for output that could not be parsed.

The credential belongs to the tool. `kagi auth` stores it where the user's own terminal
already reads it, and Vervellum neither asks for it nor keeps a copy — a key stored in
Vervellum anyway is passed to the child as `KAGI_API_KEY`. Which program runs is the
command in the provider settings: a bare name is resolved against `PATH` **first** and
then against the directories CLIs install into (`/opt/homebrew/bin`, `/usr/local/bin`,
`/home/linuxbrew/.linuxbrew/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`,
`/usr/bin`, `/bin`), because a menu-bar agent's `PATH` contains none of them. An
absolute path is taken as written, and is the way to be certain which program runs. A
relative path is refused rather than resolved against a working directory the app did
not choose.

Setting **Reading the page** to *Use a reader service* moves the fetch to an MCP reader
endpoint; setting it to *Snippets only* is the behaviour of every build before this one.
Either way, a source that was read says so in the panel and in a copied transcript, and
a page that was fetched but did not fit the model's context is listed as a summary —
because that is what the answer actually had.

### Attachments

An image or file the user attaches is content Vervellum did not fetch and cannot
vouch for, and it is handled on those terms:

- **The type comes from the bytes.** A dropped file's name is the one part of it that
  carries no evidence about what it is, so the media type announced to the provider is
  sniffed from the file's own signature. A `.png` whose bytes are text is attached as
  text.
- **An attached file's text is untrusted data**, exactly like a page Vervellum read. It
  reaches the model inside the same payload as the question, under the same system
  prompt, and cannot become a citation — it has no source number, and the answer prompt
  says so in as many words rather than leaving the model to invent one.
- **Sent inline, never uploaded.** An image travels as a `data:` URL in the request body.
  The alternative — putting the user's screenshot somewhere public to get a link for it
  — is the opposite of what the rest of this document promises.
- **Sent once.** An attachment goes with the turn it was attached to and no other. Later
  turns in the thread carry its name only.
- **Bounded.** Images are capped at 4 MB and refused above it rather than silently
  scaled; an attached file contributes a bounded amount of text, truncated with a
  visible marker so the model is never handed a fragment presented as a whole file.
- **The file name is sanitised** before it is shown or put in the payload: control and
  format characters out — which covers the bidi overrides and zero-width marks that make
  one name render as another — and path separators too. Nothing builds a path from it —
  the store keys by the attachment's id — and keeping it that way is easier than proving
  it is safe.
- **A provider is shown images only if you said it can.** There is no way to ask an
  OpenAI-compatible endpoint whether it has eyes, and guessing wrong fails the turn
  outright, so it is a per-provider setting that is off until set. The filter is applied
  where the request is built rather than by each caller, so a provider you did not tick
  cannot be sent a picture by a code path that forgot.
- **An attachment that could not be sent says so.** Bytes that have gone missing, or text
  that no longer decodes, raise a notice on the turn rather than leaving an answer that
  ignores a file for no visible reason.

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
