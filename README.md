# okto-dist

Public **distribution repository** for the [okto](https://oktomata.com) CLI.

This repository holds the signed release binaries of the `okto` CLI and the
installer scripts, published so they can be downloaded without
authentication.

## Install

macOS / Linux:

```sh
curl -fsSL https://oktomata.com/install | sh
# or, raw fallback:
curl -fsSL https://raw.githubusercontent.com/oktomata/okto-dist/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/oktomata/okto-dist/main/install.ps1 | iex
```

Self-update an existing install:

```sh
okto update
```

## Provenance

Every archive ships a SHA-256 sidecar and a keyless
[Sigstore](https://www.sigstore.dev/) `cosign` bundle. The installers and
`okto update` verify the signature against this repository's release
workflow identity. Verification is mandatory unless explicitly skipped.

Manual check (the identity is pinned to the release tag you're verifying —
substitute `<tag>`, e.g. `v0.1.0`):

```sh
cosign verify-blob \
  --bundle okto-<os>-<arch>.tar.gz.cosign.bundle \
  --certificate-identity-regexp '^https://github.com/oktomata/okto-dist/\.github/workflows/sign-release\.yml@refs/tags/<tag>$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  okto-<os>-<arch>.tar.gz
```

Each release also includes a CycloneDX SBOM (`okto-sbom.cdx.json`).

## Note

The `install.sh` / `install.ps1` here are generated copies kept in sync so
the raw-URL install path works anonymously. Don't edit them here directly —
change them upstream and re-sync.
