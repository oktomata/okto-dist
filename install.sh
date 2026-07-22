#!/usr/bin/env sh
# Okto CLI installer (macOS + Linux).
#
# Downloads the `okto` binary from a GitHub release, verifies its
# sha256, and places it on PATH. POSIX sh — no bashisms.
#
# Usage:
#   curl -fsSL https://oktomata.com/install | sh
#   curl -fsSL https://oktomata.com/install | sh -s -- --version 0.1.0
#   curl -fsSL https://oktomata.com/install | sh -s -- --install-dir ~/bin
#
# Env vars:
#   OKTO_INSTALL_DIR    override the install directory
#   OKTO_REPO           download repo (default: oktomata/okto-dist, the
#                       PUBLIC release mirror — the source repo is private)
#   OKTO_SIGN_REPO      repo whose signing-workflow identity the cosign
#                       signature must match (default: oktomata/okto-dist).
#                       Signing runs in the mirror's sign-release.yml,
#                       dispatched against the release tag, decoupled from
#                       the source build repo.
#   OKTO_VERSION        same as --version
#
# Exit codes:
#   0  success
#   1  user-level failure (unknown OS, missing tools, sha256 mismatch)
#   2  network / release-lookup failure

set -eu

REPO="${OKTO_REPO:-oktomata/okto-dist}"
SIGN_REPO="${OKTO_SIGN_REPO:-oktomata/okto-dist}"
VERSION="${OKTO_VERSION:-}"
INSTALL_DIR="${OKTO_INSTALL_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#--install-dir=}"; shift ;;
    -h|--help)
      cat <<EOF
Okto CLI installer

  --version <X.Y.Z>     install a specific version (default: latest v* release)
  --install-dir <dir>   override install dir (default: ~/.local/bin)

Env: OKTO_INSTALL_DIR, OKTO_REPO, OKTO_SIGN_REPO, OKTO_VERSION
EOF
      exit 0
      ;;
    *) echo "install.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m✗\033[0m install.sh: %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "missing required tool: $1"; exit 1; }; }

need uname
need tar
need mkdir
need mv

# curl preferred; wget fallback.
if command -v curl >/dev/null 2>&1; then
  fetch()        { curl -fsSL "$1" -o "$2"; }
  fetch_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch()        { wget -q -O "$2" "$1"; }
  fetch_stdout() { wget -q -O - "$1"; }
else
  err "need curl or wget"; exit 1
fi

# Detect (os, arch).
case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *)
    err "unsupported OS: $(uname -s) — macOS and Linux are supported; Windows: use install.ps1"
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)   ARCH=x86_64 ;;
  arm64|aarch64)  ARCH=aarch64 ;;
  *)
    err "unsupported arch: $(uname -m) — x86_64 and aarch64 are supported"
    exit 1
    ;;
esac

ASSET="okto-${OS}-${ARCH}.tar.gz"
say "detected platform: ${OS}/${ARCH}"

# Resolve tag. Accept "0.1.0", "v0.1.0", or omit for "latest v*".
if [ -z "$VERSION" ]; then
  say "looking up latest v* release in ${REPO}"
  TAG="$(fetch_stdout "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name":[[:space:]]*"v' \
    | head -n 1 \
    | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/' || true)"
  if [ -z "$TAG" ]; then
    err "could not find a v* release in ${REPO}"
    err "if you're installing pre-release, pass --version v0.1.0 explicitly"
    exit 2
  fi
else
  V="${VERSION#v}"
  TAG="v${V}"
fi
say "tag: ${TAG}"

BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t okto-install)"
trap 'rm -rf "$TMP"' EXIT INT TERM

say "downloading ${ASSET}"
fetch "${BASE_URL}/${ASSET}"        "${TMP}/${ASSET}"
fetch "${BASE_URL}/${ASSET}.sha256" "${TMP}/${ASSET}.sha256"

# SHA256 — the .sha256 file is "<hash>  <filename>"; extract just the hash.
EXPECTED="$(awk '{print $1}' "${TMP}/${ASSET}.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "${TMP}/${ASSET}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')"
else
  err "no sha256 tool found (need sha256sum or shasum)"
  exit 1
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
  err "sha256 mismatch — expected=$EXPECTED actual=$ACTUAL"
  err "refusing to install a tampered archive"
  exit 1
fi
say "sha256 ok"

# Signature — the integrity root. The .sha256 above shares the
# artifact's download channel, so it only catches accidental
# corruption; the cosign bundle binds the bytes to the mirror's
# sign-release.yml identity. Required unless OKTO_SKIP_SIGNATURE is set.
if [ "${OKTO_SKIP_SIGNATURE:-}" = "1" ] || [ "${OKTO_SKIP_SIGNATURE:-}" = "true" ]; then
  err "OKTO_SKIP_SIGNATURE set — installing WITHOUT verifying the release signature"
elif command -v cosign >/dev/null 2>&1; then
  fetch "${BASE_URL}/${ASSET}.cosign.bundle" "${TMP}/${ASSET}.cosign.bundle"
  # Pin the signing identity to THIS tag's ref, not a branch: the release
  # was signed by sign-release.yml dispatched against refs/tags/${TAG}, so
  # a bundle from any other version (or a branch build) won't match.
  # Escape the tag's dots so the regexp is literal.
  TAG_RE="$(printf '%s' "$TAG" | sed 's/\./\\./g')"
  if cosign verify-blob \
      --bundle "${TMP}/${ASSET}.cosign.bundle" \
      --certificate-identity-regexp "^https://github\.com/${SIGN_REPO}/\.github/workflows/sign-release\.yml@refs/tags/${TAG_RE}$" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      "${TMP}/${ASSET}" >/dev/null 2>&1; then
    say "cosign signature ok"
  else
    err "cosign signature verification FAILED — refusing to install"
    exit 1
  fi
else
  err "cosign not found — cannot verify the release signature."
  err "install cosign (https://docs.sigstore.dev/cosign/installation) and re-run,"
  err "or set OKTO_SKIP_SIGNATURE=1 to install WITHOUT verification (not recommended)."
  exit 1
fi

say "extracting"
mkdir -p "${TMP}/x"
tar -C "${TMP}/x" -xzf "${TMP}/${ASSET}"

# Default install dir: ~/.local/bin (per INSTALLER.md). Try
# /usr/local/bin only if we already have write access; otherwise
# stay user-scoped — sudo prompts in curl-pipe-sh are user-hostile.
if [ -z "$INSTALL_DIR" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="${HOME}/.local/bin"
  fi
fi
mkdir -p "$INSTALL_DIR"

DEST="${INSTALL_DIR}/okto"
mv -f "${TMP}/x/okto" "$DEST"
chmod +x "$DEST"

printf '\n\033[1;32m✓ okto installed\033[0m to %s\n\n' "$DEST"

# PATH check — be helpful, not pushy. We don't edit shell rcs on the
# user's behalf; we print the exact line they can paste.
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf '%s is not on your PATH yet.\n' "$INSTALL_DIR"
    printf 'Add this to your shell rc and restart your shell:\n\n'
    printf '    export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
    ;;
esac

cat <<'EOF'
Next steps:

  okto start       # start a self-contained okto deployment (Compose by default)
  okto stop        # stop it (data + secrets kept unless --purge)
  okto --help      # full command reference

Manage agents and route jobs from the deployment's console/API once it is up.
See https://oktomata.com for documentation.
EOF
