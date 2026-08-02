#Requires -Version 5.1
<#
.SYNOPSIS
    Windows installer for devcontainer-mcp (via WSL).
.DESCRIPTION
    Installs the devcontainer-mcp Linux binary inside WSL and configures
    Windows-side MCP clients to use the WSL bridge ("command": "wsl").
.EXAMPLE
    irm https://github.com/aniongithub/devcontainer-mcp/releases/latest/download/install.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = "aniongithub/devcontainer-mcp"
$WslBinaryPath = "~/.local/bin/devcontainer-mcp"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  $([char]0x2713) $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  $([char]0x26A0) $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  $([char]0x2717) $Message" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. Verify WSL is available
# ---------------------------------------------------------------------------

Write-Step "Checking for WSL..."

try {
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL returned non-zero exit code" }
    Write-Ok "WSL is available"
} catch {
    Write-Host ""
    Write-Host "Error: WSL (Windows Subsystem for Linux) is required but not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install WSL with:  wsl --install" -ForegroundColor Yellow
    Write-Host "Then restart your computer and run this script again."
    Write-Host "More info: https://learn.microsoft.com/en-us/windows/wsl/install"
    exit 1
}

# Find usable WSL distros (skip docker-desktop* distros which are minimal)
$WslDistro = $null
$distroLines = (wsl -l -q 2>&1) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$usableDistros = @($distroLines | Where-Object { $_ -notmatch '^docker-desktop' })

if ($usableDistros.Count -eq 0) {
    Write-Host ""
    Write-Host "Error: No usable WSL distro found (docker-desktop is not supported)." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install a Linux distro with:  wsl --install Ubuntu" -ForegroundColor Yellow
    exit 1
} elseif ($usableDistros.Count -eq 1) {
    $WslDistro = $usableDistros[0]
} else {
    Write-Host ""
    Write-Host "Available WSL distros:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $usableDistros.Count; $i++) {
        Write-Host "  [$($i + 1)] $($usableDistros[$i])"
    }
    Write-Host ""
    $choice = Read-Host "Select a distro (1-$($usableDistros.Count))"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $usableDistros.Count) {
        Write-Host "Invalid selection." -ForegroundColor Red
        exit 1
    }
    $WslDistro = $usableDistros[$idx]
}

Write-Ok "Using WSL distro: $WslDistro"

# ---------------------------------------------------------------------------
# 2. Install binary inside WSL
# ---------------------------------------------------------------------------

Write-Step "Installing devcontainer-mcp binary inside WSL..."

$installUrl = "https://raw.githubusercontent.com/$Repo/main/install.sh"
$wslResult = wsl -d $WslDistro bash -c "curl -fsSL '$installUrl' | bash -s -- --skip-mcp-config" 2>&1
$wslResult | ForEach-Object { Write-Host "    $_" }

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Error: Binary installation inside WSL failed." -ForegroundColor Red
    Write-Host "Try running manually in WSL: curl -fsSL $installUrl | bash"
    exit 1
}

# Verify the binary works
$versionCheck = wsl -d $WslDistro bash -lc "$WslBinaryPath --version" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Installed: $($versionCheck.Trim())"
} else {
    Write-Warn "Binary installed but could not verify version"
}

# ---------------------------------------------------------------------------
# 3. Install SKILL.md for Windows-side agent discovery
# ---------------------------------------------------------------------------

Write-Step "Installing SKILL.md for agent discovery..."

$skillUrl = "https://raw.githubusercontent.com/$Repo/main/SKILL.md"
$skillDirs = @(
    "$env:USERPROFILE\.copilot\skills\devcontainer-mcp"
    "$env:USERPROFILE\.claude\skills\devcontainer-mcp"
    "$env:USERPROFILE\.agents\skills\devcontainer-mcp"
    "$env:USERPROFILE\.config\opencode\skills\devcontainer-mcp"
)

foreach ($dir in $skillDirs) {
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Invoke-RestMethod -Uri $skillUrl -OutFile "$dir\SKILL.md"
        Write-Ok $dir
    } catch {
        Write-Warn "Could not write to $dir"
    }
}

# ---------------------------------------------------------------------------
# 3b. Install host-protection hooks
# ---------------------------------------------------------------------------

Write-Step "Installing host-protection hook..."

$hookUrl = "https://raw.githubusercontent.com/$Repo/main/.github/hooks/devcontainer-guard.sh"
$loaderUrl = "https://raw.githubusercontent.com/$Repo/main/.github/hooks/devcontainer-skill-loader.sh"
$WslHookDir = "~/.local/share/devcontainer-mcp/hooks"
$WslHookPath = "$WslHookDir/devcontainer-guard.sh"
$WslLoaderPath = "$WslHookDir/devcontainer-skill-loader.sh"

$hookResult = wsl -d $WslDistro bash -c "mkdir -p '$WslHookDir' && curl -fsSL -o '$WslHookPath' '$hookUrl' && chmod +x '$WslHookPath' && echo OK" 2>&1
if ($hookResult -match "OK") {
    Write-Ok "Guard hook installed in WSL at $WslHookPath"
} else {
    Write-Warn "Could not install guard hook in WSL"
}

$loaderResult = wsl -d $WslDistro bash -c "curl -fsSL -o '$WslLoaderPath' '$loaderUrl' && chmod +x '$WslLoaderPath' && echo OK" 2>&1
if ($loaderResult -match "OK") {
    Write-Ok "Skill-loader hook installed in WSL at $WslLoaderPath"
} else {
    Write-Warn "Could not install skill-loader hook in WSL"
}

# Install SKILL.md alongside hooks for the loader to find
$WslSkillDataPath = "~/.local/share/devcontainer-mcp/SKILL.md"
wsl -d $WslDistro bash -c "curl -fsSL -o '$WslSkillDataPath' '$skillUrl'" 2>&1 | Out-Null

# The host-protection hooks parse their JSON payload with jq inside WSL.
# Without jq the hooks fail open (commands pass through), so protection is
# effectively disabled until jq is installed in the WSL distro.
$jqCheck = wsl -d $WslDistro bash -lc "command -v jq" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "jq (host-protection hooks active)"
} else {
    Write-Fail "jq — hooks INACTIVE until installed — https://jqlang.github.io/jq/download/"
}

# Configure Claude Code PreToolUse + SessionStart hooks (Windows-side)
Write-Step "Configuring agent hooks..."

$claudeSettings = "$env:USERPROFILE\.claude\settings.json"
try {
    $guardEntry = @{
        matcher = "Bash"
        hooks = @(
            @{
                type = "command"
                command = "wsl $WslHookPath"
                timeout = 5
            }
        )
    }
    $loaderEntry = @{
        hooks = @(
            @{
                type = "command"
                command = "wsl $WslLoaderPath"
                timeout = 5
            }
        )
    }

    if (Test-Path $claudeSettings) {
        $content = Get-Content -Raw $claudeSettings | ConvertFrom-Json
        if (-not $content.hooks) {
            $content | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{})
        }

        # PreToolUse: devcontainer-guard
        if (-not $content.hooks.PreToolUse) {
            $content.hooks | Add-Member -NotePropertyName "PreToolUse" -NotePropertyValue @()
        }
        $alreadyGuard = $false
        foreach ($group in $content.hooks.PreToolUse) {
            foreach ($h in $group.hooks) {
                if ($h.command -match "devcontainer-guard") { $alreadyGuard = $true; break }
            }
        }
        if (-not $alreadyGuard) {
            $content.hooks.PreToolUse += [PSCustomObject]$guardEntry
            Write-Ok "Claude Code — added PreToolUse hook"
        } else {
            Write-Ok "Claude Code — PreToolUse hook already configured"
        }

        # SessionStart: skill-loader
        if (-not $content.hooks.SessionStart) {
            $content.hooks | Add-Member -NotePropertyName "SessionStart" -NotePropertyValue @()
        }
        $alreadyLoader = $false
        foreach ($group in $content.hooks.SessionStart) {
            foreach ($h in $group.hooks) {
                if ($h.command -match "skill-loader") { $alreadyLoader = $true; break }
            }
        }
        if (-not $alreadyLoader) {
            $content.hooks.SessionStart += [PSCustomObject]$loaderEntry
            Write-Ok "Claude Code — added SessionStart hook"
        } else {
            Write-Ok "Claude Code — SessionStart hook already configured"
        }

        $content | ConvertTo-Json -Depth 10 | Set-Content $claudeSettings -Encoding UTF8
    } else {
        $dir = Split-Path $claudeSettings -Parent
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $config = [PSCustomObject]@{
            hooks = [PSCustomObject]@{
                PreToolUse = @([PSCustomObject]$guardEntry)
                SessionStart = @([PSCustomObject]$loaderEntry)
            }
        }
        $config | ConvertTo-Json -Depth 10 | Set-Content $claudeSettings -Encoding UTF8
        Write-Ok "Claude Code — created $claudeSettings"
    }
} catch {
    Write-Warn "Claude Code — could not configure hooks"
}

# Configure Copilot CLI preToolUse + sessionStart hooks (Windows-side)
$copilotHooksDir = "$env:USERPROFILE\.copilot\hooks"
try {
    New-Item -ItemType Directory -Path $copilotHooksDir -Force | Out-Null

    $copilotGuard = [PSCustomObject]@{
        version = 1
        hooks = [PSCustomObject]@{
            preToolUse = @(
                [PSCustomObject]@{
                    type = "command"
                    bash = "wsl $WslHookPath"
                    timeoutSec = 5
                }
            )
        }
    }
    $copilotGuard | ConvertTo-Json -Depth 10 | Set-Content "$copilotHooksDir\devcontainer-guard.json" -Encoding UTF8
    Write-Ok "Copilot CLI — created $copilotHooksDir\devcontainer-guard.json"

    $copilotLoader = [PSCustomObject]@{
        version = 1
        hooks = [PSCustomObject]@{
            sessionStart = @(
                [PSCustomObject]@{
                    type = "command"
                    bash = "wsl $WslLoaderPath"
                    timeoutSec = 5
                }
            )
        }
    }
    $copilotLoader | ConvertTo-Json -Depth 10 | Set-Content "$copilotHooksDir\devcontainer-skill-loader.json" -Encoding UTF8
    Write-Ok "Copilot CLI — created $copilotHooksDir\devcontainer-skill-loader.json"
} catch {
    Write-Warn "Copilot CLI — could not configure hooks"
}

# ---------------------------------------------------------------------------
# 4. Detect backend CLIs available in WSL
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Backend CLIs detected in WSL (install as needed — MCP server gives helpful errors if missing):"

$backends = @(
    @{ Name = "devpod";       Url = "https://devpod.sh/docs/getting-started/install" }
    @{ Name = "devcontainer"; Url = "https://github.com/devcontainers/cli#install-script" }
    @{ Name = "gh";           Url = "https://cli.github.com/" }
)

foreach ($b in $backends) {
    $check = wsl -d $WslDistro bash -lc "command -v $($b.Name)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$($b.Name)"
    } else {
        $label = $b.Name
        if ($label -eq "gh") { $label = "gh (codespaces)" }
        Write-Fail "$label — $($b.Url)"
    }
}

# ---------------------------------------------------------------------------
# 5. Configure Windows-side MCP clients (with WSL bridge)
# ---------------------------------------------------------------------------

Write-Step "Configuring MCP clients..."

$mcpServerEntry = @{
    command = "wsl"
    args    = @($WslBinaryPath, "serve")
}

function Set-McpConfig {
    param(
        [string]$ConfigPath,
        [string]$ClientName
    )

    try {
        if (Test-Path $ConfigPath) {
            $content = Get-Content -Raw $ConfigPath | ConvertFrom-Json
            if (-not $content.mcpServers) {
                $content | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
            }
            if ($content.mcpServers.PSObject.Properties.Name -contains "devcontainer-mcp") {
                Write-Ok "$ClientName — already configured"
                return
            }
            $content.mcpServers | Add-Member -NotePropertyName "devcontainer-mcp" -NotePropertyValue ([PSCustomObject]$mcpServerEntry)
            $content | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
            Write-Ok "$ClientName — added to $ConfigPath"
        } else {
            $dir = Split-Path $ConfigPath -Parent
            if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $config = [PSCustomObject]@{
                mcpServers = [PSCustomObject]@{
                    "devcontainer-mcp" = [PSCustomObject]$mcpServerEntry
                }
            }
            $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
            Write-Ok "$ClientName — created $ConfigPath"
        }
    } catch {
        Write-Warn "$ClientName — could not update $ConfigPath"
    }
}

# Claude Code
Set-McpConfig "$env:USERPROFILE\.claude.json" "Claude Code"

# GitHub Copilot (if .copilot dir exists)
if (Test-Path "$env:USERPROFILE\.copilot") {
    Set-McpConfig "$env:USERPROFILE\.copilot\mcp-config.json" "GitHub Copilot"
}

# VS Code (if config dir exists)
$vscodeDir = "$env:APPDATA\Code\User"
if (Test-Path $vscodeDir) {
    Set-McpConfig "$vscodeDir\mcp.json" "VS Code"
}

# Cursor (if installed)
if (Test-Path "$env:USERPROFILE\.cursor") {
    Set-McpConfig "$env:USERPROFILE\.cursor\mcp.json" "Cursor"
}

# opencode — uses a distinct schema (mcp key, type: "local", combined
# command array, enabled: true) and lives at ~/.config/opencode/opencode.json.
function Set-OpencodeMcpConfig {
    $ConfigPath = "$env:USERPROFILE\.config\opencode\opencode.json"
    $opencodeEntry = [PSCustomObject]@{
        type    = "local"
        command = @("wsl", $WslBinaryPath, "serve")
        enabled = $true
    }

    try {
        if (Test-Path $ConfigPath) {
            $content = Get-Content -Raw $ConfigPath | ConvertFrom-Json
            if (-not $content.mcp) {
                $content | Add-Member -NotePropertyName "mcp" -NotePropertyValue ([PSCustomObject]@{})
            }
            if ($content.mcp.PSObject.Properties.Name -contains "devcontainer-mcp") {
                Write-Ok "opencode — already configured"
                return
            }
            $content.mcp | Add-Member -NotePropertyName "devcontainer-mcp" -NotePropertyValue $opencodeEntry
            $content | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
            Write-Ok "opencode — added to $ConfigPath"
        } else {
            $dir = Split-Path $ConfigPath -Parent
            if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $config = [PSCustomObject]@{
                '$schema' = "https://opencode.ai/config.json"
                mcp = [PSCustomObject]@{
                    "devcontainer-mcp" = $opencodeEntry
                }
            }
            $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
            Write-Ok "opencode — created $ConfigPath"
        }
    } catch {
        Write-Warn "opencode — could not update $ConfigPath"
    }
}

Set-OpencodeMcpConfig

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Done! devcontainer-mcp is ready to use." -ForegroundColor Green
Write-Host ""
Write-Host "MCP clients are configured to launch the server via WSL:" -ForegroundColor DarkGray
Write-Host "  command: wsl" -ForegroundColor DarkGray
Write-Host "  args:    [$WslBinaryPath, serve]" -ForegroundColor DarkGray
