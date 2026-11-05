<#
.SYNOPSIS
    Installe l'addon Trading Book dans World of Warcraft (Retail).

.DESCRIPTION
    Copie dans Interface\AddOns le fichier .toc et les fichiers qu'il liste, rien
    d'autre. Le dossier installé est remplacé à chaque fois : après une modification
    du code, relancez le script, puis faites /reload en jeu.

.PARAMETER Clean
    Supprime aussi les données sauvegardées de Trading Book (historique, stock, or) sur
    tous les comptes. Irréversible : une confirmation est demandée, et WoW doit être
    fermé. Ajoutez -Confirm:$false pour ne pas être interrogé.

.PARAMETER WowPath
    Dossier d'installation de World of Warcraft, celui qui contient _retail_.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Clean

.EXAMPLE
    .\install.ps1 -Clean -WhatIf
    Montre ce qui serait fait, sans rien modifier.
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
    throw "$tocName est introuvable à côté de ce script ($PSScriptRoot)."
}
if (-not (Test-Path -LiteralPath $addOnsPath -PathType Container)) {
    throw "World of Warcraft (Retail) est introuvable dans « $WowPath ». Indiquez son dossier avec -WowPath."
}

# Checked before changing anything: the client rewrites saved variables when it
# logs out or reloads, so the deleted data would simply come back.
if ($Clean -and (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)) {
    throw 'WoW est ouvert : fermez-le avant -Clean, sinon il réécrira ses données en quittant. Rien n''a été modifié.'
}

# Installation ---------------------------------------------------------------

# The .toc is the list of what the client loads, so nothing else needs to be installed.
$tocLines = @(Get-Content -LiteralPath $tocPath)
$files = @($tocName) + @($tocLines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw "Fichiers listés dans $tocName mais introuvables : $($missing -join ', '). Rien n'a été modifié."
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
    throw "« $installPath » existe déjà et n'a pas été installé par ce script. Déplacez-le ou supprimez-le, puis relancez le script. Rien n'a été modifié."
}

# A lower impact than the script's: updating the install is routine and loses nothing,
# unlike -Clean, so it only asks under an explicit -Confirm.
function Install-AddonFiles {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()

    if (-not $PSCmdlet.ShouldProcess($installPath, "Installer $($files.Count) fichiers")) {
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

    Write-Host "$addonName installé : $installPath ($($files.Count) fichiers)"
    if ($existing) {
        Write-Host 'Si WoW est ouvert, faites /reload. Redémarrez-le si la liste de fichiers du .toc a changé.'
    }
    else {
        Write-Host 'Si WoW est ouvert, redémarrez-le : un nouvel addon n''est détecté qu''au lancement.'
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
        Write-Host 'Aucune donnée sauvegardée à supprimer.'
    }
    elseif ($PSCmdlet.ShouldProcess(($files -join [Environment]::NewLine), 'Supprimer définitivement')) {
        Remove-Item -LiteralPath $files -Force -Confirm:$false
        foreach ($file in $files) {
            Write-Host "Supprimé : $file"
        }
    }
    elseif (-not $WhatIfPreference) {
        Write-Host 'Données sauvegardées conservées.'
    }
}
