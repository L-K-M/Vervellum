# Bundled license texts

`packaging/build-deb.sh` builds the Linux binary with `--static-swift-stdlib`, which
links the Swift runtime and Foundation's ICU into it. `components.json` lists them, and
`scripts/deb-copyright.py` turns it into the package's `copyright` and
`Third-Party-Notices.txt`. The Swift license text is read from the toolchain at build
time; the ICU text is kept here because the toolchain does not ship it.

| File | Upstream | SHA-256 |
| --- | --- | --- |
| `ICU-74.1-LICENSE.txt` | unicode-org/icu `LICENSE` at `release-74-1`, the ICU version in `swift-foundation-icu` for Swift 6.0 to 6.2 | `17510cf7a58b4879b887ec05a45d72cf1b73544dd9ec7e72f20110ed104229ee` |

A toolchain whose ICU has another major version fails the build in
`scripts/static-runtime-notices.py`. Swift 6.3 and 6.4 use ICU 76.1: add that
version's `LICENSE` from unicode-org/icu and update `components.json`.
