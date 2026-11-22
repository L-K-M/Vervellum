# Changelog

## Unreleased

- The macOS app's update checks now use the shared Updraft package, like the
  sibling apps. Downloads are verified (HTTPS GitHub hosts including
  redirects, exact size, SHA-256 when the release publishes one) and carry the
  quarantine attribute so Gatekeeper checks them; assets for another OS or of
  an unknown type are no longer offered. A failed download shows an alert
  offering the release page instead of opening it silently. Check for Updates
  during a background check is reported instead of dropped, Skip This Version
  survives a re-tag, the release page opened is always Vervellum's GitHub
  page, and the daily check runs at 90% of the interval so a punctual timer no
  longer skips a day.
- Global shortcuts now use the shared Keycap package. The recorder refuses
  shortcuts macOS reserves (⌘Q, ⌘W, ⌘H, ⌘M, ⌘Space, ⌘Tab, their ⇧ variants and
  ⇧⌘3 to ⇧⌘6) and accepts a bare function key; a refused shortcut saved
  earlier is not registered, and Settings ▸ Shortcuts says so. Escape cancels
  recording even with modifiers held, Space or Return starts recording when
  the recorder has focus, held modifiers show while recording, and the
  recorder shows keypad Enter, function, Help and keypad Clear keys by their
  standard names, and the panel's hint shows the same name, so a shortcut saved
  earlier matches the recorder without being recorded again. The stored label is
  preserved for older builds. The Linux build is unchanged.
- Earlier history lives in the commit log and the GitHub releases.
