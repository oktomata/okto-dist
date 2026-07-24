# Okto CLI installer (Windows).
#
# Usage:
#   irm https://oktomata.com/install.ps1 | iex
#   iex "& { $(irm https://oktomata.com/install.ps1) } -Version 0.1.0"
#
# Env vars:
#   OKTO_INSTALL_DIR    override the install directory (default: %USERPROFILE%\.okto\bin)
#   OKTO_REPO           download repo (default: oktomata/okto-dist, the
#                       PUBLIC release mirror — the source repo is private)
#   OKTO_SIGN_REPO      repo whose signing-workflow identity the cosign
#                       signature must match (default: oktomata/okto-dist;
#                       signing runs in the mirror's sign-release.yml on the release tag)
#   OKTO_VERSION        same as -Version

[CmdletBinding()]
param(
    [string]$Version = $env:OKTO_VERSION,
    [string]$InstallDir = $env:OKTO_INSTALL_DIR,
    [string]$Repo,
    [string]$SignRepo
)

if (-not $Repo) {
    $Repo = if ($env:OKTO_REPO) { $env:OKTO_REPO } else { "oktomata/okto-dist" }
}
if (-not $SignRepo) {
    $SignRepo = if ($env:OKTO_SIGN_REPO) { $env:OKTO_SIGN_REPO } else { "oktomata/okto-dist" }
}

$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "▸ $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "✗ install.ps1: $m" -ForegroundColor Red; exit 1 }

# Arch detection. Only x86_64 ships today; aarch64 reserved.
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "x86_64" }
    "ARM64" { "aarch64" }
    default { Die "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}
if ($arch -ne "x86_64") {
    Die "Windows builds are x86_64-only at this time (got $arch)"
}
$asset = "okto-windows-$arch.zip"
Say "detected platform: windows/$arch"

# Resolve tag.
if (-not $Version) {
    Say "looking up latest v* release in $Repo"
    $headers = @{ "User-Agent" = "okto-installer" }
    $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
    $tag = $latest.tag_name
    if (-not $tag -or -not $tag.StartsWith("v")) {
        Die "no v* release found in $Repo. Pass -Version v0.1.0 for pre-release."
    }
} else {
    $v = $Version -replace '^v',''
    $tag = "v$v"
}
Say "tag: $tag"

$baseUrl = "https://github.com/$Repo/releases/download/$tag"
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP ("okto-install-" + [Guid]::NewGuid().ToString("N")))
try {
    $zipPath = Join-Path $tmp $asset
    $shaPath = "$zipPath.sha256"

    Say "downloading $asset"
    Invoke-WebRequest -Uri "$baseUrl/$asset"        -OutFile $zipPath -UseBasicParsing
    Invoke-WebRequest -Uri "$baseUrl/$asset.sha256" -OutFile $shaPath -UseBasicParsing

    $expected = ((Get-Content -Raw $shaPath) -split '\s+')[0].ToLower()
    $actual   = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
    if ($expected -ne $actual) {
        Die "sha256 mismatch — expected=$expected actual=$actual. Refusing to install."
    }
    Say "sha256 ok"

    # Signature — the integrity root. The .sha256 above shares the
    # artifact's download channel; the cosign bundle binds the bytes to
    # the mirror's sign-release.yml identity. Required unless
    # $env:OKTO_SKIP_SIGNATURE is set.
    if ($env:OKTO_SKIP_SIGNATURE -eq "1" -or $env:OKTO_SKIP_SIGNATURE -eq "true") {
        Write-Warning "OKTO_SKIP_SIGNATURE set - installing WITHOUT verifying the release signature"
    } elseif (Get-Command cosign -ErrorAction SilentlyContinue) {
        $bundlePath = "$zipPath.cosign.bundle"
        Invoke-WebRequest -Uri "$baseUrl/$asset.cosign.bundle" -OutFile $bundlePath -UseBasicParsing
        $identity = "^https://github\.com/$SignRepo/\.github/workflows/sign-release\.yml@refs/tags/v.*$"
        & cosign verify-blob --bundle $bundlePath --certificate-identity-regexp $identity --certificate-oidc-issuer "https://token.actions.githubusercontent.com" $zipPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            Die "cosign signature verification FAILED - refusing to install"
        }
        Say "cosign signature ok"
    } else {
        Die "cosign not found - cannot verify the release signature. Install cosign (https://docs.sigstore.dev/cosign/installation) and re-run, or set OKTO_SKIP_SIGNATURE=1 to install WITHOUT verification (not recommended)."
    }

    $extract = Join-Path $tmp "x"
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force

    if (-not $InstallDir) {
        $InstallDir = Join-Path $env:USERPROFILE ".okto\bin"
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $dest = Join-Path $InstallDir "okto.exe"
    Move-Item -Force -Path (Join-Path $extract "okto.exe") -Destination $dest
    Say "installed to $dest"

    # Add to user PATH if missing. `setx` persists; current shell still
    # needs a restart to see the change.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $onPath = $userPath -split ';' | Where-Object { $_ -ieq $InstallDir }
    if (-not $onPath) {
        Say "adding $InstallDir to user PATH (restart your shell to pick it up)"
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    }

    Write-Host ""
    Write-Host "✓ okto installed" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host ""
    Write-Host "  okto start       # start the self-contained okto Compose deployment"
    Write-Host "  okto stop        # stop it (data + secrets kept unless --purge)"
    Write-Host "  okto --help      # full command reference"
    Write-Host ""
    Write-Host "Manage agents and route jobs from the deployment's console/API once it is up."
    Write-Host "See https://oktomata.com for documentation."
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
