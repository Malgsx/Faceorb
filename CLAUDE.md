# FaceOrb: notes for coding agents

macOS 14+ menu bar app (SwiftUI `MenuBarExtra`) that finds the user in a photo album with on-device
face recognition, plus a local web app served by the same process. See README.md for features.

## Layout
- `Sources/FaceOrbCore`: matcher, alignment, Pixieset/folder import, store, export planning, disk checks (cross-platform)
- `Sources/FaceOrbWeb`: loopback HTTP server, JSON API, the web page (cross-platform)
- `Sources/FaceOrbKit`: Apple Vision detection, SFace via ONNX Runtime, ImageIO (macOS)
- `Sources/FaceOrb`: the app (AppModel, dropdown, review window, export sheet, AppBackend for the web app)
- `Sources/faceorb-sim`: headless harness (`swift run faceorb-sim`)

## Build / test
- `scripts/build-app.sh --open` builds `build/FaceOrb.app` (downloads the SFace model once, sha256-checked).
- `swift test` runs the core and web tests (needs Xcode for XCTest).
- `install.sh` is the curl installer: clones to ~/.faceorb, builds, installs to ~/Applications.

## Data
`~/Library/Application Support/FaceOrb/`: `library.json` (photos, face boxes, 128-d signatures,
decisions), `albums/` (downloaded web-size copies), `web-token`. Treat face signatures as biometric
data: don't print, upload or copy them anywhere.
