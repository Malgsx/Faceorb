# FaceOrb

FaceOrb is a macOS menu bar app that finds the photos you're in. Point it at a photo album (a
link or a folder on your Mac), show it which face is yours, and it sorts the album into your
photos, photos to review, and everyone else. Then you can save your photos to a
folder.

Everything runs on your Mac. No accounts, no cloud services.

## Requirements

- macOS 14 Sonoma or newer
- Apple's Command Line Tools (the installer will ask to install them if they're missing)

## Install

Open Terminal and run:

```sh
curl -fsSL https://raw.githubusercontent.com/Malgsx/Faceorb/main/install.sh | bash
```

The installer:

1. Downloads the source code to `~/.faceorb`.
2. Downloads the face recognition model (37 MB, checked against a known hash).
3. Builds FaceOrb on your Mac. The first build takes a few minutes.
4. Installs it to `~/Applications/FaceOrb.app` and starts it.
5. Adds a `faceorb` command to your shell.

If you'd rather read the script before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/Malgsx/Faceorb/main/install.sh -o install.sh
less install.sh
bash install.sh
```

## Use

1. Click the orb in the menu bar, or type `faceorb` in a new Terminal window.
2. Paste a link and click Import, or choose a folder of photos.
3. Wait for the scan to finish, then click "Pick yourself to start sorting" and pick your face.
4. Go through the photos FaceOrb isn't sure about in the Review tab.
5. Use "Save my photos" to copy your photos to a folder.

The Browser button in the dropdown opens the same app in your web browser. It only listens on
your own Mac (127.0.0.1) and needs a private key that the button passes along.

## What you can import

- A link to a web page with photos on it, such as a gallery or event page
- A Pixieset gallery link, including photographers' own gallery domains
- A direct link to a photo, or to a .zip of photos
- A Dropbox share link to a photo, a .zip, or a folder
- A folder on your Mac, with photos from anywhere: a camera, AirDrop, or an album you downloaded

Some sites only show photos after you sign in, or load them in a way FaceOrb can't read
(Google Photos and iCloud shared albums, for example). For those, download the album, then
choose the folder.

## Update

Run the install command again.

## Uninstall

1. In FaceOrb, open Privacy and click "Delete all FaceOrb data" if you want your library removed.
2. Quit FaceOrb.
3. Delete `~/Applications/FaceOrb.app` and the `~/.faceorb` folder.
4. Remove the `faceorb` line from `~/.zshrc` (or `~/.bash_profile`).

## Privacy

- Photos are only downloaded from the link you paste. Nothing is uploaded.
- FaceOrb stores its data in `~/Library/Application Support/FaceOrb/`: the photo list, face
  positions, face signatures, your choices, and downloaded copies of the album.
- Folders you import are read in place and never changed.
- Face signatures are biometric data. You can delete other people's, your own, or everything
  from the Privacy tab.

Only use FaceOrb on photos you have permission to process.

## How it works

- Apple's Vision framework finds faces and their landmarks.
- Each face is aligned and turned into a 128-number signature by the SFace model
  (OpenCV Zoo, Apache-2.0) running in ONNX Runtime.
- Faces are compared with the ones you've confirmed as you. Each yes or no you give improves
  the next match.

## Build from source

```sh
git clone https://github.com/Malgsx/Faceorb.git
cd Faceorb
scripts/build-app.sh --open
```

`swift test` runs the tests (needs Xcode for XCTest). The code is laid out as:

- `Sources/FaceOrbCore`: matching, alignment, import, storage, export
- `Sources/FaceOrbWeb`: the local web app
- `Sources/FaceOrbKit`: face detection and the face model (macOS)
- `Sources/FaceOrb`: the menu bar app
- `Sources/faceorb-sim`: a command line harness for testing without the app

## License

MIT. See [LICENSE](LICENSE).
