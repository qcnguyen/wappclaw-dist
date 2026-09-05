#!/usr/bin/env bash
# Wappclaw installer.
#
#   curl -fsSL https://raw.githubusercontent.com/qcnguyen/wappclaw-dist/main/install.sh | bash
#   curl -fsSL <same-url> | WAPP_CHANNEL=dev bash   # newest dev build instead
#   ./install.sh                                    # unpacked release, no download
#
# Note the placement: the variable belongs on `bash`, not on `curl`. Putting it
# before curl sets it in curl's environment and the installer never sees it.
#
# Installs into your HOME. It never uses sudo, never writes outside these two
# directories, and never installs system packages — if something is missing it
# tells you the command to run.
#
#   ~/.local/share/wappclaw/    the release, its dependencies, instance data
#   ~/.config/wappclaw/         license key and per-instance config
#   ~/.local/bin/wapp           the CLI
#
# If ~/.local/bin is not already on your PATH, one line is appended to your
# shell profile so `wapp` works in new terminals. Opt out with
# WAPP_NO_MODIFY_PATH=1.
set -euo pipefail

WAPP_HOME="${WAPP_HOME:-$HOME/.local/share/wappclaw}"
WAPP_CONFIG="${WAPP_CONFIG:-$HOME/.config/wappclaw}"
BIN_DIR="${WAPP_BIN_DIR:-$HOME/.local/bin}"
# Where a networked install pulls from.
#   DIST_REPO   the public artifact repo (no source in it, ever)
#   WAPP_CHANNEL  stable (default) or dev
# Channel resolution reads a tiny text file rather than the GitHub API: no JSON
# parsing in bash, and no unauthenticated rate limit to trip over.
DIST_REPO="${WAPP_DIST_REPO:-qcnguyen/wappclaw-dist}"
CHANNEL="${WAPP_CHANNEL:-stable}"
BASE_URL="${WAPP_BASE_URL:-https://raw.githubusercontent.com/$DIST_REPO/main}"
ASSET_URL="${WAPP_ASSET_URL:-https://github.com/$DIST_REPO/releases/download}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SRC=""
# Running from inside an unpacked release? Then install that, no download.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/server.mjs" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

bold "Wappclaw installer"

# --- requirements: checked, never installed --------------------------------

pkg_hint() {
  if have apt-get;  then echo "sudo apt-get install -y $*"
  elif have dnf;    then echo "sudo dnf install -y $*"
  elif have apk;    then echo "sudo apk add $*"
  elif have pacman; then echo "sudo pacman -S $*"
  else echo "install: $*"
  fi
}

missing=()
if have node && [ "$(printf '22.13.0\n%s\n' "$(node -v | tr -d v)" | sort -V | head -1)" = "22.13.0" ]; then
  info "node    $(node -v)"
else
  missing+=("node — need >= 22.13, found $(have node && node -v || echo 'nothing'). https://nodejs.org/en/download")
fi
for c in npm git lsof tar; do
  have "$c" && info "$(printf '%-7s present' "$c")" || missing+=("$c — $(pkg_hint "$c")")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo; printf '\033[31mMissing requirements:\033[0m\n' >&2
  for m in "${missing[@]}"; do printf '  %s\n' "$m" >&2; done
  echo >&2; die "install the above, then run this again."
fi
have script || warn "'script' (util-linux) missing — Claude sign-in needs it later; $(pkg_hint util-linux)"

# --- fetch (only when not already unpacked) --------------------------------

TMP=""
# `return 0` is load-bearing, not tidiness. Bash exits with the status of the
# last command run in an EXIT trap, so `[ -n "$TMP" ] && rm -rf "$TMP"` makes the
# whole installer exit 1 whenever TMP is empty — which is exactly the unpacked
# release path, where nothing was downloaded. The script printed "Installed."
# and then failed; only CI, which checks the exit code, ever noticed.
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

if [ -z "$SRC" ]; then
  have curl || die "curl is required to download the release."
  TMP="$(mktemp -d)"
  case "$CHANNEL" in
    stable) pointer="latest" ;;
    dev)    pointer="latest-dev" ;;
    *) die "unknown WAPP_CHANNEL '$CHANNEL' (stable|dev)" ;;
  esac
  VERSION="${WAPP_VERSION:-$(curl -fsSL "$BASE_URL/$pointer" 2>/dev/null | tr -d '[:space:]' || true)}"
  if [ -z "$VERSION" ]; then
    # A missing pointer almost always means "that channel has nothing published
    # yet", not "something is broken". Say which, and name the alternative that
    # does exist — otherwise the message sends people looking for a fault.
    other_pointer="latest-dev"; other_channel="dev"
    [ "$CHANNEL" = dev ] && { other_pointer="latest"; other_channel="stable"; }
    other="$(curl -fsSL "$BASE_URL/$other_pointer" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$other" ]; then
      # The variable goes on `bash`, NOT on `curl`. `VAR=x curl … | bash` puts
      # VAR in curl's environment and the script never sees it — which is what
      # the first version of this very message told people to do.
      die "no $CHANNEL release has been published yet.
  The newest $other_channel build is $other. To install it:

      curl -fsSL $BASE_URL/install.sh | WAPP_CHANNEL=$other_channel bash"
    fi
    die "could not determine the latest $CHANNEL version from $BASE_URL/$pointer.
  Nothing is published on either channel yet. Set WAPP_VERSION explicitly, or
  download a release and run its install.sh."
  fi
  bold "Downloading wappclaw $VERSION ($CHANNEL)"
  curl -fsSL "$ASSET_URL/v$VERSION/wappclaw-$VERSION.tar.gz" -o "$TMP/release.tar.gz" || die "download failed."
  # Verify before unpacking: an unchecked tarball from the network is arbitrary
  # code, and this script is about to run it.
  if curl -fsSL "$ASSET_URL/v$VERSION/wappclaw-$VERSION.tar.gz.sha256" -o "$TMP/release.sha256" 2>/dev/null; then
    expected="$(cut -d' ' -f1 < "$TMP/release.sha256")"
    actual="$(sha256sum "$TMP/release.tar.gz" | cut -d' ' -f1)"
    [ "$expected" = "$actual" ] || die "checksum mismatch — refusing to install.
  expected $expected
  got      $actual"
    info "checksum verified"
  else
    warn "no published checksum found — cannot verify this download."
  fi
  tar xzf "$TMP/release.tar.gz" -C "$TMP"
  SRC="$(find "$TMP" -maxdepth 1 -name 'wappclaw-*' -type d | head -1)"
  [ -n "$SRC" ] || die "the downloaded archive did not contain a release."
fi

VERSION="$(head -1 "$SRC/VERSION")"

# --- install ---------------------------------------------------------------

bold "Installing $VERSION"
DEST="$WAPP_HOME/releases/$VERSION"
mkdir -p "$DEST" "$WAPP_CONFIG" "$BIN_DIR"
# Keep node_modules across an upgrade of the same version so a re-run is quick.
find "$DEST" -maxdepth 1 -mindepth 1 ! -name node_modules -exec rm -rf {} +
for item in server.mjs serve-spa.mjs license-check.mjs chat admin package.json VERSION wapp install.sh; do
  [ -e "$SRC/$item" ] && cp -r "$SRC/$item" "$DEST/"
done
ln -sfn "$DEST" "$WAPP_HOME/current"
info "release  $DEST"

bold "Installing runtime dependencies (~550 MB, mostly the bundled Claude binary)"
( cd "$DEST" && npm install --omit=dev --no-audit --no-fund )

# The CLI is a tiny shim rather than a copy, so `wapp` always runs the version
# `current` points at and an upgrade needs no second step.
cat > "$BIN_DIR/wapp" <<EOF
#!/usr/bin/env bash
# Baked in at install time: without these, the CLI falls back to the default
# ~/.local/share/wappclaw and cannot find an installation made anywhere else
# (an /opt deployment, a service account, a second instance for testing).
# Still overridable, so one shim can drive an alternate tree when asked.
export WAPP_HOME="\${WAPP_HOME:-$WAPP_HOME}"
export WAPP_CONFIG="\${WAPP_CONFIG:-$WAPP_CONFIG}"
exec "\$WAPP_HOME/current/wapp" "\$@"
EOF
chmod +x "$BIN_DIR/wapp"
info "cli      $BIN_DIR/wapp"

# Is the CLI actually reachable? This decides what the closing instructions can
# tell you to type. It used to warn about PATH *before* printing "Next: wapp
# license set …", so the warning scrolled past and the very next instruction was
# a command the shell could not find.
ON_PATH=0
case ":$PATH:" in
  *":$BIN_DIR:"*) ON_PATH=1 ;;
esac

# Which file a login shell would read. Only used to tell you where to put the
# line — nothing is edited unless you ask for it with WAPP_MODIFY_PATH=1.
profile_file() {
  case "${SHELL:-}" in
    *zsh)  echo "$HOME/.zshrc" ;;
    *fish) echo "$HOME/.config/fish/config.fish" ;;
    *)     [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" || echo "$HOME/.profile" ;;
  esac
}

# Put the CLI on PATH by default. This is the user's own shell profile in their
# own HOME — no privileges, one line, trivially reversible — which is a very
# different thing from installing system packages behind sudo, and it is what
# rustup, bun, nvm and uv all do. The alternative is that every single customer
# finishes a successful install with `wapp: command not found`.
# Opt out with WAPP_NO_MODIFY_PATH=1.
PATH_ADDED_TO=""
if [ "$ON_PATH" = 0 ] && [ "${WAPP_NO_MODIFY_PATH:-0}" != 1 ]; then
  rc="$(profile_file)"
  # Idempotent: re-running the installer, or upgrading, must not stack up
  # duplicate PATH entries.
  if grep -qs "$BIN_DIR" "$rc" 2>/dev/null; then
    PATH_ADDED_TO="$rc"
  elif touch "$rc" 2>/dev/null; then
    {
      printf '\n# added by the wappclaw installer\n'
      printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    } >> "$rc"
    PATH_ADDED_TO="$rc"
  else
    warn "could not write to $rc — add $BIN_DIR to your PATH by hand."
  fi
fi

echo
bold "Installed."

if [ "$ON_PATH" = 1 ]; then
  WAPP=wapp
elif [ -n "$PATH_ADDED_TO" ]; then
  # It is on PATH for every new shell, but this script cannot change the
  # environment of the shell that invoked it — no process can. So the next
  # steps use the full path, which works right now, and say how to get the
  # short name in this shell too.
  WAPP="$BIN_DIR/wapp"
  # printf, not the heredoc: a heredoc emits \033 literally rather than as an
  # escape, so the notice printed raw characters instead of colouring.
  printf '\n\033[33m  Added %s to your PATH in %s.\033[0m\n' "$BIN_DIR" "$PATH_ADDED_TO"
  cat <<EOF

  New terminals will find \`wapp\` automatically. For THIS one, either run:

      export PATH="$BIN_DIR:\$PATH"

  or use the full path below.
EOF
else
  WAPP="$BIN_DIR/wapp"
  rc="$(profile_file)"
  printf '\n\033[33m  wapp is installed but %s is not on your PATH.\033[0m\n' "$BIN_DIR"
  cat <<EOF

  For this shell:

      export PATH="$BIN_DIR:\$PATH"

  To make it permanent:

      echo 'export PATH="$BIN_DIR:\$PATH"' >> $rc
EOF
fi

cat <<EOF

  Next:

    $WAPP license set <your-key>     install your license
    $WAPP start                      start it (chat :5173, admin :5174)

  Then open the chat at http://localhost:5173 and sign Claude in from the
  admin app, or run: $WAPP login

  Other commands: $WAPP status | stop | logs | config list | doctor
EOF
