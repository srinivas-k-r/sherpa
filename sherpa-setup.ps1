#requires -Version 5.1
<#
  sherpa-setup.ps1
  ---------------------------------------------------------------------------
  One interactive script to bootstrap a dev machine on Windows PowerShell.

  Run from PowerShell:
    Set-ExecutionPolicy -Scope Process Bypass
    .\sherpa-setup.ps1

  Flow:
    1. GATHER   - ask every question up front; no installs.
    2. PLAN     - show exactly what will happen and ask for confirmation.
    3. EXECUTE  - perform installs and print OK / SKIPPED / FAILED.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# =============================================================================
# Config & globals
# =============================================================================

$Platform = "windows"

$ProfileFile = ""
$ProfileMode = $false
$ProfileName = ""
$NodeVersion = "lts"
$PythonVersion = "3.12.4"
$GitSshSetup = $false
$CloneRepos = @()

$GitAlreadyInstalled = $false
$GitWantInstall = $false

$IdeChoice = 3 # 0=Zed 1=VSCode 2=Both 3=Skip
$WantVsCodeExtensions = $false

$NodeChoice = 2 # 0=nvm 1=direct 2=skip
$PkgManagerChoice = 0 # 0=npm 1=pnpm 2=yarn

$PythonChoice = 2 # 0=pyenv 1=direct 2=skip

$WantGhCli = $false
$WantDocker = $false
$WantPostman = $false
$WantChrome = $false
$WantFirefox = $false
$WantJq = $false
$WantStarship = $false

$GitConfigNeeded = $false
$GitConfigName = ""
$GitConfigEmail = ""

$WantClone = $false
$CloneUrlsRaw = ""
$CloneDir = ""

$PlanLines = [System.Collections.Generic.List[string]]::new()
$Summary = [System.Collections.Generic.List[object]]::new()
$NextSteps = [System.Collections.Generic.List[string]]::new()

# =============================================================================
# UI helpers
# =============================================================================

$Esc = [char]27
$Yellow = "$Esc[0;33m"
$Green = "$Esc[0;32m"
$Red = "$Esc[0;31m"
$Magenta = "$Esc[0;35m"
$Gray = "$Esc[0;90m"
$Cyan = "$Esc[0;36m"
$Bold = "$Esc[1m"
$NC = "$Esc[0m"

$MountainFacts = @(
    "Mount Everest grows about 4mm taller every year as the Indian and Eurasian tectonic plates keep colliding."
    "The summit of Mount Everest is Earth's highest point, but Mauna Kea in Hawaii is taller base-to-peak -- most of it is just underwater."
    "'Sherpa' is actually an ethnic group native to the Himalayas, renowned as high-altitude mountaineering guides."
    "K2 is nicknamed the 'Savage Mountain' -- it's shorter than Everest but far deadlier to climb."
    "Tenzing Norgay and Edmund Hillary were the first confirmed climbers to summit Everest, in 1953."
    "The Andes is the longest continental mountain range on Earth, running about 7,000 km down South America."
    "Olympus Mons on Mars is the tallest known mountain in the solar system -- about 2.5x the height of Everest."
    "Above 8,000m is called the 'death zone': there's so little oxygen that the body can no longer acclimatize, only deteriorate."
    "The Alps were formed by the same collision that's still pushing the Himalayas up today, just tens of millions of years earlier."
    "Denali in Alaska has one of the greatest base-to-peak rises of any mountain on land, taller in that sense than Everest."
    "Kilimanjaro is a free-standing volcanic mountain -- it isn't part of any mountain range."
    "Some Sherpas have made 20+ Everest summits; Kami Rita Sherpa holds the record with over two dozen."
)

function Write-Banner {
    Write-Host ""
    $flags = ""
    $flagChars = @(
        "$Esc[0;34m▽$NC", "$Esc[1;37m▽$NC", "$Esc[0;31m▽$NC",
        "$Esc[0;32m▽$NC", "$Esc[1;33m▽$NC"
    )
    for ($i = 0; $i -lt 16; $i++) { $flags += $flagChars[$i % 5] }
    Write-Host "$Gray   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾$NC"
    Write-Host "   $flags"
    Write-Host "$Cyan"
    @"
                      /\
                     /  \
                    /    \
                   /      \
                  /   /\   \
                 /   /  \   \
                /   /    \   \
               /___/      \___\
"@
    Write-Host "$NC"
    Write-Host "$Cyan$Bold                  S H E R P A$NC"
    Write-Host "$Gray           let me carry the heavy gear$NC"
    Write-Host ""
    $fact = Get-Random -InputObject $MountainFacts
    Write-Host "$Yellow" -NoNewline
    Write-Host "Mountain fact:" -NoNewline
    Write-Host "$NC $fact"
    Write-Host ""
}

function Step($Message) { Write-Host "$Yellow>> $Message$NC" }
function Ok($Message) { Write-Host "$Green   [OK] $Message$NC" }
function Skip($Message) { Write-Host "$Gray   [SKIP] $Message$NC" }
function Fail($Message) { Write-Host "$Red   [FAILED] $Message$NC" }
function Add-PlanLine($Message) { [void]$PlanLines.Add($Message) }
function Add-Summary($Name, $Status, $Version = "-", $Notes = "-") {
    [void]$Summary.Add([pscustomobject]@{
        TOOL = $Name; STATUS = $Status; VERSION = $Version; NOTES = $Notes
    })
}

function Ask-YesNo($Question, $Default = "y") {
    $suffix = if ($Default -eq "n") { "[y/N]" } else { "[Y/n]" }
    while ($true) {
        $raw = Read-Host "? $Question $suffix"
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $Default }
        if ($raw -match '^[Yy]') { return $true }
        if ($raw -match '^[Nn]') { return $false }
        Write-Host "$Red  Please answer Y or N.$NC"
    }
}

function Ask-Text($Prompt, $Default = "") {
    if ($Default) {
        $raw = Read-Host "  $Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return $raw
    }
    return Read-Host "  $Prompt"
}

function Select-Menu($Prompt, [string[]]$Options) {
    Write-Host ""
    Write-Host "$Magenta? $Prompt$NC"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  $($i + 1)) $($Options[$i])"
    }
    while ($true) {
        $raw = Read-Host "  Enter choice (1-$($Options.Count))"
        $choice = 0
        if ([int]::TryParse($raw, [ref]$choice) -and
            $choice -ge 1 -and $choice -le $Options.Count) {
            return ($choice - 1)
        }
        Write-Host "$Red  Please enter a number between 1 and $($Options.Count).$NC"
    }
}

function Print-Plan-And-Confirm {
    Write-Host ""
    Write-Host "$Cyan=================== Plan =====================$NC"
    Write-Host "Here's what I'm about to do:"
    foreach ($line in $PlanLines) { Write-Host "  - $line" }
    Write-Host "$Cyan================================================$NC"
    Write-Host ""
    if (-not (Ask-YesNo "Proceed?" "y")) {
        Write-Host "$Gray`nNothing was installed. Exiting.$NC"
        exit 0
    }
}

function Print-Summary {
    Write-Host ""
    Write-Host "$Green=================== Summary ====================$NC"
    $Summary | Format-Table -Property TOOL, STATUS, VERSION, NOTES -AutoSize | Out-Host
    Write-Host "$Green==================================================$NC"
    Write-Host ""
    if ($NextSteps.Count -gt 0) {
        Write-Host "$Bold" -NoNewline
        Write-Host "Next steps:$NC"
        foreach ($n in $NextSteps) { Write-Host "  - $n" }
        Write-Host ""
    }
}

function Show-Usage {
    @"
Usage: .\sherpa-setup.ps1 [options]

Options:
  -Profile <file>   Read stack from a sherpa.yml profile (skips the wizard)
  -Help             Show this help

Examples:
  .\sherpa-setup.ps1
  .\sherpa-setup.ps1 -Profile sherpa.yml
"@
}

function Parse-Args {
    param([string[]]$Args)
    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            "-Profile" {
                if ($i + 1 -ge $Args.Count) {
                    Write-Host "$Red-Profile requires a file path.$NC"
                    exit 1
                }
                $script:ProfileFile = $Args[$i + 1]
                $script:ProfileMode = $true
                $i++
            }
            { $_ -in @("-Help", "-h", "--help") } {
                Show-Usage
                exit 0
            }
            default {
                Write-Host "$RedUnknown option: $($Args[$i])$NC"
                Show-Usage
                exit 1
            }
        }
    }
}

function Expand-HomePath($Path) {
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~/")) { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

function Resolve-RepoUrl($Repo) {
    if ($Repo -match '^(git@|https?://)') { return $Repo }
    if ($Repo -match '/') { return "git@github.com:$Repo.git" }
    return $Repo
}

function Load-Profile {
    $parser = Join-Path $ScriptDir "sherpa-profile.py"
    if (-not (Test-Path $ProfileFile)) {
        Write-Host "$RedProfile not found: $ProfileFile$NC"
        exit 1
    }
    if (-not (Test-Path $parser)) {
        Write-Host "$RedProfile parser not found: $parser$NC"
        Write-Host "Make sure sherpa-profile.py sits next to sherpa-setup.ps1."
        exit 1
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
        -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
        Write-Host "$Redpython is required to read profile files.$NC"
        exit 1
    }
    $python = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "python3" }
    $output = & $python $parser $ProfileFile powershell 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$RedFailed to parse profile: $ProfileFile$NC"
        Write-Host $output
        exit 1
    }
    foreach ($line in $output) {
        if ($line) { Invoke-Expression $line }
    }
    $script:CloneDir = Expand-HomePath $CloneDir
}

function Add-PlanFromProfile {
    Add-PlanLine "Profile: $ProfileName (from $(Split-Path -Leaf $ProfileFile))"

    if (Has-Command "git") {
        $script:GitAlreadyInstalled = $true
        Add-PlanLine "Git: already installed ($(Get-Version git))"
    } else {
        $script:GitWantInstall = $true
        Add-PlanLine "Git: install"
    }

    switch ($IdeChoice) {
        0 { Add-PlanLine "IDE: install Zed" }
        1 { Add-PlanLine "IDE: install VS Code" }
        2 { Add-PlanLine "IDE: install Zed and VS Code" }
        3 { Add-PlanLine "IDE: skip" }
    }
    if ($IdeChoice -in @(1, 2)) {
        if ($WantVsCodeExtensions) { Add-PlanLine "VS Code extensions: install Prettier, ESLint, GitLens" }
        else { Add-PlanLine "VS Code extensions: skip" }
    }

    switch ($NodeChoice) {
        0 { Add-PlanLine "Node.js: install via nvm-windows (version: $NodeVersion)" }
        1 { Add-PlanLine "Node.js: install LTS directly" }
        2 { Add-PlanLine "Node.js: skip" }
    }
    switch ($PkgManagerChoice) {
        0 { Add-PlanLine "Package manager: npm" }
        1 { Add-PlanLine "Package manager: pnpm" }
        2 { Add-PlanLine "Package manager: yarn" }
    }
    switch ($PythonChoice) {
        0 { Add-PlanLine "Python: install via pyenv-win (version: $PythonVersion)" }
        1 { Add-PlanLine "Python: install directly" }
        2 { Add-PlanLine "Python: skip" }
    }

    if ($WantGhCli) { Add-PlanLine "GitHub CLI: install" } else { Add-PlanLine "GitHub CLI: skip" }
    if ($WantDocker) { Add-PlanLine "Docker Desktop: install" } else { Add-PlanLine "Docker Desktop: skip" }
    if ($WantPostman) { Add-PlanLine "Postman: install" } else { Add-PlanLine "Postman: skip" }
    if ($WantChrome) { Add-PlanLine "Chrome: install" } else { Add-PlanLine "Chrome: skip" }
    if ($WantFirefox) { Add-PlanLine "Firefox: install" } else { Add-PlanLine "Firefox: skip" }
    if ($WantJq) { Add-PlanLine "jq: install" } else { Add-PlanLine "jq: skip" }
    if ($WantStarship) { Add-PlanLine "Starship prompt: install" } else { Add-PlanLine "Starship prompt: skip" }

    $name = ""
    $email = ""
    if (Has-Command "git") {
        $name = (& git config --global user.name 2>$null)
        $email = (& git config --global user.email 2>$null)
    }
    if ($name -and $email) { Add-PlanLine "git config: already set ($name <$email>)" }
    else { Add-PlanLine "git config: prompt for user.name / user.email" }

    if ($GitSshSetup) { Add-PlanLine "SSH: generate key if needed, upload to GitHub via gh (terminal only)" }
    else { Add-PlanLine "SSH: skip" }

    if ($WantClone) {
        Add-PlanLine "Clone repo(s) into $CloneDir`:"
        foreach ($repo in $CloneRepos) {
            Add-PlanLine "  - $(Resolve-RepoUrl $repo)"
        }
    } else {
        Add-PlanLine "Clone repo(s): skip"
    }
}

function Gather-GitConfigInteractive {
    $name = ""
    $email = ""
    if (Has-Command "git") {
        $name = (& git config --global user.name 2>$null)
        $email = (& git config --global user.email 2>$null)
    }
    if ($name -and $email) { return }
    if ($ProfileMode -or (Ask-YesNo "git user.name/email isn't fully set. Set it now?" "y")) {
        $script:GitConfigNeeded = $true
        if (-not $name) { $name = Ask-Text "Your name for git commits" }
        if (-not $email) { $email = Ask-Text "Your email for git commits" }
        $script:GitConfigName = $name
        $script:GitConfigEmail = $email
        if (-not $ProfileMode) { Add-PlanLine "git config: set user.name/email to $name <$email>" }
    } elseif (-not $ProfileMode) {
        Add-PlanLine "git config: leave as-is"
    }
}

# =============================================================================
# Platform helpers
# =============================================================================

function Has-Command($Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-Version($CommandName) {
    if (-not (Has-Command $CommandName)) { return "" }
    try {
        $result = & $CommandName --version 2>&1 | Select-Object -First 1
        return ([string]$result).Trim()
    } catch { return "" }
}

function Ensure-Winget {
    Step "Checking winget..."
    if (Has-Command "winget") {
        Ok "winget is available."
        return
    }
    Fail "winget not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
    exit 1
}

function Install-WingetPackage($Id) {
    & winget install --id $Id -e --accept-source-agreements --accept-package-agreements
    return ($LASTEXITCODE -eq 0)
}

function Open-Url($Url) {
    try { Start-Process $Url | Out-Null } catch {}
}

function Copy-ToClipboard($Text) {
    try {
        Set-Clipboard -Value $Text
        return $true
    } catch {
        try {
            $Text | clip.exe
            return ($LASTEXITCODE -eq 0)
        } catch { return $false }
    }
}

# =============================================================================
# GATHER phase -- no installs
# =============================================================================

function Gather-Git {
    if (Has-Command "git") {
        $script:GitAlreadyInstalled = $true
        Add-PlanLine "Git: already installed ($(Get-Version git)) -- nothing to do"
    } elseif (Ask-YesNo "Git isn't installed. Install it?") {
        $script:GitWantInstall = $true
        Add-PlanLine "Git: install"
    } else {
        Add-PlanLine "Git: skip (you said no)"
    }
}

function Gather-IDE {
    $script:IdeChoice = Select-Menu "Which IDE would you like to install?" @(
        "Zed (fast, Rust-based, built-in AI)"
        "VS Code (most popular, huge extension ecosystem)"
        "Both"
        "Skip"
    )
    switch ($IdeChoice) {
        0 { Add-PlanLine "IDE: install Zed" }
        1 { Add-PlanLine "IDE: install VS Code" }
        2 { Add-PlanLine "IDE: install Zed and VS Code" }
        3 { Add-PlanLine "IDE: skip" }
    }

    if ($IdeChoice -in @(1,2)) {
        if (Ask-YesNo "Install a starter VS Code extension pack (Prettier, ESLint, GitLens)?" "y") {
            $script:WantVsCodeExtensions = $true
            Add-PlanLine "VS Code extensions: install Prettier, ESLint, GitLens"
        } else {
            Add-PlanLine "VS Code extensions: skip"
        }
    }
}

function Gather-Node {
    $script:NodeChoice = Select-Menu "How would you like to install Node.js?" @(
        "nvm-windows (switch Node versions later - recommended)"
        "Direct install (latest LTS)"
        "Skip Node.js"
    )
    switch ($NodeChoice) {
        0 { Add-PlanLine "Node.js: install via nvm-windows" }
        1 { Add-PlanLine "Node.js: install LTS directly" }
        2 { Add-PlanLine "Node.js: skip" }
    }
    Gather-PackageManager
}

function Gather-PackageManager {
    if ($NodeChoice -eq 2 -and -not (Has-Command "node")) {
        Add-PlanLine "Package manager: skip (no Node.js)"
        return
    }
    $script:PkgManagerChoice = Select-Menu "Which package manager would you like as your default?" @(
        "npm (ships with Node, simplest)"
        "pnpm (fast, disk-efficient -- common on modern JS projects)"
        "yarn (classic alternative)"
    )
    switch ($PkgManagerChoice) {
        0 { Add-PlanLine "Package manager: npm (no extra setup)" }
        1 { Add-PlanLine "Package manager: pnpm (enabled via Corepack)" }
        2 { Add-PlanLine "Package manager: yarn (enabled via Corepack)" }
    }
}

function Gather-Python {
    $script:PythonChoice = Select-Menu "How would you like to install Python?" @(
        "pyenv-win (switch Python versions later - recommended)"
        "Direct install (latest 3.x)"
        "Skip Python"
    )
    switch ($PythonChoice) {
        0 { Add-PlanLine "Python: install via pyenv-win" }
        1 { Add-PlanLine "Python: install 3.x directly" }
        2 { Add-PlanLine "Python: skip" }
    }
}

function Gather-Extras {
    Write-Host "`nA couple of optional extras:"
    if (Ask-YesNo "Install GitHub CLI (gh)?" "y") {
        $script:WantGhCli = $true; Add-PlanLine "GitHub CLI: install"
    } else { Add-PlanLine "GitHub CLI: skip" }

    if (Ask-YesNo "Install Docker Desktop?" "n") {
        $script:WantDocker = $true; Add-PlanLine "Docker Desktop: install"
    } else { Add-PlanLine "Docker Desktop: skip" }

    if (Ask-YesNo "Install Postman?" "y") {
        $script:WantPostman = $true; Add-PlanLine "Postman: install"
    } else { Add-PlanLine "Postman: skip" }

    if (Ask-YesNo "Install Chrome?" "y") {
        $script:WantChrome = $true; Add-PlanLine "Chrome: install"
    } else { Add-PlanLine "Chrome: skip" }

    if (Ask-YesNo "Install Firefox?" "n") {
        $script:WantFirefox = $true; Add-PlanLine "Firefox: install"
    } else { Add-PlanLine "Firefox: skip" }

    if (Ask-YesNo "Install jq (JSON CLI tool)?" "y") {
        $script:WantJq = $true; Add-PlanLine "jq: install"
    } else { Add-PlanLine "jq: skip" }

    if (Ask-YesNo "Install Starship (fast, cross-shell prompt)?" "y") {
        $script:WantStarship = $true; Add-PlanLine "Starship prompt: install"
    } else { Add-PlanLine "Starship prompt: skip" }
}

function Gather-GitConfig {
    $name = ""
    $email = ""
    if (Has-Command "git") {
        $name = (& git config --global user.name 2>$null)
        $email = (& git config --global user.email 2>$null)
    }
    if ($name -and $email) {
        Add-PlanLine "git config: already set ($name <$email>)"
        return
    }
    if (Ask-YesNo "git user.name/email isn't fully set. Set it now?" "y") {
        $script:GitConfigNeeded = $true
        if (-not $name) { $name = Ask-Text "Your name for git commits" }
        if (-not $email) { $email = Ask-Text "Your email for git commits" }
        $script:GitConfigName = $name
        $script:GitConfigEmail = $email
        Add-PlanLine "git config: set user.name/email to $name <$email>"
    } else { Add-PlanLine "git config: leave as-is" }
}

function Gather-SshSetup {
    if ($ProfileMode) { return }
    if (Ask-YesNo "Set up SSH for GitHub (generate key + upload via gh, no browser)?" "n") {
        $script:GitSshSetup = $true
        $script:WantGhCli = $true
        Add-PlanLine "SSH: generate key if needed, upload to GitHub via gh (terminal only)"
    } else {
        Add-PlanLine "SSH: skip"
    }
}

function Gather-CloneRepos {
    if (Ask-YesNo "Clone a repo now?" "n") {
        $script:CloneUrlsRaw = Ask-Text "Repo URL(s), comma-separated" ""
        if (-not $CloneUrlsRaw) {
            Add-PlanLine "Clone repo(s): skip (no URL entered)"
            return
        }
        $script:CloneDir = Ask-Text "Parent folder to clone into" (Join-Path $HOME "dev")
        $script:WantClone = $true
        Add-PlanLine "Clone repo(s) into $CloneDir`: $CloneUrlsRaw"
    } else { Add-PlanLine "Clone repo(s): skip" }
}

# =============================================================================
# EXECUTE phase
# =============================================================================

function Execute-Git {
    if ($GitAlreadyInstalled) {
        Add-Summary "Git" "OK" (Get-Version git) "already installed"; return
    }
    if (-not $GitWantInstall) {
        Add-Summary "Git" "SKIPPED" "-" "user chose Skip"; return
    }
    Step "Git..."
    if (Install-WingetPackage "Git.Git") {
        Ok "Git installed."
        Add-Summary "Git" "OK" (Get-Version git) "newly installed"
    } else {
        Fail "Git install failed."
        Add-Summary "Git" "FAILED" "-" "install command failed"
    }
}

function Install-VsCodeExtensions {
    if (-not $WantVsCodeExtensions) {
        Add-Summary "VS Code extensions" "SKIPPED" "-" "user chose Skip"; return
    }
    Step "VS Code starter extensions..."
    if (-not (Has-Command "code")) {
        Skip "'code' CLI not on PATH yet -- can't install extensions this run."
        Add-Summary "VS Code extensions" "SKIPPED" "-" "code CLI not on PATH"
        [void]$NextSteps.Add("After reopening your terminal, run: code --install-extension esbenp.prettier-vscode; code --install-extension dbaeumer.vscode-eslint; code --install-extension eamodio.gitlens")
        return
    }
    $extensions = @(
        "esbenp.prettier-vscode"
        "dbaeumer.vscode-eslint"
        "eamodio.gitlens"
    )
    $failed = 0
    foreach ($ext in $extensions) {
        & code --install-extension $ext --force *> $null
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    if ($failed -eq 0) {
        Ok "Prettier, ESLint, GitLens installed."
        Add-Summary "VS Code extensions" "OK" "-" "Prettier, ESLint, GitLens"
    } else {
        Fail "$failed of $($extensions.Count) extension(s) failed to install."
        Add-Summary "VS Code extensions" "FAILED" "-" "$failed of $($extensions.Count) failed"
    }
}

function Execute-IDE {
    function Install-IDE($FriendlyName, $WingetId) {
        Step "$FriendlyName..."
        if (Install-WingetPackage $WingetId) {
            Ok "$FriendlyName installed."
            Add-Summary $FriendlyName "OK" "-" "newly installed"
        } else {
            Fail "$FriendlyName install failed."
            Add-Summary $FriendlyName "FAILED" "-" "install command failed"
        }
    }

    switch ($IdeChoice) {
        0 { Install-IDE "Zed" "ZedIndustries.Zed" }
        1 {
            Install-IDE "VS Code" "Microsoft.VisualStudioCode"
            Install-VsCodeExtensions
        }
        2 {
            Install-IDE "Zed" "ZedIndustries.Zed"
            Install-IDE "VS Code" "Microsoft.VisualStudioCode"
            Install-VsCodeExtensions
        }
        3 { Add-Summary "IDE" "SKIPPED" "-" "user chose Skip" }
    }
}

function Execute-Node {
    switch ($NodeChoice) {
        0 {
            Step "nvm-windows..."
            if (Has-Command "nvm") {
                Skip "nvm-windows already installed."
                Add-Summary "nvm-windows" "OK" "-" "already installed"
            } elseif (Install-WingetPackage "CoreyButler.NVMforWindows") {
                Ok "nvm-windows installed."
                Add-Summary "nvm-windows" "OK" "-" "newly installed"
                [void]$NextSteps.Add("Open a NEW terminal, then: nvm install lts && nvm use lts")
            } else {
                Fail "nvm-windows install failed."
                Add-Summary "nvm-windows" "FAILED" "-" "install command failed"
            }
        }
        1 {
            Step "Node.js LTS..."
            if (Install-WingetPackage "OpenJS.NodeJS.LTS") {
                Ok "Node.js LTS installed."
                Add-Summary "Node.js" "OK" (Get-Version node) "newly installed"
            } else {
                Fail "Node.js install failed."
                Add-Summary "Node.js" "FAILED" "-" "install command failed"
            }
        }
        2 { Add-Summary "Node.js" "SKIPPED" "-" "user chose Skip" }
    }
}

function Execute-PackageManager {
    switch ($PkgManagerChoice) {
        0 { Add-Summary "Package manager" "OK" "npm" "using npm (default)" }
        1 {
            Step "pnpm via Corepack..."
            if (-not (Has-Command "node")) {
                Fail "Node.js not found -- can't enable Corepack."
                Add-Summary "pnpm" "FAILED" "-" "Node.js not installed"
            } else {
                & corepack enable *> $null
                $enableOk = ($LASTEXITCODE -eq 0)
                if ($enableOk) {
                    & corepack prepare pnpm@latest --activate *> $null
                    $enableOk = ($LASTEXITCODE -eq 0)
                }
                if ($enableOk) {
                    Ok "pnpm activated via Corepack."
                    Add-Summary "pnpm" "OK" (Get-Version pnpm) "activated via Corepack"
                    [void]$NextSteps.Add("Open a new terminal, then: pnpm --version")
                } else {
                    Fail "Corepack/pnpm setup failed."
                    Add-Summary "pnpm" "FAILED" "-" "Corepack command failed"
                }
            }
        }
        2 {
            Step "yarn via Corepack..."
            if (-not (Has-Command "node")) {
                Fail "Node.js not found -- can't enable Corepack."
                Add-Summary "yarn" "FAILED" "-" "Node.js not installed"
            } else {
                & corepack enable *> $null
                $enableOk = ($LASTEXITCODE -eq 0)
                if ($enableOk) {
                    & corepack prepare yarn@stable --activate *> $null
                    $enableOk = ($LASTEXITCODE -eq 0)
                }
                if ($enableOk) {
                    Ok "yarn activated via Corepack."
                    Add-Summary "yarn" "OK" (Get-Version yarn) "activated via Corepack"
                    [void]$NextSteps.Add("Open a new terminal, then: yarn --version")
                } else {
                    Fail "Corepack/yarn setup failed."
                    Add-Summary "yarn" "FAILED" "-" "Corepack command failed"
                }
            }
        }
    }
}

function Execute-Python {
    switch ($PythonChoice) {
        0 {
            Step "pyenv-win..."
            if (Has-Command "pyenv") {
                Skip "pyenv-win already installed."
                Add-Summary "pyenv-win" "OK" "-" "already installed"
            } else {
                try {
                    $installer = Join-Path $env:TEMP "install-pyenv-win.ps1"
                    Invoke-WebRequest -UseBasicParsing `
                        -Uri "https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1" `
                        -OutFile $installer
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
                    if ($LASTEXITCODE -eq 0) {
                        Ok "pyenv-win installed."
                        Add-Summary "pyenv-win" "OK" "-" "newly installed"
                        [void]$NextSteps.Add("Open a NEW terminal, then: pyenv install 3.12.4 && pyenv global 3.12.4")
                    } else { throw "installer returned exit code $LASTEXITCODE" }
                } catch {
                    Fail "pyenv-win install failed."
                    Add-Summary "pyenv-win" "FAILED" "-" "install command failed"
                }
            }
        }
        1 {
            Step "Python 3..."
            if (Install-WingetPackage "Python.Python.3.12") {
                Ok "Python installed."
                $pythonCmd = if (Has-Command "python") { "python" } else { "python3" }
                Add-Summary "Python" "OK" (Get-Version $pythonCmd) "newly installed"
            } else {
                Fail "Python install failed."
                Add-Summary "Python" "FAILED" "-" "install command failed"
            }
        }
        2 { Add-Summary "Python" "SKIPPED" "-" "user chose Skip" }
    }
}

function Execute-ExtraCli($Friendly, $Want, $WingetId, $CommandName) {
    if (-not $Want) {
        Add-Summary $Friendly "SKIPPED" "-" "user chose Skip"; return
    }
    Step "$Friendly..."
    if (Has-Command $CommandName) {
        Skip "$Friendly already installed."
        Add-Summary $Friendly "OK" (Get-Version $CommandName) "already installed"
        return
    }
    if (Install-WingetPackage $WingetId) {
        Ok "$Friendly installed."
        Add-Summary $Friendly "OK" (Get-Version $CommandName) "newly installed"
    } else {
        Fail "$Friendly install failed."
        Add-Summary $Friendly "FAILED" "-" "install command failed"
    }
}

function Execute-ExtraGui($Friendly, $Want, $WingetId) {
    if (-not $Want) {
        Add-Summary $Friendly "SKIPPED" "-" "user chose Skip"; return
    }
    Step "$Friendly..."
    if (Install-WingetPackage $WingetId) {
        Ok "$Friendly installed."
        Add-Summary $Friendly "OK" "-" "newly installed"
    } else {
        Fail "$Friendly install failed."
        Add-Summary $Friendly "FAILED" "-" "install command failed"
    }
}

function Execute-Extras {
    Execute-ExtraCli "GitHub CLI" $WantGhCli "GitHub.cli" "gh"
    Execute-ExtraGui "Docker Desktop" $WantDocker "Docker.DockerDesktop"
    Execute-ExtraGui "Postman" $WantPostman "Postman.Postman"
    Execute-ExtraGui "Chrome" $WantChrome "Google.Chrome"
    Execute-ExtraGui "Firefox" $WantFirefox "Mozilla.Firefox"
    Execute-ExtraCli "jq" $WantJq "jqlang.jq" "jq"
    Execute-Starship
}

function Execute-Starship {
    Execute-ExtraCli "Starship" $WantStarship "Starship.Starship" "starship"
    if ($WantStarship -and (Has-Command "starship")) {
        [void]$NextSteps.Add("Enable Starship in PowerShell: add 'Invoke-Expression (&starship init powershell)' to your PowerShell profile. Run: notepad `$PROFILE")
    }
}

function Execute-GitConfig {
    if (-not $GitConfigNeeded) {
        Add-Summary "git config" "SKIPPED" "-" "already set or user declined"
        return
    }
    & git config --global user.name $GitConfigName
    & git config --global user.email $GitConfigEmail
    if ($LASTEXITCODE -eq 0) {
        Ok "git config set ($GitConfigName <$GitConfigEmail>)."
        Add-Summary "git config" "OK" "-" "newly configured"
    } else {
        Fail "git config failed."
        Add-Summary "git config" "FAILED" "-" "git config command failed"
    }
}

function Execute-GhAuth {
    if (-not $GitSshSetup) { return }
    if (-not (Has-Command "gh")) {
        Fail "GitHub CLI (gh) is required for SSH setup but is not installed."
        Add-Summary "GitHub auth" "FAILED" "-" "gh not installed"
        return
    }
    & gh auth status *> $null
    if ($LASTEXITCODE -eq 0) {
        Ok "gh already authenticated."
        Add-Summary "GitHub auth" "OK" "-" "already authenticated"
        return
    }
    Step "GitHub authentication..."
    Write-Host "  $Gray Create a token at: https://github.com/settings/tokens$NC"
    Write-Host "  $Gray Scopes: repo, admin:public_key (or read:org + admin:public_key)$NC"
    $secure = Read-Host "  Paste GitHub token (hidden)" -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
    if ([string]::IsNullOrWhiteSpace($token)) {
        Fail "No token entered."
        Add-Summary "GitHub auth" "FAILED" "-" "no token provided"
        return
    }
    $token | & gh auth login --with-token *> $null
    if ($LASTEXITCODE -eq 0) {
        Ok "GitHub authenticated."
        Add-Summary "GitHub auth" "OK" "-" "authenticated via token"
    } else {
        Fail "gh auth login failed."
        Add-Summary "GitHub auth" "FAILED" "-" "gh auth login failed"
    }
}

function Execute-SshSetup {
    if (-not $GitSshSetup) {
        Add-Summary "SSH key" "SKIPPED" "-" "not requested"
        return
    }
    if (-not (Has-Command "gh")) {
        Add-Summary "SSH key" "FAILED" "-" "gh not installed"
        return
    }

    Execute-GhAuth
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Add-Summary "SSH key" "FAILED" "-" "gh not authenticated"
        return
    }

    Step "SSH key..."
    $keyDir = Join-Path $HOME ".ssh"
    $keyPath = Join-Path $keyDir "id_ed25519"
    $email = $GitConfigEmail
    if (-not $email -and (Has-Command "git")) {
        $email = (& git config --global user.email 2>$null)
    }
    if (Test-Path $keyPath) {
        Skip "SSH key already exists at $keyPath -- not overwriting."
        Add-Summary "SSH key" "OK" "-" "already existed"
    } else {
        New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
        $comment = if ($email) { $email } else { "sherpa-$env:COMPUTERNAME" }
        & ssh-keygen -t ed25519 -C $comment -f $keyPath -N '""'
        if ($LASTEXITCODE -eq 0) {
            Ok "SSH key generated at $keyPath"
            Add-Summary "SSH key" "OK" "-" "newly generated"
        } else {
            Fail "SSH key generation failed."
            Add-Summary "SSH key" "FAILED" "-" "ssh-keygen failed"
            return
        }
    }

    $pubPath = "$keyPath.pub"
    if (-not (Test-Path $pubPath)) {
        Fail "Public key not found at $pubPath"
        Add-Summary "SSH upload" "FAILED" "-" "missing public key"
        return
    }

    Step "Uploading SSH key to GitHub via gh..."
    $title = "$env:COMPUTERNAME-sherpa"
    & gh ssh-key add $pubPath -t $title *> $null
    if ($LASTEXITCODE -eq 0) {
        Ok "SSH key uploaded to GitHub."
        Add-Summary "SSH upload" "OK" "-" "uploaded via gh"
    } else {
        Fail "Could not upload SSH key (it may already be registered)."
        Add-Summary "SSH upload" "FAILED" "-" "gh ssh-key add failed"
    }
}

function Execute-CloneRepos {
    if (-not $WantClone) {
        Add-Summary "Clone repo(s)" "SKIPPED" "-" "user chose Skip"; return
    }

    Step "Cloning repo(s)..."
    New-Item -ItemType Directory -Force -Path $CloneDir | Out-Null
    $cloned = 0
    $failed = 0

    if ($CloneRepos.Count -gt 0) {
        foreach ($repo in $CloneRepos) {
            $url = Resolve-RepoUrl $repo
            $repoName = ($url.TrimEnd('/') -split '/')[-1]
            if ($repoName.EndsWith(".git")) { $repoName = $repoName.Substring(0, $repoName.Length - 4) }
            $destination = Join-Path $CloneDir $repoName
            & git clone $url $destination
            if ($LASTEXITCODE -eq 0) {
                Ok "Cloned into $destination"
                $cloned++
            } else {
                Fail "Failed to clone $url"
                $failed++
            }
        }
    } else {
        $urls = $CloneUrlsRaw -split ','
        foreach ($url in $urls) {
            $url = $url.Trim()
            if (-not $url) { continue }
            $url = Resolve-RepoUrl $url
            $repoName = ($url.TrimEnd('/') -split '/')[-1]
            if ($repoName.EndsWith(".git")) { $repoName = $repoName.Substring(0, $repoName.Length - 4) }
            $destination = Join-Path $CloneDir $repoName
            & git clone $url $destination
            if ($LASTEXITCODE -eq 0) {
                Ok "Cloned into $destination"
                $cloned++
            } else {
                Fail "Failed to clone $url"
                $failed++
            }
        }
    }

    if ($failed -eq 0) {
        Add-Summary "Clone repo(s)" "OK" "-" "$cloned cloned into $CloneDir"
    } else {
        Add-Summary "Clone repo(s)" "FAILED" "-" "$cloned OK, $failed failed"
    }
}

# =============================================================================
# Main
# =============================================================================

function Main {
    param([string[]]$Args)
    Parse-Args $Args

    Write-Banner
    Ensure-Winget

    if ($ProfileMode) {
        Load-Profile
        Write-Host "`nUsing profile: $Bold$(Split-Path -Leaf $ProfileFile)$NC"
        Write-Host "$Gray Review the plan below, then confirm to install.$NC`n"
        Add-PlanFromProfile
        Gather-GitConfigInteractive
        Print-Plan-And-Confirm
    } else {
        Write-Host "`nA few questions first -- nothing installs until you confirm the plan.`n"
        Gather-Git
        Gather-IDE
        Gather-Node
        Gather-Python
        Gather-Extras
        Gather-GitConfig
        Gather-SshSetup
        Gather-CloneRepos
        Print-Plan-And-Confirm
    }

    Execute-Git
    Execute-IDE
    Execute-Node
    Execute-PackageManager
    Execute-Python
    Execute-Extras
    Execute-GitConfig
    Execute-SshSetup
    Execute-CloneRepos

    Print-Summary

    Write-Host "Close and reopen PowerShell so PATH changes take effect, then verify with:"
    Write-Host "  $Cyan git --version$NC"
    Write-Host "  $Cyan node --version$NC"
    Write-Host "  $Cyan python --version$NC"
    switch ($PkgManagerChoice) {
        1 { Write-Host "  $Cyan pnpm --version$NC" }
        2 { Write-Host "  $Cyan yarn --version$NC" }
    }
    if ($WantStarship) { Write-Host "  $Cyan starship --version$NC" }
    Write-Host ""
}

try {
    Main $args
} catch {
    Write-Host "`n$Red Setup failed unexpectedly:$NC $($_.Exception.Message)"
    Write-Host "$Gray Anything already installed remains installed; nothing further will run.$NC"
    exit 1
}