[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$P12Password,

    [string]$CertificateBase64Path = ".\local-secrets\build-certificate-base64.txt",

    [string]$ProvisioningProfileBase64Path = ".\local-secrets\build-provision-profile-base64.txt",

    [string]$TeamId
)

$ErrorActionPreference = "Stop"

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh -and (Test-Path -LiteralPath "C:\Program Files\GitHub CLI\gh.exe")) {
    $gh = Get-Item "C:\Program Files\GitHub CLI\gh.exe"
}

if (-not $gh) {
    throw "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/ and sign in with 'gh auth login'."
}

$ghPath = if ($gh -is [System.Management.Automation.CommandInfo]) {
    $gh.Source
}
else {
    $gh.FullName
}

if (-not $env:GH_TOKEN) {
    try {
        & $ghPath auth status | Out-Null
    }
    catch {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' or provide GH_TOKEN in the environment."
    }
}

foreach ($path in @($CertificateBase64Path, $ProvisioningProfileBase64Path)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

$certificateBase64 = (Get-Content -LiteralPath $CertificateBase64Path -Raw).Trim()
$provisionBase64 = (Get-Content -LiteralPath $ProvisioningProfileBase64Path -Raw).Trim()

if (-not $certificateBase64) {
    throw "Certificate Base64 file is empty: $CertificateBase64Path"
}

if (-not $provisionBase64) {
    throw "Provisioning profile Base64 file is empty: $ProvisioningProfileBase64Path"
}

$secretMap = [ordered]@{
    BUILD_CERTIFICATE_BASE64       = $certificateBase64
    BUILD_PROVISION_PROFILE_BASE64 = $provisionBase64
    P12_PASSWORD                   = $P12Password
}

if ($TeamId) {
    $secretMap["TEAM_ID"] = $TeamId
}

foreach ($entry in $secretMap.GetEnumerator()) {
    & $ghPath secret set $entry.Key --repo $Repository --body $entry.Value
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set GitHub secret: $($entry.Key)"
    }
}

Write-Host "GitHub Actions secrets were updated for $Repository"

