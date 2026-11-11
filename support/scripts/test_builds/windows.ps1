#Requires -Version 5.1
<#
Build an unsigned LocalSend x64 portable ZIP for testing on Windows.
Run on a Windows x64 build machine with Visual Studio C++/CMake, Windows SDK,
the Flutter version from .fvmrc, and Rust from rust-toolchain.toml installed.
No signing service, administrator access, publication, or MSIX registration is used.

Example:
  .\build-windows.ps1 -RepoRoot C:\src\localsend -OutputDirectory C:\builds\localsend

FVM is the default, as requested by AGENTS.md. A CI runner that has installed the
exact Flutter pin may pass -FlutterCommand flutter, as the repository's CI does.
Dependencies are restored with the committed pub lockfile; Flutter/Cargokit may
download missing build artifacts. Provision toolchains before invoking this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'artifacts'),

    [ValidateSet('fvm', 'flutter')]
    [string]$FlutterCommand = 'fvm'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([string]$Executable, [string[]]$Arguments)
    $nativeTail = New-Object 'System.Collections.Generic.Queue[string]'
    & $Executable @Arguments 2>&1 | ForEach-Object {
        $nativeTail.Enqueue($_.ToString())
        if ($nativeTail.Count -gt 20) { [void]$nativeTail.Dequeue() }
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            # Keep stderr visible without adding it to machine-readable stdout.
            Write-Host $_.ToString()
        } else {
            Write-Output $_
        }
    }
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) {
        $tail = $nativeTail.ToArray() -join "`n"
        throw "Native command failed (exit $nativeExitCode): $Executable $($Arguments -join ' ')`n$tail"
    }
}

function Invoke-Flutter {
    param([string[]]$Arguments)
    if ($FlutterCommand -eq 'fvm') {
        Invoke-Native -Executable $FlutterCommand -Arguments (@('flutter') + $Arguments)
    } else {
        Invoke-Native -Executable $FlutterCommand -Arguments $Arguments
    }
}

function Read-FlutterMachineVersion {
    param([string]$RawOutput, [string]$ExpectedVersion)
    # A first Flutter invocation can print dependency/bootstrap progress before
    # its machine JSON. Select the line-delimited object, not that prelude.
    $jsonMatch = [regex]::Match($RawOutput, '(?ms)^[ \t]*(\{.*\})[ \t]*\r?$')
    $rawTail = $RawOutput.Substring([Math]::Max(0, $RawOutput.Length - 2000))
    if (-not $jsonMatch.Success) {
        throw "Flutter --version --machine did not return a JSON object. Response tail:`n$rawTail"
    }
    try {
        $versionInfo = $jsonMatch.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Flutter --version --machine returned malformed JSON. Response tail:`n$rawTail"
    }
    $versionProperty = $versionInfo.PSObject.Properties['frameworkVersion']
    if ($null -eq $versionProperty -or $versionProperty.Value -isnot [string]) {
        throw "Flutter version JSON has no string frameworkVersion. Response tail:`n$rawTail"
    }
    if ($versionProperty.Value -ne $ExpectedVersion) {
        throw "Flutter $ExpectedVersion is required; selected Flutter is $($versionProperty.Value)."
    }
    return $versionInfo
}

function Assert-X64Pe {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE executable: $Path" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Missing PE signature: $Path" }
        if ($reader.ReadUInt16() -ne 0x8664) { throw "Expected an x64 PE image: $Path" }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script requires a native Windows build machine.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run this script from 64-bit PowerShell.'
}
foreach ($command in @($FlutterCommand, 'git', 'rustup')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $command"
    }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$appRoot = Join-Path $RepoRoot 'app'
$flutterPin = (Get-Content -LiteralPath (Join-Path $RepoRoot '.fvmrc') -Raw | ConvertFrom-Json).flutter
$rustPinMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'rust-toolchain.toml') -Raw), '(?m)^channel\s*=\s*"([^"]+)"')
if (-not $rustPinMatch.Success) { throw 'Cannot read the repository Rust toolchain pin.' }
$rustPin = $rustPinMatch.Groups[1].Value
$versionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $appRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[^\r\n]+)?\s*$')
if (-not $versionMatch.Success) { throw 'Cannot read the LocalSend app version.' }
$appVersion = $versionMatch.Groups[1].Value

$sdkBinRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$sdkCandidates = @(Get-ChildItem -LiteralPath $sdkBinRoot -Directory | Where-Object {
    $_.Name -match '^10\.\d+\.\d+\.\d+$' -and
    (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makepri.exe')) -and
    (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makeappx.exe'))
} | Sort-Object { [version]$_.Name } -Descending)
if ($sdkCandidates.Count -eq 0) { throw 'Install a Windows SDK containing x64 makepri.exe and makeappx.exe.' }
$makePri = Join-Path $sdkCandidates[0].FullName 'x64\makepri.exe'
$makeAppx = Join-Path $sdkCandidates[0].FullName 'x64\makeappx.exe'

$originalLocation = Get-Location
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('localsend-windows-test-' + [guid]::NewGuid().ToString('N'))
$helperPath = Join-Path $appRoot 'windows\localsend_msix_helper.msix'
$helperBackup = Join-Path $tempRoot 'original-helper.msix'
$helperReplaced = $false
$helperExisted = Test-Path -LiteralPath $helperPath
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    Set-Location -LiteralPath $RepoRoot
    $commit = ((Invoke-Native -Executable 'git' -Arguments @('rev-parse', 'HEAD')) -join "`n").Trim()
    $trackedChanges = @((Invoke-Native -Executable 'git' -Arguments @('status', '--porcelain=v1', '--untracked-files=no')))
    $flutterVersionJson = (Invoke-Flutter -Arguments @('--version', '--machine')) -join "`n"
    $flutterInfo = Read-FlutterMachineVersion -RawOutput $flutterVersionJson -ExpectedVersion $flutterPin
    $rustVersion = ((Invoke-Native -Executable 'rustup' -Arguments @('run', $rustPin, 'rustc', '--version')) -join "`n").Trim()

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $archiveName = "LocalSend-$appVersion-windows-x86-64-test-$($commit.Substring(0, 12)).zip"
    $archivePath = Join-Path $OutputDirectory $archiveName
    if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath "$archivePath.sha256")) {
        throw "Output already exists; choose a new OutputDirectory: $archivePath"
    }

    # CMake requires a helper MSIX during its install step, even for a portable
    # build. Generate resources in scratch space, preserving any existing helper.
    $msixContent = Join-Path $tempRoot 'msix-content'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'support\build\msix\content') -Destination $msixContent -Recurse
    Invoke-Native -Executable $makePri -Arguments @(
        'new', '/pr', $msixContent,
        '/cf', (Join-Path $RepoRoot 'support\build\msix\priconfig.xml'),
        '/mn', (Join-Path $msixContent 'AppxManifest.xml'),
        '/of', (Join-Path $msixContent 'resources.pri'), '/o'
    )
    $generatedHelper = Join-Path $tempRoot 'localsend_msix_helper.msix'
    Invoke-Native -Executable $makeAppx -Arguments @('pack', '/o', '/d', $msixContent, '/nv', '/p', $generatedHelper)
    if ($helperExisted) { Copy-Item -LiteralPath $helperPath -Destination $helperBackup }
    $helperReplaced = $true
    Copy-Item -LiteralPath $generatedHelper -Destination $helperPath -Force

    Set-Location -LiteralPath $appRoot
    Invoke-Flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Set-Location -LiteralPath (Join-Path $RepoRoot 'packages\localsend_isolates\rust_builder\cargokit\build_tool')
    Invoke-Flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Set-Location -LiteralPath $appRoot
    Invoke-Flutter -Arguments @('build', 'windows', '--release', '--target-platform', 'windows-x64', '--no-pub')

    $bundle = Join-Path $appRoot 'build\windows\x64\runner\Release'
    foreach ($required in @('localsend_app.exe', 'flutter_windows.dll', 'rust_lib_localsend_app.dll', 'data\icudtl.dat', 'data\flutter_assets')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Incomplete build bundle: $required" }
    }
    Assert-X64Pe -Path (Join-Path $bundle 'localsend_app.exe')
    Assert-X64Pe -Path (Join-Path $bundle 'rust_lib_localsend_app.dll')

    # Work on a copy so the generated build remains intact. Copy every file and
    # subdirectory, including hidden entries, rather than distributing a lone EXE.
    $portable = Join-Path $tempRoot 'portable'
    New-Item -ItemType Directory -Path $portable | Out-Null
    Get-ChildItem -LiteralPath $bundle -Force | Copy-Item -Destination $portable -Recurse -Force
    foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "support\build\windows\x64\$dll") -Destination $portable -Force
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $portable 'LICENSE') -Force
    if (Test-Path -LiteralPath (Join-Path $RepoRoot 'NOTICE')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'NOTICE') -Destination (Join-Path $portable 'NOTICE') -Force
    }
    [System.IO.File]::WriteAllText((Join-Path $portable 'settings.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))
    foreach ($file in @('localsend_msix_helper.msix', 'install_msix_helper.ps1', 'localsend_app.exe.manifest')) {
        $path = Join-Path $portable $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }

    $metadata = [ordered]@{
        source_commit = $commit
        source_had_tracked_changes = ($trackedChanges.Count -gt 0)
        app_version = $appVersion
        flutter_version = $flutterInfo.frameworkVersion
        rust_version = $rustVersion
        platform = 'windows-x64'
        mode = 'release'
        signing = 'Unsigned LocalSend test build; bundled third-party DLL signatures are retained'
        runtime_tested = $false
        built_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $portable 'BUILD-INFO.json') -Encoding UTF8
    @'
LocalSend portable test build for Windows x64

Extract the ENTIRE ZIP to a writable folder, then open localsend_app.exe there.
Keep data/ and every DLL beside the executable. settings.json enables portable
settings in this folder. This LocalSend build is unsigned and may trigger a
Windows reputation warning. Only run it if you trust its source/build process.
The optional MSIX helper was excluded; Windows Share Target integration requiring
that helper is not included. No package registration or installation is needed.

Compilation and bundle checks do not establish that the GUI or file transfers
work. Test sending and receiving with another device on the same local network.
See BUILD-INFO.json for the source commit and exact toolchain versions.
See LICENSE and data/flutter_assets/ for the included license notices.
'@ | Set-Content -LiteralPath (Join-Path $portable 'TEST-BUILD.txt') -Encoding UTF8

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryZip = Join-Path $tempRoot $archiveName
    [System.IO.Compression.ZipFile]::CreateFromDirectory($portable, $temporaryZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($temporaryZip)
    try {
        foreach ($required in @('localsend_app.exe', 'flutter_windows.dll', 'rust_lib_localsend_app.dll', 'LICENSE', 'settings.json', 'BUILD-INFO.json')) {
            if ($null -eq $zip.GetEntry($required)) { throw "Archive is missing $required" }
        }
    } finally {
        $zip.Dispose()
    }
    Move-Item -LiteralPath $temporaryZip -Destination $archivePath
    $sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$sha256  $archiveName" | Set-Content -LiteralPath "$archivePath.sha256" -Encoding ASCII
    Write-Host "Created: $archivePath"
    Write-Host "SHA-256: $sha256"
    Write-Host 'Compilation and packaging completed. GUI and transfer testing remain pending.'
} finally {
    if ($helperReplaced) {
        if ($helperExisted) {
            Copy-Item -LiteralPath $helperBackup -Destination $helperPath -Force
        } elseif (Test-Path -LiteralPath $helperPath) {
            Remove-Item -LiteralPath $helperPath -Force
        }
    }
    Set-Location -LiteralPath $originalLocation.Path
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
