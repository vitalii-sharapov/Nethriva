# Bundled console dependency provenance

The JavaScript library sources below are unmodified upstream files. Nethriva's native transport adapter and UI integration live separately in console.js and the Swift services.

| Component | Revision | Upstream | License files included |
|---|---|---|---|
| noVNC v1.7.0 | 63107bd06d9e1f6136ff21aeda8cd62cbf0d433e | https://github.com/novnc/noVNC | noVNC/LICENSE.txt, noVNC/docs/LICENSE*, source/vendor headers |
| SPICE HTML5 | 85262d0a4f9c0d9996575e0afa57d680fcf5bd6f | https://gitlab.freedesktop.org/spice/spice-html5 | spice/COPYING, spice/COPYING.LESSER, source headers |

Only the console modules, their supporting vendor modules, and notices are bundled; no upstream Git history, package installation, analytics, or external CDN is used. Compatible modified modules can be substituted in this directory for a local build. Consult THIRD_PARTY_NOTICES.md in the source repository for redistribution notes.

`dependencies.lock.json` records verified source-archive SHA-256 values, exact commits and every bundled dependency-file hash. The build preflight checks upstream versions/revisions and validates these files; the wrapper remains separate and upstream files are unmodified.
