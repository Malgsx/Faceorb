<p align="center">
  <img src="assets/faceorb-orb.svg" width="160" alt="FaceOrb logo">
</p>

# FaceOrb

FaceOrb is a macOS menu bar app that finds the photos you're in. Point it at a photo album (a
link or a folder on your Mac), show it which face is yours, and it sorts the album into your
photos, photos to review, and everyone else. Then you can save your photos to a
folder.

Photo processing runs on your Mac. No FaceOrb account or cloud recognition service is needed.
Optional phone access can use third-party private networking, such as Tailscale.

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

### Use it on your iPhone

The phone-access preview lives on the **mobile** branch, separate from main. To install or update
that version on your Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/Malgsx/Faceorb/mobile/install.sh | FACEORB_BRANCH=mobile bash
```

This uses the same build/install process. It does **not** enable networking or install Tailscale.
Repeat this command to stay on mobile; the ordinary install command above installs main.

1. Open FaceOrb on your Mac and click **Phone** (also available in **Privacy → Phone setup…**).
2. Choose **Tailscale (recommended)** or **My own HTTPS proxy**.
3. Configure the private connection as described below, paste its HTTPS address, and click
   **Enable phone access**. The address must be the site root, not a link containing a path or key.
4. FaceOrb tests the HTTPS connection from your Mac. When it succeeds, click **Show pairing code**.
   Scan the QR code with your iPhone Camera and open it in Safari, or privately send yourself the
   **Copy private phone link** link.
5. In Safari, **Share → Add to Home Screen** creates a shortcut. **Save selected** uses the
   destinations offered by your device, with download links as a fallback.

Your Mac must remain awake, FaceOrb must stay running, and the phone must be on the configured
private network. This is a browser interface backed by your Mac, not an independent iOS app.
Using the Mac's LAN IP or `127.0.0.1` directly on a physical phone will not work.

#### Option A: Tailscale private HTTPS

Install [Tailscale](https://tailscale.com/download) on the Mac and iPhone, sign both into the same
private network, and connect them. Tailscale requires its own account; FaceOrb does not.
Copy the command shown in **Phone setup** and run it in Terminal on the Mac. For the usual port:

```sh
tailscale serve --bg http://127.0.0.1:47615
```

The setup window uses the actual FaceOrb port and detects common macOS CLI locations. If
`tailscale` isn't on your PATH, the app's command can use
`"/Applications/Tailscale.app/Contents/MacOS/Tailscale"` instead.

Approve HTTPS in Tailscale if prompted. Paste the printed `https://your-mac.your-tailnet.ts.net`
address into FaceOrb. Keep Tailscale connected on the phone before opening the private link.
Tailscale supplies a **publicly trusted HTTPS certificate**: you do not install certificates or
approve macOS Certificate Trust Settings. The app and curl installer do not create or trust
certificates, and they never bypass TLS verification. Tailscale's own installation may ask for
ordinary VPN/network permission; enabling HTTPS is done in Tailscale, not Keychain Access.
Use [Serve](https://tailscale.com/kb/1312/serve), **not Funnel**: Serve is tailnet-private, while
Funnel publishes a service to the internet. FaceOrb rejects Tailscale Funnel requests.

Check `tailscale serve status` before changing an existing Serve setup. If another app uses its
default HTTPS port, use a dedicated port (for example `tailscale serve --bg --https=8443
http://127.0.0.1:47615`) and register the HTTPS address with that port. Do not overwrite someone
else's proxy configuration.

HTTPS certificate issuance publishes the certificate hostname in public certificate-transparency
logs, **not** the photo library. Avoid sensitive machine names; see
[Tailscale's HTTPS notes](https://tailscale.com/kb/1153/enabling-https).

#### Option B: Your own private HTTPS proxy

Advanced users can run an HTTPS reverse proxy **on the same Mac**, reachable through a private VPN
or trusted LAN. Supply a certificate **already trusted** by both the Mac and iPhone—this option
is for an existing, correctly configured HTTPS endpoint. Do not bypass certificate warnings or
install a test certificate for FaceOrb. If the certificate isn't already trusted, use Tailscale
or fix the proxy to use a publicly trusted certificate. Forward the site root `/` to the loopback
backend shown in **Phone setup**.

- Preserve the original `Host` header, including any nondefault HTTPS port.
- Set `X-Forwarded-Proto: https` only after TLS termination; strip untrusted incoming forwarding
  headers. FaceOrb does not trust forwarded host headers or auto-discover remote origins.
- Register exactly that HTTPS origin in FaceOrb. Subpath hosting is not supported.
- Keep it private. Do not add router port forwarding or a public tunnel.

HTTPS is important for Safari's file-sharing features as well as protecting photos and credentials.
FaceOrb itself continues to listen only on loopback; it does not provide a plaintext LAN mode.

#### Revoke phone access

**Disable phone access** immediately blocks new phone requests and removes the phone key.
**Replace phone link…** revokes existing links and phone browser sessions without disrupting the
Mac's Browser link. Each device then needs the new QR code. Pairing gives full library access,
including destructive actions, so only share the code/link with your own trusted devices.

Disabling access does not erase photos already saved to a device or stop the external proxy.
For the default Tailscale setup, use `tailscale serve off`; for a dedicated port, use
`tailscale serve --https=8443 off`. Verify with `tailscale serve status`. These commands change
Tailscale configuration, so only disable the listener you set up for FaceOrb.

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

- Photos are only downloaded from the link you paste. No photos or face signatures are sent to a
  cloud recognition service. Optional phone access sends requested previews and photo files to
  your device through the private HTTPS connection you configured.
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
