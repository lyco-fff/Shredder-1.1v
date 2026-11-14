@echo off
setlocal DisableDelayedExpansion
title SHRED - Secure AES-256 File ^& Folder Shredder

:: ============================================================================
:: 1. AUTO-ELEVATE TO ADMINISTRATOR (Single-Window Hand-off)
:: ============================================================================
net session >nul 2>&1
if errorlevel 1 goto :ELEVATE
goto :INIT

:ELEVATE
echo Requesting Administrator privileges...
set "CRUSH_SELF=%~f0"
powershell -NoProfile -Command "try { Start-Process -FilePath $env:CRUSH_SELF -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo.
    echo ============================================================================
    echo [ERROR] Administrator privileges were declined.
    echo Please click "Yes" on the UAC prompt, or right-click "%~nx0"
    echo and select "Run as administrator".
    echo ============================================================================
    pause
    exit /b 1
)
:: Immediately close this non-admin launcher window once the elevated window opens
exit

:INIT
:: Lock working directory to the folder containing this .bat file
cd /d "%~dp0"
set "SHRED_SELF=%~f0"

:: Run embedded PowerShell engine directly in memory
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$raw = [IO.File]::ReadAllText($env:SHRED_SELF); $m = '# === PS_MAIN' + '_START ==='; $i = $raw.LastIndexOf($m); if ($i -lt 0) { Write-Host '[ERROR] Engine marker not found.' -ForegroundColor Red; exit 1 }; Invoke-Expression $raw.Substring($i + $m.Length)"

echo.
pause
exit /b 0

# === PS_MAIN_START ===
try {
    $ErrorActionPreference = 'Stop'

    $SelfBat = [IO.Path]::GetFullPath($env:SHRED_SELF).TrimEnd('\')
    $SysDrive = $env:SystemDrive.TrimEnd('\')

    # 1. Protected Windows & System trees (blocks the folder AND anything inside it)
    $ProtectedTrees = @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        "$SysDrive\System Volume Information",
        "$SysDrive\Recovery",
        "$SysDrive\Boot",
        "$SysDrive\EFI",
        "$SysDrive\`$Recycle.Bin",
        "$SysDrive\Windows.old",
        (Join-Path $env:USERPROFILE 'AppData')
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }

    # 2. Protected root user containers (blocks deleting the root container itself, allows items inside)
    $ProtectedRootsOnly = @(
        "$SysDrive\Users",
        $env:USERPROFILE,
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos'),
        (Join-Path $env:USERPROFILE 'Downloads')
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }

    $ProtectedFileNames = @(
        'bootmgr', 'bootnxt', 'ntldr', 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys',
        'ntoskrnl.exe', 'hal.dll', 'winload.exe', 'winload.efi', 'ntuser.dat'
    )

    function Format-FileSize([long]$bytes) {
        if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
        if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
        if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
        return "$bytes B"
    }

    function Test-SafetyGuard([string]$rawPath) {
        try {
            $full = [IO.Path]::GetFullPath($rawPath).TrimEnd('\')
        } catch {
            return [pscustomobject]@{ Allowed = $false; Reason = "Invalid path syntax" }
        }

        if ($full -match '^[A-Za-z]:$') {
            return [pscustomobject]@{ Allowed = $false; Reason = "Drive root ($full\) cannot be shredded" }
        }

        if ($full -ieq $SelfBat) {
            return [pscustomobject]@{ Allowed = $false; Reason = "Cannot shred the active Shredder.bat script" }
        }

        foreach ($tree in $ProtectedTrees) {
            if ($full -ieq $tree -or $full.StartsWith("$tree\", [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Allowed = $false; Reason = "Protected Windows/System path ($tree)" }
            }
            if ($tree.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Allowed = $false; Reason = "Folder contains critical Windows directory ($tree)" }
            }
        }

        foreach ($root in $ProtectedRootsOnly) {
            if ($full -ieq $root) {
                return [pscustomobject]@{ Allowed = $false; Reason = "Protected root user folder ($root)" }
            }
            if ($root.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Allowed = $false; Reason = "Folder contains protected user profile root ($root)" }
            }
        }

        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force
            $leaf = $item.Name.ToLowerInvariant()

            if ($ProtectedFileNames -contains $leaf) {
                return [pscustomobject]@{ Allowed = $false; Reason = "Protected Windows OS file ($($item.Name))" }
            }

            if (($item.Attributes -band [IO.FileAttributes]::System) -and -not $item.PSIsContainer) {
                if ($leaf -ne 'desktop.ini' -and $leaf -ne 'thumbs.db') {
                    return [pscustomobject]@{ Allowed = $false; Reason = "File has Windows System attribute set" }
                }
            }
        }

        return [pscustomobject]@{ Allowed = $true; Reason = "OK" }
    }

    function Invoke-SecureShred([System.IO.FileInfo]$fileInfo, [System.Security.Cryptography.RandomNumberGenerator]$rng, [byte[]]$inBuf, [byte[]]$outBuf) {
        $fullPath = $fileInfo.FullName
        $BufferSize = $inBuf.Length
        try {
            [IO.File]::SetAttributes($fullPath, [IO.FileAttributes]::Normal)
            $len = ([IO.FileInfo]::new($fullPath)).Length

            if ($len -gt 0) {
                $fs = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    # Pass 1: In-Place AES-256 Encryption with ephemeral key
                    $aes = [System.Security.Cryptography.Aes]::Create()
                    try {
                        $aes.KeySize = 256
                        $aes.BlockSize = 128
                        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
                        $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
                        $aes.GenerateKey()
                        $aes.GenerateIV()

                        $encryptor = $aes.CreateEncryptor()
                        try {
                            $offset = [long]0
                            while ($offset -lt $len) {
                                $fs.Position = $offset
                                $toRead = [int][Math]::Min($BufferSize, $len - $offset)
                                $read = $fs.Read($inBuf, 0, $toRead)
                                if ($read -le 0) { break }

                                $aligned = [int]([Math]::Ceiling($read / 16.0) * 16)
                                if ($aligned -gt $read) {
                                    [Array]::Clear($inBuf, $read, $aligned - $read)
                                }

                                [void]$encryptor.TransformBlock($inBuf, 0, $aligned, $outBuf, 0)
                                $fs.Position = $offset
                                $fs.Write($outBuf, 0, $read)
                                $offset += $read
                            }
                            $fs.Flush($true)
                        } finally {
                            $encryptor.Dispose()
                        }
                        $aes.Clear()
                    } finally {
                        $aes.Dispose()
                    }

                    # Pass 2: CSPRNG Random Overwrite + 0-Byte Truncation
                    $fs.Position = 0
                    $rem = $len
                    while ($rem -gt 0) {
                        $chunk = [int][Math]::Min($BufferSize, $rem)
                        $rng.GetBytes($outBuf)
                        $fs.Write($outBuf, 0, $chunk)
                        $rem -= $chunk
                    }
                    $fs.Flush($true)
                    $fs.SetLength(0)
                    $fs.Flush($true)
                } finally {
                    $fs.Close()
                    $fs.Dispose()
                }
            }

            # Pass 3: Scrub MFT timestamps, rename with .NET IO, and delete
            $epoch = New-Object DateTime(1980, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($fullPath, $epoch)
            [IO.File]::SetLastWriteTimeUtc($fullPath, $epoch)
            [IO.File]::SetLastAccessTimeUtc($fullPath, $epoch)

            $parentDir = [IO.Path]::GetDirectoryName($fullPath)
            $randomLeaf = [IO.Path]::GetRandomFileName()
            $renamedPath = [IO.Path]::Combine($parentDir, $randomLeaf)

            [IO.File]::Move($fullPath, $renamedPath)
            [IO.File]::Delete($renamedPath)

            Write-Host " [ENCRYPTED & SHREDDED] $fullPath" -ForegroundColor Green
        } catch {
            Write-Host " [FAILED] $fullPath - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    while ($true) {
        Clear-Host
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "              SHRED - Secure AES-256 File & Folder Shredder" -ForegroundColor Cyan
        Write-Host "         Administrator Mode | Windows OS & Profile Safeguards Active" -ForegroundColor DarkCyan
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " TIP: In File Explorer, right-click a folder/file and select 'Copy as path'" -ForegroundColor Gray
        Write-Host "      (or copy the address bar), then right-click or press Ctrl+V below." -ForegroundColor Gray
        Write-Host ""

        $rawInput = Read-Host "Paste folder or file path here (or type Q to quit)"
        if ([string]::IsNullOrWhiteSpace($rawInput)) { continue }

        $targetPath = $rawInput.Trim().Trim('"', "'").Trim()
        if ($targetPath -ieq 'Q' -or $targetPath -ieq 'EXIT') {
            Write-Host ""
            Write-Host "Exiting shredder safely." -ForegroundColor Yellow
            break
        }

        if (-not ([IO.File]::Exists($targetPath) -or [IO.Directory]::Exists($targetPath))) {
            Write-Host ""
            Write-Host " [ERROR] Path not found: $targetPath" -ForegroundColor Red
            Write-Host " Make sure the folder or file exists and try again." -ForegroundColor Yellow
            Write-Host ""
            [void](Read-Host "Press Enter to try again")
            continue
        }

        $FilesToShred = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        $FoldersToClean = New-Object System.Collections.Generic.List[string]
        $BlockedItems = New-Object System.Collections.Generic.List[string]
        $TotalBytes = [long]0

        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "           SCANNING TARGET & VERIFYING WINDOWS SAFEGUARDS" -ForegroundColor Cyan
        Write-Host "============================================================================" -ForegroundColor Cyan

        $guard = Test-SafetyGuard $targetPath
        $rootItem = Get-Item -LiteralPath $targetPath -Force

        if (-not $guard.Allowed) {
            $BlockedItems.Add("$($rootItem.FullName)  -->  $($guard.Reason)")
        } elseif ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $BlockedItems.Add("$($rootItem.FullName)  -->  Skipped symlink/junction for safety")
        } elseif ($rootItem.PSIsContainer) {
            Write-Host ""
            Write-Host " [TARGET FOLDER] $($rootItem.FullName)" -ForegroundColor Yellow
            $FoldersToClean.Add($rootItem.FullName)

            $subItems = @(Get-ChildItem -LiteralPath $rootItem.FullName -Recurse -Force -ErrorAction SilentlyContinue)
            if ($subItems.Count -eq 0) {
                Write-Host "    (Empty folder)" -ForegroundColor DarkGray
            }

            foreach ($sub in $subItems) {
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $BlockedItems.Add("$($sub.FullName)  -->  Skipped symlink/junction")
                    continue
                }

                $subGuard = Test-SafetyGuard $sub.FullName
                $relPath = $sub.FullName.Substring($rootItem.FullName.Length).TrimStart('\')

                if (-not $subGuard.Allowed) {
                    $BlockedItems.Add("$($sub.FullName)  -->  $($subGuard.Reason)")
                    Write-Host "    |-- [BLOCKED] $relPath ($($subGuard.Reason))" -ForegroundColor Red
                    continue
                }

                if ($sub.PSIsContainer) {
                    $FoldersToClean.Add($sub.FullName)
                    Write-Host "    |-- [DIR]  $relPath\" -ForegroundColor DarkYellow
                } else {
                    $FilesToShred.Add($sub)
                    $TotalBytes += $sub.Length
                    Write-Host ("    |-- [FILE] {0} ({1})" -f $relPath, (Format-FileSize $sub.Length))
                }
            }
        } else {
            $FilesToShred.Add($rootItem)
            $TotalBytes += $rootItem.Length
            Write-Host ""
            Write-Host (" [TARGET FILE] {0} ({1})" -f $rootItem.FullName, (Format-FileSize $rootItem.Length)) -ForegroundColor Yellow
        }

        if ($BlockedItems.Count -gt 0) {
            Write-Host ""
            Write-Host "============================================================================" -ForegroundColor Red
            Write-Host " SAFEGUARD ALERT - THE FOLLOWING PROTECTED ITEMS WERE BLOCKED:" -ForegroundColor Red
            Write-Host "============================================================================" -ForegroundColor Red
            foreach ($b in $BlockedItems) {
                Write-Host "  [X] $b" -ForegroundColor Red
            }
        }

        if ($FilesToShred.Count -eq 0 -and $FoldersToClean.Count -eq 0) {
            Write-Host ""
            Write-Host "No eligible files or folders to shred." -ForegroundColor Yellow
            Write-Host ""
            [void](Read-Host "Press Enter to return to the path prompt")
            continue
        }

        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host (" SUMMARY: {0} File(s) and {1} Folder(s) queued | Total Size: {2}" -f $FilesToShred.Count, $FoldersToClean.Count, (Format-FileSize $TotalBytes)) -ForegroundColor White
        Write-Host " METHOD : Pass 1: In-Place AES-256 Encryption (Ephemeral Key Destroyed)" -ForegroundColor Gray
        Write-Host "          Pass 2: CSPRNG Random Overwrite + 0-Byte Truncate + MFT Scrub" -ForegroundColor Gray
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host ""

        $confirm = Read-Host "Type SHRED (in ALL CAPS) and press Enter to permanently destroy (or Enter to cancel)"
        if ($confirm -cne 'SHRED') {
            Write-Host ""
            Write-Host "Cancelled. Nothing was modified." -ForegroundColor Yellow
            Write-Host ""
            [void](Read-Host "Press Enter to return to the path prompt")
            continue
        }

        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $BufferSize = 1048576
        $inBuf  = New-Object byte[] $BufferSize
        $outBuf = New-Object byte[] $BufferSize

        Write-Host ""
        Write-Host "Starting encryption and shredding sequence..." -ForegroundColor Cyan

        try {
            foreach ($f in $FilesToShred) {
                Invoke-SecureShred $f $rng $inBuf $outBuf
            }

            $SortedFolders = $FoldersToClean | Sort-Object { $_.Length } -Descending | Select-Object -Unique
            foreach ($dir in $SortedFolders) {
                if ([IO.Directory]::Exists($dir)) {
                    $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
                    if ($remaining.Count -eq 0) {
                        try {
                            $dInfo = [IO.DirectoryInfo]::new($dir)
                            $dInfo.Attributes = [IO.FileAttributes]::Directory
                            $parentDir = [IO.Path]::GetDirectoryName($dir)
                            $randDirLeaf = [IO.Path]::GetRandomFileName()
                            $renamedDir = [IO.Path]::Combine($parentDir, $randDirLeaf)

                            [IO.Directory]::Move($dir, $renamedDir)
                            [IO.Directory]::Delete($renamedDir, $false)
                            Write-Host " [REMOVED FOLDER]       $dir" -ForegroundColor DarkGreen
                        } catch {
                            Write-Host " [FOLDER IN USE]        $dir - $($_.Exception.Message)" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host " [KEPT NON-EMPTY DIR]   $dir (Contains skipped or locked files)" -ForegroundColor Yellow
                    }
                }
            }
        } finally {
            $rng.Dispose()
        }

        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host " Operation complete." -ForegroundColor Green
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host ""
        $again = Read-Host "Press Enter to shred another item, or type Q to quit"
        if ($again.Trim() -ieq 'Q' -or $again.Trim() -ieq 'EXIT') { break }
    }
} catch {
    Write-Host ""
    Write-Host "[CRITICAL ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}