[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$P12Password,

    [string]$TeamId = "2M6M6BW775",

    [switch]$CreateRepository,

    [switch]$Public
)

$ErrorActionPreference = "Stop"

$ghPath = "C:\Program Files\GitHub CLI\gh.exe"
if (-not (Test-Path -LiteralPath $ghPath)) {
    throw "GitHub CLI not found: $ghPath"
}

if (-not $env:GH_TOKEN) {
    try {
        & $ghPath auth status | Out-Null
    }
    catch {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' first or provide GH_TOKEN in the environment."
    }
}

if ($CreateRepository) {
    $visibility = if ($Public) { "--public" } else { "--private" }
    & $ghPath repo create $Repository $visibility --source . --remote origin --push=false
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create repository: $Repository"
    }
}

$publishSecretsScript = Join-Path $PSScriptRoot "publish-github-secrets.ps1"
pwsh -File $publishSecretsScript -Repository $Repository -P12Password $P12Password -TeamId $TeamId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to publish GitHub Actions secrets."
}

$originUrl = "https://github.com/$Repository.git"
$currentOrigin = git remote get-url origin 2>$null

if (-not $currentOrigin) {
    git remote add origin $originUrl
}
elseif ($currentOrigin -ne $originUrl) {
    git remote set-url origin $originUrl
}

git add .

$hasChanges = git status --short
if ($hasChanges) {
    git commit -m "Initial Windows iOS build scaffold`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
}

git push -u origin main
if ($LASTEXITCODE -ne 0) {
    throw "Failed to push to origin main."
}

Write-Host "Repository configured and pushed: $Repository"

