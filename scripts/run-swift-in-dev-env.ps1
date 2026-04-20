[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SwiftArguments
)

$ErrorActionPreference = "Stop"

$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\Common7\Tools\VsDevCmd.bat"
$swiftExe = "C:\Users\janke\AppData\Local\Programs\Swift\Toolchains\6.3.1+Asserts\usr\bin\swift.exe"
$swiftToolchainBin = "C:\Users\janke\AppData\Local\Programs\Swift\Toolchains\6.3.1+Asserts\usr\bin"
$swiftRuntimeBin = "C:\Users\janke\AppData\Local\Programs\Swift\Runtimes\6.3.1\usr\bin"
$windowsSdkDir = "C:\Program Files (x86)\Windows Kits\10\"
$windowsSdkVersion = "10.0.18362.0\"

if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw "Visual Studio developer command script not found: $vsDevCmd"
}

if (-not (Test-Path -LiteralPath $swiftExe)) {
    throw "Swift executable not found: $swiftExe"
}

$swiftArgString = if ($SwiftArguments) {
    ($SwiftArguments | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    }) -join " "
} else {
    ""
}

$command = @"
call "$vsDevCmd" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b 1
set WindowsSdkDir=$windowsSdkDir
set WindowsSDKVersion=$windowsSdkVersion
set PATH=$swiftRuntimeBin;$swiftToolchainBin;%PATH%
"$swiftExe" $swiftArgString
"@

$temporaryBatch = Join-Path $env:TEMP "run-swift-in-dev-env.cmd"
[IO.File]::WriteAllText($temporaryBatch, "@echo off`r`n$command`r`n", [Text.Encoding]::ASCII)

try {
    & cmd /c $temporaryBatch
    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $temporaryBatch -Force -ErrorAction SilentlyContinue
}

