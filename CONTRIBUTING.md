# Contributing to FaceOrb

Thanks for helping. FaceOrb is a small Swift package, so getting started takes a few minutes.

## Set up your fork

1. Fork [Malgsx/Faceorb](https://github.com/Malgsx/Faceorb) on GitHub.
2. Clone your fork and install it on your Mac:

   ```sh
   git clone https://github.com/<you>/Faceorb.git
   cd Faceorb
   ./install.sh
   ```

   Run from a clone, `install.sh` builds and installs that checkout as it is (no fetching), and
   the app's Update button rebuilds from it whenever it changes. `scripts/build-app.sh --open`
   builds `build/FaceOrb.app` without installing it.
3. Keep your fork current: `git remote add upstream https://github.com/Malgsx/Faceorb.git`, then
   `git pull upstream main`.

You need macOS 14+ and Apple's Command Line Tools (or Xcode). `swift test` needs Xcode for XCTest
on a Mac; on Linux it runs with any Swift 6 toolchain (see `.swift-version`).

## Where things live

- `Sources/FaceOrbCore`: matching, alignment, imports, storage, export (no Apple frameworks)
- `Sources/FaceOrbWeb`: the local web app and phone PWA (no Apple frameworks)
- `Sources/FaceOrbKit`: Apple Vision detection, the SFace model, images (macOS)
- `Sources/FaceOrb`: the menu bar app
- `Sources/faceorb-sim`: a command line harness, e.g. `swift run faceorb-sim link <url>`
- `Tests/FaceOrbCoreTests`: tests for the core and web targets

## Making a change

1. Branch from `main`.
2. Run `swift test`. For app or web changes, also build and try it: `scripts/build-app.sh --open`.
   The web app opens from the dropdown's Browser button; try narrow widths for the phone layout.
3. Open a pull request against `Malgsx/Faceorb:main`. CI builds the app on macOS and runs the
   tests on macOS and Linux.

Add a test when you fix a bug or add behavior other code relies on.

## Privacy rules

Face signatures are biometric data. Don't add code that uploads photos or face data, and don't
commit photos of people or anything from `~/Library/Application Support/FaceOrb/`.
