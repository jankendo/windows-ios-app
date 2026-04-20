[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$P12Path,

    [Parameter(Mandatory = $true)]
    [string]$ProvisioningProfilePath,

    [string]$OutputDirectory = ".\local-secrets"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $P12Path)) {
    throw "P12 file not found: $P12Path"
}

if (-not (Test-Path -LiteralPath $ProvisioningProfilePath)) {
    throw "Provisioning profile not found: $ProvisioningProfilePath"
}

$resolvedOutputDirectory = Resolve-Path -LiteralPath $OutputDirectory -ErrorAction SilentlyContinue
if (-not $resolvedOutputDirectory) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $resolvedOutputDirectory = Resolve-Path -LiteralPath $OutputDirectory
}

$p12Base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $P12Path)))
$profileBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ProvisioningProfilePath)))

$p12Output = Join-Path $resolvedOutputDirectory "build-certificate-base64.txt"
$profileOutput = Join-Path $resolvedOutputDirectory "build-provision-profile-base64.txt"

[IO.File]::WriteAllText($p12Output, $p12Base64, [Text.Encoding]::ASCII)
[IO.File]::WriteAllText($profileOutput, $profileBase64, [Text.Encoding]::ASCII)

Write-Host "Created:"
Write-Host "  $p12Output"
Write-Host "  $profileOutput"
Write-Host ""
Write-Host "Register these secrets in GitHub Actions:"
Write-Host "  BUILD_CERTIFICATE_BASE64 = content of build-certificate-base64.txt"
Write-Host "  BUILD_PROVISION_PROFILE_BASE64 = content of build-provision-profile-base64.txt"
Write-Host "  P12_PASSWORD = password used when exporting the .p12 file"
Write-Host "  TEAM_ID = optional; if omitted, the workflow will read it from the provisioning profile"

