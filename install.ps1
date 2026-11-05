<#
.SYNOPSIS
    Installs the Trading Book addon into World of Warcraft (Retail).

.DESCRIPTION
    Copies the .toc and the files it lists into Interface\AddOns, and nothing else. The
    installed folder is replaced every time: after changing the code, run the script
    again, then /reload in game.

.PARAMETER Clean
    Also deletes Trading Book's saved data (history, stock, gold) on all accounts. This
    cannot be undone: you are asked to confirm, and WoW must be closed. Add
    -Confirm:$false to skip the question.

.PARAMETER WowPath
    The World of Warcraft installation folder, the one containing _retail_.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Clean

.EXAMPLE
    .\install.ps1 -Clean -WhatIf
    Shows what would be done, without changing anything.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Clean,
    [string] $WowPath = 'C:\Program Files (x86)\World of Warcraft'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$addonName = 'TradingBook'
$tocName = "$addonName.toc"
$tocPath = Join-Path $PSScriptRoot $tocName
$retailPath = Join-Path $WowPath '_retail_'
$addOnsPath = Join-Path $retailPath 'Interface\AddOns'
$installPath = Join-Path $addOnsPath $addonName
# Beside the final folder, so that putting it in place is a rename. The client ignores
# it: a folder only counts as an addon if it holds a .toc of its own name.
$stagingPath = "$installPath.install-tmp"

if (-not (Test-Path -LiteralPath $tocPath -PathType Leaf)) {
    throw "$tocName was not found next to this script ($PSScriptRoot)."
}
if (-not (Test-Path -LiteralPath $addOnsPath -PathType Container)) {
    throw "World of Warcraft (Retail) was not found in '$WowPath'. Give its folder with -WowPath."
}

# Checked before changing anything: the client rewrites saved variables when it
# logs out or reloads, so the deleted data would simply come back.
if ($Clean -and (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)) {
    throw 'WoW is open: close it before using -Clean, or it will write its data back when it exits. Nothing was changed.'
}

# Installation ---------------------------------------------------------------

# The .toc is the list of what the client loads, so nothing else needs to be installed.
$tocLines = @(Get-Content -LiteralPath $tocPath)
$files = @($tocName) + @($tocLines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw "Files listed in $tocName but not found: $($missing -join ', '). Nothing was changed."
}

# Whether a folder may be replaced: a copy made by this script has our author in its .toc
# and no install script. A link is refused, as emptying it could empty its target, and so
# is a working copy, which may hold uncommitted work.
function Test-InstalledCopy($Item) {
    if ($Item.LinkType -or (Test-Path -LiteralPath (Join-Path $Item.FullName (Split-Path -Leaf $PSCommandPath)))) {
        return $false
    }
    $installedToc = Join-Path $Item.FullName $tocName
    if (-not (Test-Path -LiteralPath $installedToc -PathType Leaf)) {
        return $false
    }
    $author = $tocLines | Where-Object { $_ -match '^##\s*Author\s*:' } | Select-Object -First 1
    return @(Get-Content -LiteralPath $installedToc) -contains $author
}

# Get-Item rather than Test-Path, which does not see a link whose target has moved.
$existing = Get-Item -LiteralPath $installPath -Force -ErrorAction SilentlyContinue
if ($existing -and -not (Test-InstalledCopy $existing)) {
    throw "'$installPath' already exists and was not installed by this script. Move or delete it, then run the script again. Nothing was changed."
}

# A lower impact than the script's: updating the install is routine and loses nothing,
# unlike -Clean, so it only asks under an explicit -Confirm.
function Install-AddonFiles {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()

    if (-not $PSCmdlet.ShouldProcess($installPath, "Install $($files.Count) files")) {
        return
    }

    # Built apart, so that a failed copy leaves the current install as it was.
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -Confirm:$false
    }
    foreach ($file in $files) {
        $destination = Join-Path $stagingPath $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force -Confirm:$false | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $destination -Force -Confirm:$false
    }
    if ($existing) {
        Remove-Item -LiteralPath $existing.FullName -Recurse -Force -Confirm:$false
    }
    Rename-Item -LiteralPath $stagingPath -NewName $addonName -Confirm:$false

    Write-Host "$addonName installed: $installPath ($($files.Count) files)"
    if ($existing) {
        Write-Host 'If WoW is open, type /reload. Restart it if the list of files in the .toc changed.'
    }
    else {
        Write-Host 'If WoW is open, restart it: a new addon is only detected at launch.'
    }
}

Install-AddonFiles

# Saved variables ------------------------------------------------------------

if ($Clean) {
    $accountsPath = Join-Path $retailPath 'WTF\Account'
    $files = @(
        Get-ChildItem -LiteralPath $accountsPath -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $savedVariablesPath = Join-Path $_.FullName 'SavedVariables'
            foreach ($name in "$addonName.lua", "$addonName.lua.bak") {
                $file = Join-Path $savedVariablesPath $name
                if (Test-Path -LiteralPath $file -PathType Leaf) {
                    $file
                }
            }
        }
    )

    if ($files.Count -eq 0) {
        Write-Host 'No saved data to delete.'
    }
    elseif ($PSCmdlet.ShouldProcess(($files -join [Environment]::NewLine), 'Delete permanently')) {
        Remove-Item -LiteralPath $files -Force -Confirm:$false
        foreach ($file in $files) {
            Write-Host "Deleted: $file"
        }
    }
    elseif (-not $WhatIfPreference) {
        Write-Host 'Saved data kept.'
    }
}
