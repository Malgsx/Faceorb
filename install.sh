#!/usr/bin/env bash
# Installs or updates FaceOrb: fetches the source, builds it on this Mac, and puts FaceOrb.app in
# ~/Applications. Run it again any time to update.
#   curl -fsSL https://raw.githubusercontent.com/Malgsx/Faceorb/main/install.sh | bash
# Optional: FACEORB_SRC (where the source lives, default ~/.faceorb), FACEORB_REPO, FACEORB_BRANCH.
set -euo pipefail

REPO="${FACEORB_REPO:-https://github.com/Malgsx/Faceorb.git}"
BRANCH="${FACEORB_BRANCH:-main}"
SRC="${FACEORB_SRC:-$HOME/.faceorb}"
DEST="$HOME/Applications/FaceOrb.app"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'FaceOrb install: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "FaceOrb is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || die "FaceOrb needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))."

# Swift and git come with Apple's Command Line Tools (full Xcode works too).
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  die "Apple's Command Line Tools are needed to build FaceOrb. Finish the installer that just opened, then run this again."
fi

if [[ -d "$SRC/.git" ]]; then
  say "Updating the source in $SRC"
  git -C "$SRC" fetch --depth 1 origin "$BRANCH"
  git -C "$SRC" reset --hard FETCH_HEAD
else
  [[ -e "$SRC" ]] && die "$SRC exists but isn't a FaceOrb checkout. Move it away or set FACEORB_SRC."
  say "Downloading the source to $SRC"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
fi

say "Building (the first build takes a few minutes and uses about 2 GB of build cache)"
"$SRC/scripts/build-app.sh"

if pgrep -x FaceOrb >/dev/null; then
  say "Quitting the running FaceOrb"
  osascript -e 'quit app "FaceOrb"' >/dev/null 2>&1 || true
  for _ in $(seq 50); do pgrep -x FaceOrb >/dev/null || break; sleep 0.2; done
  pkill -x FaceOrb 2>/dev/null || true
fi

say "Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC/build/FaceOrb.app" "$DEST"

# A `faceorb` terminal command that opens the menu bar dropdown (starting the app if needed).
ALIAS="alias faceorb='open \"\$HOME/Applications/FaceOrb.app\" --args --show'"
case "${SHELL:-}" in
  */bash) RC="$HOME/.bash_profile" ;;
  *) RC="$HOME/.zshrc" ;;
esac
if ! grep -qs "alias faceorb=" "$RC"; then
  printf '\n# FaceOrb: open the menu bar dropdown\n%s\n' "$ALIAS" >> "$RC"
  say "Added the 'faceorb' command to $RC (open a new terminal to use it)"
fi

open "$DEST" --args --show
say "Done. FaceOrb is in your menu bar (the chrome orb). Run this installer again to update."
