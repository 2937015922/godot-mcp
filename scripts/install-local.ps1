#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectPath,
    [ValidateRange(1, 65535)]
    [int] $Port = 6505,
    [string] $GodotPath,
    [switch] $ConfigureCodex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SectionRange {
    param([string] $Text, [string] $Section)
    $headers = [regex]::Matches($Text, '(?m)^[\t ]*\[([^\]\r\n]+)\][\t ]*(?:[;#][^\r\n]*)?\r?$')
    $components = foreach ($component in $Section.Split('.')) {
        $escapedName = [regex]::Escape($component)
        '(?:' + $escapedName + '|"' + $escapedName + '"|''' + $escapedName + ''')'
    }
    $sectionPattern = '^\s*' + ($components -join '\s*\.\s*') + '\s*$'
    $found = $null
    for ($index = 0; $index -lt $headers.Count; $index++) {
        $name = $headers[$index].Groups[1].Value.Trim()
        # Match case-sensitive TOML components, never the unrelated literal
        # table ["mcp_servers.godot"] or a server named Godot with a capital G.
        if (-not [regex]::IsMatch($name, $sectionPattern)) { continue }
        if ($null -ne $found) { throw "Duplicate [$Section] sections; refusing an ambiguous edit." }
        $end = if ($index + 1 -lt $headers.Count) { $headers[$index + 1].Index } else { $Text.Length }
        $found = @{ Start = $headers[$index].Index; BodyStart = $headers[$index].Index + $headers[$index].Length; End = $end }
    }
    return $found
}

function Get-SettingRange {
    param([string] $Text, [string] $Section, [string] $Key)
    $range = Get-SectionRange $Text $Section
    if ($null -eq $range) { return $null }
    $body = $Text.Substring($range.BodyStart, $range.End - $range.BodyStart)
    $pattern = '(?m)^[\t ]*(?:' + [regex]::Escape($Key) + '|"' + [regex]::Escape($Key) + '"|''' + [regex]::Escape($Key) + ''')[\t ]*=[\t ]*'
    $matches = [regex]::Matches($body, $pattern)
    if ($matches.Count -gt 1) { throw "Duplicate $Key values in [$Section]; refusing an ambiguous edit." }
    if ($matches.Count -eq 0) { return $null }
    $start = $range.BodyStart + $matches[0].Index + $matches[0].Length
    $cursor = $start
    $quote = [char] 0
    $escaped = $false
    $nesting = 0
    # Stop at the logical end of a value, respecting quoted paths and multiline arrays.
    while ($cursor -lt $range.End) {
        $character = $Text[$cursor]
        if ($quote -ne [char] 0) {
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\' -and $quote -eq '"') { $escaped = $true }
            elseif ($character -eq $quote) { $quote = [char] 0 }
        }
        elseif ($character -eq '"' -or $character -eq "'") { $quote = $character }
        elseif ($character -eq '(' -or $character -eq '[' -or $character -eq '{') { $nesting++ }
        elseif ($character -eq ')' -or $character -eq ']' -or $character -eq '}') { $nesting-- }
        elseif ($character -eq ';' -or $character -eq '#') {
            if ($nesting -eq 0) { break }
            $nextLine = $Text.IndexOf("`n", $cursor)
            if ($nextLine -lt 0 -or $nextLine -ge $range.End) { throw "Unterminated $Key value in [$Section]." }
            $cursor = $nextLine + 1
            continue
        }
        elseif (($character -eq "`n" -or $character -eq "`r") -and $nesting -eq 0) { break }
        if ($nesting -lt 0) { throw "Malformed $Key value in [$Section]." }
        $cursor++
    }
    if ($quote -ne [char] 0 -or $nesting -ne 0) { throw "Unterminated $Key value in [$Section]." }
    while ($cursor -gt $start -and [char]::IsWhiteSpace($Text[$cursor - 1])) { $cursor-- }
    return @{ Start = $start; End = $cursor; Value = $Text.Substring($start, $cursor - $start) }
}

function Set-SectionValue {
    param([string] $Text, [string] $Section, [string] $Key, [string] $Value)
    $setting = Get-SettingRange $Text $Section $Key
    if ($null -ne $setting) {
        return $Text.Substring(0, $setting.Start) + $Value + $Text.Substring($setting.End)
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $range = Get-SectionRange $Text $Section
    if ($null -eq $range) {
        $separator = if ($Text.Length -eq 0) { '' } elseif ($Text.EndsWith("`n")) { $newline } else { $newline + $newline }
        return $Text + $separator + '[' + $Section + ']' + $newline + $Key + '=' + $Value + $newline
    }
    $before = $Text.Substring(0, $range.End)
    $separator = if ($before.EndsWith("`n")) { '' } else { $newline }
    return $before + $separator + $Key + '=' + $Value + $newline + $Text.Substring($range.End)
}

function Enable-GodotPlugin {
    param([string] $Text)
    $plugin = '"res://addons/godot_mcp/plugin.cfg"'
    $setting = Get-SettingRange $Text 'editor_plugins' 'enabled'
    if ($null -eq $setting) {
        return Set-SectionValue $Text 'editor_plugins' 'enabled' ('PackedStringArray(' + $plugin + ')')
    }
    $array = $setting.Value
    if ($array -notmatch '^PackedStringArray\s*\([\s\S]*\)$') {
        throw 'editor_plugins/enabled must be a PackedStringArray; no project changes have been made.'
    }
    if ([regex]::IsMatch($array, '"res://addons/godot_mcp/plugin\.cfg"')) { return $Text }
    $open = $array.IndexOf('(')
    $body = $array.Substring($open + 1, $array.Length - $open - 2)
    $separator = if ($body.Trim().Length -eq 0) { '' } else { ', ' }
    $newArray = $array.Substring(0, $open + 1) + $plugin + $separator + $body + ')'
    return Set-SectionValue $Text 'editor_plugins' 'enabled' $newArray
}

function ConvertTo-TomlString {
    param([string] $Value)
    # JSON basic strings use TOML-compatible escapes for filesystem paths.
    return ConvertTo-Json -InputObject $Value -Compress
}

function Update-CodexConfigText {
    param([string] $Text, [string] $NodePath, [string] $ServerPath, [string] $TargetProject, [int] $TargetPort)
    # A narrow text update preserves all unrelated servers, settings and comments.
    # Inline/dotted environment tables need a full TOML editor, so fail before writes.
    if ($null -ne (Get-SettingRange $Text 'mcp_servers.godot' 'env')) {
        throw 'Codex godot env uses an inline table. Convert it to [mcp_servers.godot.env] before using -ConfigureCodex.'
    }
    if ($null -ne (Get-SettingRange $Text 'mcp_servers' 'godot')) {
        throw 'Codex godot uses an inline server table. Convert it to [mcp_servers.godot] before using -ConfigureCodex.'
    }
    if ($Text -match '(?m)^\s*(?:mcp_servers\s*\.\s*godot\s*\.|godot\s*\.\s*(?:command|args|env)|env\s*\.\s*GODOT_MCP_)') {
        throw 'Codex godot configuration uses dotted assignments. Use [mcp_servers.godot] and [mcp_servers.godot.env] tables before using -ConfigureCodex.'
    }
    $updated = Set-SectionValue $Text 'mcp_servers.godot' 'command' (ConvertTo-TomlString $NodePath)
    $updated = Set-SectionValue $updated 'mcp_servers.godot' 'args' (ConvertTo-Json -InputObject @($ServerPath) -Compress)
    $updated = Set-SectionValue $updated 'mcp_servers.godot.env' 'GODOT_MCP_PORT' (ConvertTo-TomlString ([string] $TargetPort))
    return Set-SectionValue $updated 'mcp_servers.godot.env' 'GODOT_MCP_PROJECT' (ConvertTo-TomlString $TargetProject)
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceAddon = Join-Path $repositoryRoot 'addons/godot_mcp'
$serverRoot = Join-Path $repositoryRoot 'server'
$serverEntry = Join-Path $serverRoot 'build/index.js'
$resolvedProject = Resolve-Path -LiteralPath $ProjectPath
if ($resolvedProject.Provider.Name -ne 'FileSystem') { throw 'ProjectPath must point to a local filesystem project.' }
$targetProject = $resolvedProject.ProviderPath
if (Test-Path -LiteralPath $targetProject -PathType Leaf) {
    if ([IO.Path]::GetFileName($targetProject) -ne 'project.godot') { throw 'ProjectPath must be a project folder or project.godot file.' }
    $targetProject = Split-Path -Parent $targetProject
}
$projectFile = Join-Path $targetProject 'project.godot'
if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) { throw 'The target does not contain project.godot.' }
if (-not (Test-Path -LiteralPath (Join-Path $sourceAddon 'plugin.cfg') -PathType Leaf)) { throw 'Cannot find the repository Godot addon.' }
if (-not (Test-Path -LiteralPath (Join-Path $serverRoot 'package-lock.json') -PathType Leaf)) { throw 'Cannot find server/package-lock.json.' }
$targetAddon = Join-Path $targetProject 'addons/godot_mcp'
if ([IO.Path]::GetFullPath($targetAddon) -eq [IO.Path]::GetFullPath($sourceAddon)) { throw 'The source addon cannot also be the installation target.' }

$nodeCommand = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$npmCommand = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $npmCommand) { $npmCommand = Get-Command npm -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
$nodeExecutable = $nodeCommand.Source
$nodeVersion = & $nodeExecutable --version
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(\d+)\.' -or [int] $Matches[1] -lt 18) { throw 'Node.js 18 or later is required.' }

if ($GodotPath) {
    $godotExecutable = (Resolve-Path -LiteralPath $GodotPath).ProviderPath
    if (-not (Test-Path -LiteralPath $godotExecutable -PathType Leaf)) { throw 'GodotPath must point to the Godot executable.' }
    $godotVersion = & $godotExecutable --version
    if ($LASTEXITCODE -ne 0 -or ($godotVersion -join '') -notmatch '^4\.') { throw 'GodotPath must be a working Godot 4 executable.' }
    Write-Host ('Godot version: ' + ($godotVersion -join '').Trim())
}

$originalProjectText = [IO.File]::ReadAllText($projectFile)
if ($originalProjectText -notmatch '(?m)^\s*config_version\s*=\s*5\s*(?:;[^\r\n]*)?\r?$') { throw 'Expected a Godot 4 project.godot with config_version=5.' }
$updatedProjectText = Enable-GodotPlugin $originalProjectText
$updatedProjectText = Set-SectionValue $updatedProjectText 'godot_mcp' 'network/port' ([string] $Port)

$codexConfigFile = $null
$originalCodexText = $null
$updatedCodexText = $null
if ($ConfigureCodex) {
    $codexConfigDirectory = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    $codexConfigFile = Join-Path $codexConfigDirectory 'config.toml'
    $originalCodexText = if (Test-Path -LiteralPath $codexConfigFile -PathType Leaf) { [IO.File]::ReadAllText($codexConfigFile) } else { '' }
    $updatedCodexText = Update-CodexConfigText $originalCodexText $nodeExecutable $serverEntry $targetProject $Port
}

# Build before touching the target project or Codex configuration. Dependency
# verification compares the npm lock to installed versions/integrities and files.
$dependencyCheck = @'
const fs = require('node:fs');
try {
  const wanted = JSON.parse(fs.readFileSync('package-lock.json', 'utf8')).packages;
  const installed = JSON.parse(fs.readFileSync('node_modules/.package-lock.json', 'utf8')).packages;
  if (!wanted || !installed) process.exit(2);
  for (const [name, spec] of Object.entries(wanted)) {
    if (!name) continue;
    const actual = installed[name];
    if (spec.optional && !actual) continue;
    if (!actual || actual.version !== spec.version || actual.integrity !== spec.integrity || !fs.existsSync(name + '/package.json')) process.exit(2);
  }
} catch { process.exit(2); }
'@
Push-Location -LiteralPath $serverRoot
try {
    & $nodeExecutable -e $dependencyCheck
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Installing locked server dependencies without lifecycle scripts...'
        & $npmCommand.Source ci --ignore-scripts --no-audit --no-fund --include=dev
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed; target project and Codex configuration were not changed.' }
    }
    Write-Host 'Building the MCP server...'
    & $npmCommand.Source run build
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $serverEntry -PathType Leaf)) { throw 'Server build failed; target project and Codex configuration were not changed.' }
}
finally { Pop-Location }

# Refuse to overwrite an editor/user change made while npm was running.
if ([IO.File]::ReadAllText($projectFile) -cne $originalProjectText) { throw 'project.godot changed during the build. Run the installer again against its latest content.' }
if ($ConfigureCodex) {
    $currentCodexText = if (Test-Path -LiteralPath $codexConfigFile -PathType Leaf) { [IO.File]::ReadAllText($codexConfigFile) } else { '' }
    if ($currentCodexText -cne $originalCodexText) { throw 'Codex config.toml changed during the build. Run the installer again against its latest content.' }
}

$backupId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Join-Path $repositoryRoot ('.local/backups/' + $backupId)
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Copy-Item -LiteralPath $projectFile -Destination (Join-Path $backupRoot 'project.godot')
if (Test-Path -LiteralPath $targetAddon -PathType Container) {
    $addonBackupParent = Join-Path $backupRoot 'addons'
    New-Item -ItemType Directory -Path $addonBackupParent -Force | Out-Null
    Copy-Item -LiteralPath $targetAddon -Destination $addonBackupParent -Recurse
}

# Codex backups may contain other servers' secrets and must stay beside config.toml.
if ($ConfigureCodex -and (Test-Path -LiteralPath $codexConfigFile -PathType Leaf)) {
    Copy-Item -LiteralPath $codexConfigFile -Destination ($codexConfigFile + '.godot-mcp-backup-' + $backupId)
}
$targetAddonParent = Join-Path $targetProject 'addons'
New-Item -ItemType Directory -Path $targetAddonParent -Force | Out-Null
Copy-Item -LiteralPath $sourceAddon -Destination $targetAddonParent -Recurse -Force
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($projectFile, $updatedProjectText, $utf8)
if ($ConfigureCodex) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $codexConfigFile) -Force | Out-Null
    [IO.File]::WriteAllText($codexConfigFile, $updatedCodexText, $utf8)
}

Write-Host ('Installed Godot MCP 0.2 in: ' + $targetProject)
Write-Host ('Editor port: ' + $Port)
Write-Host ('Project/addon backup: ' + $backupRoot)
if ($ConfigureCodex) {
    Write-Host 'Updated only the Codex godot MCP command, arguments and project/port environment values.'
    Write-Host 'Any previous Codex configuration was backed up beside config.toml.'
    Write-Host 'Restart the Codex MCP connection and reopen the Godot project to load the new plugin.'
}
else {
    Write-Host ('Server entry: ' + $serverEntry)
    Write-Host 'Use -ConfigureCodex to configure this server and project for Codex.'
    Write-Host 'Reopen the Godot project to load the new plugin.'
}
Write-Host 'An existing GODOT_MCP_PORT in the editor process environment overrides the saved project port.'
