# CI/CD

Vervellum uses GitHub Actions for builds, releases, and optional review. CI runs on every pull request and on
pushes to `main`; releases are produced by pushing a version tag. Everything works with
**no secrets configured** — the only optional secret is the automated reviewer's key.

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | PRs, pushes to `main`, manual dispatch | Build and test on macOS. |
| `.github/workflows/linux.yml` | PRs, pushes to `main`, manual dispatch | Build, test and package on Ubuntu. |
| `.github/workflows/release.yml` | Pushing a `v*` tag | Build both platforms, publish a GitHub Release with a `.dmg`, a `.zip` and a `.deb`, and verify what was published. |
| `.github/workflows/glm-review.yml` | PRs from this repository | Starts automated review. |
| `.github/workflows/zai-code-review.yml` | Reusable workflow | Implements automated review. |

Every third-party action is pinned to an **immutable commit SHA**, with the version in
a trailing comment. A mutable tag like `@v4` can be repointed at tampered code after
the fact; a commit SHA cannot. `release.yml` holds `contents: write` and produces the
exact bytes the in-app updater offers to every user, so it gets the same discipline.

## Continuous integration (`ci.yml`)

One job on `macos-26` with Xcode pinned to `26.0`:

```bash
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum \
  -destination 'platform=macOS' -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO clean test | xcbeautify
```

Notes on the shape of this job, each of which is there for a reason:

- **`workflow_dispatch` is enabled.** GitHub has throttled webhook delivery during
  Actions incidents, and `pull_request` events stopped starting workflows at all;
  dispatch goes through the API instead. It is also how CI is re-run without an empty
  commit.
- **`permissions: contents: read`.** The job only needs to read the repo; uploading test
  results uses the artifact API, which needs no extra scope.
- **`persist-credentials: false`.** Nothing runs `git` after checkout, so no token is
  left in `.git/config` for the duration of the build.
- **A 30-minute timeout.** A wedged `xcodebuild` is a documented failure mode, and macOS
  runners bill at 10×; without this it would burn six hours.
- **Concurrency cancels PR runs only.** Cancelling a push to `main` would leave that
  commit permanently marked "cancelled", masking breakage and putting holes in
  CI-status bisection.
- **Xcode is pinned**, so a runner-image bump cannot silently change the toolchain.
  Liquid Glass needs Xcode 26.

On failure the `.xcresult` bundle is uploaded as an artifact.

## Linux (`linux.yml`)

One job in the **official Swift container for the target Ubuntu release**, not
`swift-actions/setup-swift` on a bare runner. A `.deb` links against the library
versions present at build time, so the container is what guarantees the package
targets 24.04. The `swift:6.1-noble` image tag is still mutable, not digest-pinned.

The job builds the executable, runs shared tests and loopback provider fixtures,
checks native-close/reopen under Xvfb, validates the desktop entry, and packages
and installs the `.deb`. Loopback tests use Python's standard library, temporary
XDG directories, and fake keys; no external provider or user state is used.

`swift test` here runs the *same files* as the macOS suite, from
`Tests/VervellumKitTests/`. That is the mechanism that stops the two platforms drifting:
a change that breaks one platform's copy of a shared rule fails the other's build.
It is also what enforces the portability rule in `AGENTS.md` — a stray `import AppKit`
in the shared core compiles fine on a Mac and fails here immediately.

## Releases (`release.yml`)

Triggered by pushing a tag matching `v*`. Two jobs: the Linux package is built **first**
and handed to the macOS job as an artifact, so a broken `.deb` fails the tag before a
GitHub Release exists to attach anything to.

`scripts/release.sh` does the bump, commit, tag and (with `--push`) the push:

```bash
scripts/release.sh 1.3.0 --push
```

**The tag is the source of truth** for the released version — CI derives
`MARKETING_VERSION` from `${GITHUB_REF_NAME#v}`. The script only keeps the committed
`MARKETING_VERSION` and the README's version marker in step, so local builds and the
in-app updater report the same number.

The job then:

1. **Runs the tests.** With no signing or notarization downstream, the suite is the only
   automated quality gate; a tag on a broken commit must not publish a release the
   updater immediately offers to everyone.
2. **Builds Release** with `CODE_SIGNING_ALLOWED=NO`.
3. **Ad-hoc signs** (`codesign --sign -`). This is not a Developer ID signature and the
   app is not notarized — it is the minimum required for the app to launch on Apple
   Silicon at all. Gatekeeper still warns. See SECURITY.md for what this costs.
4. **Packages** a `.zip` (via `ditto`) and a `.dmg` (via `create-dmg`). `create-dmg`
   exits non-zero on a headless runner even on success, so the file's existence is
   checked and `hdiutil verify` runs against it — a truncated or corrupt image must not
   ship as the release's preferred asset.
5. **Publishes** the release. A pre-release tag (one containing a hyphen, e.g.
   `v1.1.0-beta.1`) is marked as a prerelease and is *not* made "latest", or the
   updater's `releases/latest` fetch would offer the beta to every stable user and
   silently defeat its own prerelease gate.
6. **Verifies what was published.** All three assets are downloaded back from GitHub and
   byte-compared against what was built. A mismatched asset is deleted from the release
   before the job fails, so the updater cannot keep serving corrupt bytes while someone
   investigates.

### The Debian package

`packaging/build-deb.sh` builds with `--static-swift-stdlib`, which links Swift's runtime
and Foundation into the binary; glibc, GTK and libcurl stay dynamic. The musl Static
Linux SDK is not an option — it forbids `dlopen` entirely, and GTK needs it for GIO
modules, input methods and pixbuf loaders.

Three details that are easy to get wrong and are handled in the script:

- `Depends:` is generated by **`dpkg-shlibdeps` from the built ELF**, never hand-written.
  Ubuntu 24.04's 64-bit `time_t` transition renamed `libglib2.0-0` to `libglib2.0-0t64`
  and `libcurl4` to `libcurl4t64`, so a line copied from a 22.04 example produces an
  uninstallable package with no build-time error.
- `dpkg-deb --root-owner-group`, or every file is owned by the building user's uid.
- A version with no Debian revision makes this a *native* package, which requires
  `changelog.gz` rather than `changelog.Debian.gz`.

## Automated review (`zai-code-review.yml`)

Runs on `pull_request_target`, which exposes repository secrets and a write-capable
token. That is why the job is gated on
`github.event.pull_request.head.repo.full_name == github.repository`: **it must never
run for a branch from an untrusted fork.** That condition is a security control, not
boilerplate. Without `ZAI_API_KEY`, the workflow reports success but performs no
review. That is reviewer unavailability, not approval.

`CLAUDE.md` describes how to work with the review rounds this produces, including when
to declare steady state and stop.

## Running the checks locally

```bash
# macOS
xcodebuild -project Vervellum.xcodeproj -scheme Vervellum \
  -destination 'platform=macOS' clean test

# Linux
swift build -c release --product vervellum
swift test --parallel
python3 Tests/Integration/provider_fixtures.py .build/release/vervellum
xvfb-run --auto-servernum swift test --skip-build --filter LinuxPanelLifecycleTests
packaging/build-deb.sh 0.1.0
```

`scripts/build.sh` and `scripts/release.sh` are thin stubs over the shared `lkm-build`
and `lkm-release` engines from
[`release-tool`](https://github.com/L-K-M/release-tool). They only export
`BUILD_*` / `RELEASE_*` configuration; no release logic belongs in them.
