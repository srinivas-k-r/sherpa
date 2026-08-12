#!/usr/bin/env bash
#
# sherpa-setup.sh
# ---------------------------------------------------------------------------
# One interactive script to bootstrap a dev machine on macOS or Windows.
#
#   macOS:   run from Terminal
#             chmod +x sherpa-setup.sh && ./sherpa-setup.sh
#   Windows: run from Git Bash (not plain CMD/PowerShell)
#             ./sherpa-setup.sh
#
# Flow (three phases, run in this order):
#   1. GATHER  - ask every question up front. Pure input collection, zero
#                side effects, nothing touches the machine yet.
#   2. PLAN    - print exactly what will happen based on those answers, and
#                ask for one final go/no-go confirmation.
#   3. EXECUTE - run the actual installs, printing OK / SKIPPED / FAILED as
#                it goes, then print a summary table + "next steps" notes.
#
# This separation is the whole point of the UX: you always see the full
# plan before anything installs, and Ctrl+C during GATHER or PLAN is 100%
# safe (nothing has happened to your machine yet).
#
# Layout (top to bottom):
#   - Config & globals
#   - UI helpers          (colors, banner, menus, prompts, summary table)
#   - Platform helpers     (OS detection, package manager, clipboard, browser)
#   - Gather_*  functions   (ask questions, store answers -- no installs)
#   - Execute_* functions   (do the actual work, based on stored answers)
#   - Main                  (gather -> plan/confirm -> execute -> summarize)
#
# Each Gather_*/Execute_* pair is self-contained on purpose: when this
# script eventually gets split into modules (per-tool files + a registry),
# each pair below maps 1:1 onto a module.
# ---------------------------------------------------------------------------

set -uo pipefail

# =============================================================================
# Config & globals
# =============================================================================

PLATFORM=""   # "mac" | "windows"

# --- Answers collected during GATHER, consumed during EXECUTE ---
GIT_ALREADY_INSTALLED=false
GIT_WANT_INSTALL=false

IDE_CHOICE=3           # 0=Zed 1=VSCode 2=Both 3=Skip
WANT_VSCODE_EXTENSIONS=false   # starter pack: Prettier, ESLint, GitLens

NODE_CHOICE=2           # 0=nvm 1=direct 2=skip
PKG_MANAGER_CHOICE=0    # 0=npm 1=pnpm 2=yarn

PYTHON_CHOICE=2          # 0=pyenv 1=direct 2=skip

WANT_GH_CLI=false
WANT_DOCKER=false
WANT_POSTMAN=false
WANT_CHROME=false
WANT_FIREFOX=false
WANT_JQ=false
WANT_STARSHIP=false

GITCONFIG_NEEDED=false
GITCONFIG_NAME=""
GITCONFIG_EMAIL=""

WANT_SSH_KEY=false
SSH_EMAIL=""

WANT_CLONE=false
CLONE_URLS_RAW=""
CLONE_DIR=""

# --- Human-readable plan lines, printed before the confirm prompt ---
PLAN_LINES=()

# --- Summary table, filled in during EXECUTE ---
SUMMARY_NAMES=()
SUMMARY_STATUS=()     # OK | SKIPPED | FAILED
SUMMARY_VERSIONS=()
SUMMARY_NOTES=()

# --- Freeform "do this after the script finishes" notes ---
NEXT_STEPS=()

# =============================================================================
# UI helpers
# =============================================================================

YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Mountain facts, one picked at random each run (see banner()) ---
MOUNTAIN_FACTS=(
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

banner() {
  echo ""
  # prayer flags -- traditional five colors: blue, white, red, green, yellow
  local flag_colors=('\033[0;34m' '\033[1;37m' '\033[0;31m' '\033[0;32m' '\033[1;33m')
  local flags="" i
  for ((i = 0; i < 16; i++)); do
    flags+="${flag_colors[$((i % 5))]}▽${NC}"
  done
  echo -e "${GRAY}   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾${NC}"
  echo -e "   ${flags}"
  echo -e "${CYAN}"
  cat <<'MOUNTAIN'
                      /\
                     /  \
                    /    \
                   /      \
                  /   /\   \
                 /   /  \   \
                /   /    \   \
               /___/      \___\
MOUNTAIN
  echo -e "${NC}"
  echo -e "${CYAN}${BOLD}                  S H E R P A${NC}"
  echo -e "${GRAY}           let me carry the heavy gear${NC}"
  echo ""
  local fact_idx=$((RANDOM % ${#MOUNTAIN_FACTS[@]}))
  echo -e "${YELLOW}Mountain fact:${NC} ${MOUNTAIN_FACTS[$fact_idx]}"
  echo ""
}

step()  { echo -e "${YELLOW}>> $1${NC}"; }
ok()    { echo -e "${GREEN}   [OK] $1${NC}"; }
skip()  { echo -e "${GRAY}   [SKIP] $1${NC}"; }
fail()  { echo -e "${RED}   [FAILED] $1${NC}"; }

plan_line()   { PLAN_LINES+=("$1"); }
add_summary() { SUMMARY_NAMES+=("$1"); SUMMARY_STATUS+=("$2"); SUMMARY_VERSIONS+=("${3:--}"); SUMMARY_NOTES+=("${4:--}"); }

# ask_yesno "Question" [default: y|n] -> return code 0 = yes, 1 = no
ask_yesno() {
  local question="$1" default="${2:-y}" suffix="[Y/n]" raw
  [ "$default" = "n" ] && suffix="[y/N]"
  read -r -p "? ${question} ${suffix} " raw
  raw="${raw:-$default}"
  [[ "$raw" =~ ^[Yy] ]]
}

# ask_text "Prompt" ["default value"] -> echoes the result
ask_text() {
  local prompt="$1" default="${2:-}" raw
  if [ -n "$default" ]; then
    read -r -p "  ${prompt} [${default}]: " raw
    echo "${raw:-$default}"
  else
    read -r -p "  ${prompt}: " raw
    echo "$raw"
  fi
}

# select_menu "Question" "Option A" "Option B" ... -> sets $MENU_RESULT (0-based)
# Arrow keys in a real terminal; falls back to numbered input when stdin
# isn't a TTY (piped input, CI) since arrow-key reading needs a real TTY.
select_menu() {
  local prompt="$1"; shift
  local options=("$@")

  if [ ! -t 0 ]; then
    select_menu_fallback "$prompt" "${options[@]}"
    return
  fi

  local selected=0 n=${#options[@]} esc=$'\033'

  draw_menu() {
    echo -e "\n${MAGENTA}? ${prompt}${NC}"
    local i
    for i in "${!options[@]}"; do
      if [ "$i" -eq "$selected" ]; then
        echo -e "  ${GREEN}> ${options[$i]}${NC}"
      else
        echo -e "    ${options[$i]}"
      fi
    done
    echo -e "${GRAY}  (arrow keys to move, Enter to select)${NC}"
  }

  tput civis 2>/dev/null || true
  draw_menu
  # draw_menu prints: 1 blank line + 1 prompt line + n option lines + 1 footer
  # line = n + 3. (Previously miscounted as n + 2, which under-erased by one
  # line on every redraw and made the menu creep down the screen.)
  local lines_drawn=$((n + 3))

  while true; do
    local key moved=false
    IFS= read -rsn1 key
    if [[ $key == "$esc" ]]; then
      read -rsn2 key
      case "$key" in
        '[A') selected=$(( (selected - 1 + n) % n )); moved=true ;;
        '[B') selected=$(( (selected + 1) % n )); moved=true ;;
      esac
    elif [[ -z $key ]]; then
      break
    fi
    # Only erase+redraw when the selection actually moved -- redrawing on
    # every keystroke (including ones we ignore) is what caused the
    # flicker. Erasing is also now one cursor-up + one clear-to-end-of-
    # screen call instead of a per-line loop, so the redraw itself doesn't
    # visibly flash.
    if $moved; then
      tput cuu "$lines_drawn" 2>/dev/null || true
      tput ed 2>/dev/null || true
      draw_menu
    fi
  done

  tput cnorm 2>/dev/null || true
  MENU_RESULT=$selected
}

select_menu_fallback() {
  local prompt="$1"; shift
  local options=("$@")
  echo ""
  echo -e "${MAGENTA}? ${prompt}${NC}"
  local i
  for i in "${!options[@]}"; do
    echo "  $((i + 1))) ${options[$i]}"
  done
  while true; do
    local raw
    read -r -p "  Enter choice (1-${#options[@]}): " raw
    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -ge 1 ] && [ "$raw" -le "${#options[@]}" ]; then
      MENU_RESULT=$((raw - 1)); return
    fi
    echo -e "${RED}  Please enter a number between 1 and ${#options[@]}.${NC}"
  done
}

print_plan_and_confirm() {
  echo ""
  echo -e "${CYAN}=================== Plan =====================${NC}"
  echo "Here's what I'm about to do:"
  local line
  for line in "${PLAN_LINES[@]}"; do
    echo "  - $line"
  done
  echo -e "${CYAN}================================================${NC}"
  echo ""
  if ! ask_yesno "Proceed?" "y"; then
    echo -e "${GRAY}Nothing was installed. Exiting.${NC}"
    exit 0
  fi
}

print_summary_table() {
  echo ""
  echo -e "${GREEN}=================== Summary ====================${NC}"
  printf "%-16s %-9s %-16s %-30s\n" "TOOL" "STATUS" "VERSION" "NOTES"
  printf "%-16s %-9s %-16s %-30s\n" "----" "------" "-------" "-----"
  local i
  for i in "${!SUMMARY_NAMES[@]}"; do
    printf "%-16s %-9s %-16s %-30s\n" \
      "${SUMMARY_NAMES[$i]}" "${SUMMARY_STATUS[$i]}" "${SUMMARY_VERSIONS[$i]}" "${SUMMARY_NOTES[$i]}"
  done
  echo -e "${GREEN}==================================================${NC}"
  echo ""
  if [ ${#NEXT_STEPS[@]} -gt 0 ]; then
    echo -e "${BOLD}Next steps:${NC}"
    local n
    for n in "${NEXT_STEPS[@]}"; do
      echo -e "  - $n"
    done
    echo ""
  fi
}

cleanup_on_interrupt() {
  tput cnorm 2>/dev/null || true
  echo -e "\n\n${RED}Setup cancelled.${NC}"
  echo -e "${RED}Anything already installed above this point is still on your system;${NC}"
  echo -e "${RED}nothing further will run.${NC}"
  exit 130
}
trap cleanup_on_interrupt INT
trap 'tput cnorm 2>/dev/null || true' EXIT

# =============================================================================
# Platform helpers
# =============================================================================

has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_platform() {
  case "$OSTYPE" in
    darwin*) PLATFORM="mac" ;;
    msys*|cygwin*|win32*) PLATFORM="windows" ;;
    *)
      echo -e "${RED}Unsupported OS (\$OSTYPE = '$OSTYPE').${NC}"
      echo "This script supports macOS (Terminal) and Windows (Git Bash) only."
      exit 1
      ;;
  esac
}

get_version() {
  local cmd="$1"
  has_cmd "$cmd" && "$cmd" --version 2>&1 | head -n1 || echo ""
}

ensure_pkg_manager() {
  if [ "$PLATFORM" = "mac" ]; then
    step "Checking Homebrew..."
    if has_cmd brew; then
      ok "Homebrew already installed."
    else
      if ask_yesno "Homebrew isn't installed (required for everything below). Install it now?"; then
        if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
          [ -d "/opt/homebrew/bin" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
          ok "Homebrew installed."
        else
          fail "Homebrew install failed. Exiting."
          exit 1
        fi
      else
        fail "Homebrew is required to continue. Exiting."
        exit 1
      fi
    fi
  else
    step "Checking winget..."
    if has_cmd winget.exe || has_cmd winget; then
      ok "winget is available."
    else
      fail "winget not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
      exit 1
    fi
  fi
}

# install_pkg <brew-formula> <winget-id> [cask: true|false]
install_pkg() {
  local brew_formula="$1" winget_id="$2" is_cask="${3:-false}"
  if [ "$PLATFORM" = "mac" ]; then
    if [ "$is_cask" = "true" ]; then brew install --cask "$brew_formula"; else brew install "$brew_formula"; fi
  else
    winget.exe install --id "$winget_id" -e --accept-source-agreements --accept-package-agreements
  fi
}

open_url() {
  if [ "$PLATFORM" = "mac" ]; then open "$1" >/dev/null 2>&1 || true
  else explorer.exe "$1" >/dev/null 2>&1 || true; fi
}

copy_to_clipboard() {
  if [ "$PLATFORM" = "mac" ]; then printf '%s' "$1" | pbcopy
  else printf '%s' "$1" | clip.exe; fi
}

# =============================================================================
# GATHER phase -- ask questions, store answers, add a plan line. No installs.
# =============================================================================

gather_git() {
  if has_cmd git; then
    GIT_ALREADY_INSTALLED=true
    plan_line "Git: already installed ($(git --version | awk '{print $3}')) -- nothing to do"
  else
    if ask_yesno "Git isn't installed. Install it?"; then
      GIT_WANT_INSTALL=true
      plan_line "Git: install"
    else
      plan_line "Git: skip (you said no)"
    fi
  fi
}

gather_ide() {
  select_menu "Which IDE would you like to install?" \
    "Zed (fast, Rust-based, built-in AI)" \
    "VS Code (most popular, huge extension ecosystem)" \
    "Both" \
    "Skip"
  IDE_CHOICE=$MENU_RESULT
  case $IDE_CHOICE in
    0) plan_line "IDE: install Zed" ;;
    1) plan_line "IDE: install VS Code" ;;
    2) plan_line "IDE: install Zed and VS Code" ;;
    3) plan_line "IDE: skip" ;;
  esac

  if [ "$IDE_CHOICE" -eq 1 ] || [ "$IDE_CHOICE" -eq 2 ]; then
    if ask_yesno "Install a starter VS Code extension pack (Prettier, ESLint, GitLens)?" "y"; then
      WANT_VSCODE_EXTENSIONS=true
      plan_line "VS Code extensions: install Prettier, ESLint, GitLens"
    else
      plan_line "VS Code extensions: skip"
    fi
  fi
}

gather_node() {
  select_menu "How would you like to install Node.js?" \
    "nvm (switch Node versions later - recommended)" \
    "Direct install (latest LTS)" \
    "Skip Node.js"
  NODE_CHOICE=$MENU_RESULT
  case $NODE_CHOICE in
    0) plan_line "Node.js: install via nvm" ;;
    1) plan_line "Node.js: install LTS directly" ;;
    2) plan_line "Node.js: skip" ;;
  esac

  gather_package_manager
}

gather_package_manager() {
  if [ "$NODE_CHOICE" -eq 2 ] && ! has_cmd node; then
    plan_line "Package manager: skip (no Node.js)"
    return
  fi
  select_menu "Which package manager would you like as your default?" \
    "npm (ships with Node, simplest)" \
    "pnpm (fast, disk-efficient -- common on modern JS projects)" \
    "yarn (classic alternative)"
  PKG_MANAGER_CHOICE=$MENU_RESULT
  case $PKG_MANAGER_CHOICE in
    0) plan_line "Package manager: npm (no extra setup)" ;;
    1) plan_line "Package manager: pnpm (enabled via corepack)" ;;
    2) plan_line "Package manager: yarn (enabled via corepack)" ;;
  esac
}

gather_python() {
  select_menu "How would you like to install Python?" \
    "pyenv (switch Python versions later - recommended)" \
    "Direct install (latest 3.x)" \
    "Skip Python"
  PYTHON_CHOICE=$MENU_RESULT
  case $PYTHON_CHOICE in
    0) plan_line "Python: install via pyenv" ;;
    1) plan_line "Python: install 3.x directly" ;;
    2) plan_line "Python: skip" ;;
  esac
}

gather_extras() {
  echo -e "\nA couple of optional extras:"
  if ask_yesno "Install GitHub CLI (gh)?" "y"; then
    WANT_GH_CLI=true; plan_line "GitHub CLI: install"
  else
    plan_line "GitHub CLI: skip"
  fi
  if ask_yesno "Install Docker Desktop?" "n"; then
    WANT_DOCKER=true; plan_line "Docker Desktop: install"
  else
    plan_line "Docker Desktop: skip"
  fi
  if ask_yesno "Install Postman?" "y"; then
    WANT_POSTMAN=true; plan_line "Postman: install"
  else
    plan_line "Postman: skip"
  fi
  if ask_yesno "Install Chrome?" "y"; then
    WANT_CHROME=true; plan_line "Chrome: install"
  else
    plan_line "Chrome: skip"
  fi
  if ask_yesno "Install Firefox?" "n"; then
    WANT_FIREFOX=true; plan_line "Firefox: install"
  else
    plan_line "Firefox: skip"
  fi
  if ask_yesno "Install jq (JSON CLI tool)?" "y"; then
    WANT_JQ=true; plan_line "jq: install"
  else
    plan_line "jq: skip"
  fi
  if ask_yesno "Install Starship (fast, cross-shell prompt)?" "y"; then
    WANT_STARSHIP=true; plan_line "Starship prompt: install"
  else
    plan_line "Starship prompt: skip"
  fi
}

gather_git_config() {
  local name email
  name=$(git config --global user.name 2>/dev/null || true)
  email=$(git config --global user.email 2>/dev/null || true)
  if [ -n "$name" ] && [ -n "$email" ]; then
    plan_line "git config: already set ($name <$email>)"
    return
  fi
  if ask_yesno "git user.name/email isn't fully set. Set it now?" "y"; then
    GITCONFIG_NEEDED=true
    [ -z "$name" ]  && name=$(ask_text "Your name for git commits")
    [ -z "$email" ] && email=$(ask_text "Your email for git commits")
    GITCONFIG_NAME="$name"
    GITCONFIG_EMAIL="$email"
    plan_line "git config: set user.name/email to $name <$email>"
  else
    plan_line "git config: leave as-is"
  fi
}

gather_ssh_key() {
  if ask_yesno "Generate a new SSH key for GitHub/GitLab?" "n"; then
    WANT_SSH_KEY=true
    local default_email="$GITCONFIG_EMAIL"
    [ -z "$default_email" ] && default_email=$(git config --global user.email 2>/dev/null || echo "")
    SSH_EMAIL=$(ask_text "Email to associate with the key" "$default_email")
    plan_line "SSH key: generate id_ed25519, copy public key to clipboard, offer to open GitHub"
  else
    plan_line "SSH key: skip"
  fi
}

gather_clone_repos() {
  if ask_yesno "Clone a repo now?" "n"; then
    CLONE_URLS_RAW=$(ask_text "Repo URL(s), comma-separated" "")
    if [ -z "$CLONE_URLS_RAW" ]; then
      plan_line "Clone repo(s): skip (no URL entered)"
      return
    fi
    CLONE_DIR=$(ask_text "Parent folder to clone into" "$HOME/dev")
    WANT_CLONE=true
    plan_line "Clone repo(s) into $CLONE_DIR: $CLONE_URLS_RAW"
  else
    plan_line "Clone repo(s): skip"
  fi
}

# =============================================================================
# EXECUTE phase -- act on the answers gathered above.
# =============================================================================

execute_git() {
  if $GIT_ALREADY_INSTALLED; then
    add_summary "Git" "OK" "$(git --version | awk '{print $3}')" "already installed"
    return
  fi
  if ! $GIT_WANT_INSTALL; then
    add_summary "Git" "SKIPPED" "-" "user chose Skip"
    return
  fi
  step "Git..."
  if install_pkg "git" "Git.Git"; then
    ok "Git installed."
    add_summary "Git" "OK" "$(get_version git | awk '{print $3}')" "newly installed"
  else
    fail "Git install failed."
    add_summary "Git" "FAILED" "-" "install command failed"
  fi
}

execute_ide() {
  install_zed() {
    step "Zed..."
    if install_pkg "zed" "ZedIndustries.Zed" "true"; then
      ok "Zed installed."; add_summary "Zed" "OK" "-" "newly installed"
    else
      fail "Zed install failed."; add_summary "Zed" "FAILED" "-" "install command failed"
    fi
  }
  install_vscode() {
    step "VS Code..."
    if install_pkg "visual-studio-code" "Microsoft.VisualStudioCode" "true"; then
      ok "VS Code installed."; add_summary "VS Code" "OK" "-" "newly installed"
    else
      fail "VS Code install failed."; add_summary "VS Code" "FAILED" "-" "install command failed"
    fi
    install_vscode_extensions
  }
  case $IDE_CHOICE in
    0) install_zed ;;
    1) install_vscode ;;
    2) install_zed; install_vscode ;;
    3) add_summary "IDE" "SKIPPED" "-" "user chose Skip" ;;
  esac
}

# install_vscode_extensions -- starter pack (Prettier, ESLint, GitLens), run
# right after install_vscode. Needs the `code` CLI on PATH, which a
# freshly-installed VS Code often isn't until the terminal restarts -- in
# that case we hand the command back to the user as a next step instead of
# failing outright.
install_vscode_extensions() {
  if ! $WANT_VSCODE_EXTENSIONS; then
    add_summary "VS Code extensions" "SKIPPED" "-" "user chose Skip"
    return
  fi
  step "VS Code starter extensions..."
  if ! has_cmd code; then
    skip "'code' CLI not on PATH yet -- can't install extensions this run."
    add_summary "VS Code extensions" "SKIPPED" "-" "code CLI not on PATH"
    NEXT_STEPS+=("After reopening your terminal, run: code --install-extension esbenp.prettier-vscode && code --install-extension dbaeumer.vscode-eslint && code --install-extension eamodio.gitlens")
    return
  fi
  local exts=(esbenp.prettier-vscode dbaeumer.vscode-eslint eamodio.gitlens) failed=0 ext
  for ext in "${exts[@]}"; do
    code --install-extension "$ext" --force >/dev/null 2>&1 || failed=$((failed + 1))
  done
  if [ $failed -eq 0 ]; then
    ok "Prettier, ESLint, GitLens installed."
    add_summary "VS Code extensions" "OK" "-" "Prettier, ESLint, GitLens"
  else
    fail "$failed of ${#exts[@]} extension(s) failed to install."
    add_summary "VS Code extensions" "FAILED" "-" "$failed of ${#exts[@]} failed"
  fi
}

execute_node() {
  case $NODE_CHOICE in
    0)
      step "nvm..."
      if [ "$PLATFORM" = "mac" ]; then
        if [ -d "$HOME/.nvm" ] || has_cmd nvm; then
          skip "nvm already installed."; add_summary "nvm" "OK" "-" "already installed"
        elif curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash; then
          ok "nvm installed."; add_summary "nvm" "OK" "-" "newly installed"
          NEXT_STEPS+=("Open a new terminal (or 'source ~/.zshrc'), then: nvm install --lts && nvm use --lts")
        else
          fail "nvm install failed."; add_summary "nvm" "FAILED" "-" "install command failed"
        fi
      else
        if has_cmd nvm; then
          skip "nvm-windows already installed."; add_summary "nvm-windows" "OK" "-" "already installed"
        elif install_pkg "" "CoreyButler.NVMforWindows"; then
          ok "nvm-windows installed."; add_summary "nvm-windows" "OK" "-" "newly installed"
          NEXT_STEPS+=("Open a NEW terminal, then: nvm install lts && nvm use lts")
        else
          fail "nvm-windows install failed."; add_summary "nvm-windows" "FAILED" "-" "install command failed"
        fi
      fi
      ;;
    1)
      step "Node.js LTS..."
      if install_pkg "node@22" "OpenJS.NodeJS.LTS"; then
        ok "Node.js LTS installed."; add_summary "Node.js" "OK" "$(get_version node)" "newly installed"
      else
        fail "Node.js install failed."; add_summary "Node.js" "FAILED" "-" "install command failed"
      fi
      ;;
    2) add_summary "Node.js" "SKIPPED" "-" "user chose Skip" ;;
  esac
}

# execute_package_manager -- npm needs nothing extra (it ships with Node).
# pnpm/yarn are activated through corepack, which itself ships with Node
# >=16.9, so this only makes sense once Node is actually on PATH.
execute_package_manager() {
  case $PKG_MANAGER_CHOICE in
    0)
      add_summary "Package manager" "OK" "npm" "using npm (default)"
      ;;
    1)
      step "pnpm via corepack..."
      if ! has_cmd node; then
        fail "Node.js not found -- can't enable corepack."
        add_summary "pnpm" "FAILED" "-" "Node.js not installed"
      elif corepack enable >/dev/null 2>&1 && corepack prepare pnpm@latest --activate >/dev/null 2>&1; then
        ok "pnpm activated via corepack."
        add_summary "pnpm" "OK" "$(get_version pnpm)" "activated via corepack"
        NEXT_STEPS+=("Open a new terminal, then: pnpm --version")
      else
        fail "corepack/pnpm setup failed."
        add_summary "pnpm" "FAILED" "-" "corepack command failed"
      fi
      ;;
    2)
      step "yarn via corepack..."
      if ! has_cmd node; then
        fail "Node.js not found -- can't enable corepack."
        add_summary "yarn" "FAILED" "-" "Node.js not installed"
      elif corepack enable >/dev/null 2>&1 && corepack prepare yarn@stable --activate >/dev/null 2>&1; then
        ok "yarn activated via corepack."
        add_summary "yarn" "OK" "$(get_version yarn)" "activated via corepack"
        NEXT_STEPS+=("Open a new terminal, then: yarn --version")
      else
        fail "corepack/yarn setup failed."
        add_summary "yarn" "FAILED" "-" "corepack command failed"
      fi
      ;;
  esac
}

execute_python() {
  case $PYTHON_CHOICE in
    0)
      step "pyenv..."
      if [ "$PLATFORM" = "mac" ]; then
        if has_cmd pyenv; then
          skip "pyenv already installed."; add_summary "pyenv" "OK" "-" "already installed"
        elif install_pkg "pyenv" ""; then
          ok "pyenv installed."; add_summary "pyenv" "OK" "-" "newly installed"
          # Single-quoted on purpose: this is instructional text for the user, not meant to expand.
          # shellcheck disable=SC2016
          NEXT_STEPS+=('Add eval "$(pyenv init -)" to ~/.zshrc, restart terminal, then: pyenv install 3.12.4 && pyenv global 3.12.4')
        else
          fail "pyenv install failed."; add_summary "pyenv" "FAILED" "-" "install command failed"
        fi
      else
        if has_cmd pyenv; then
          skip "pyenv-win already installed."; add_summary "pyenv-win" "OK" "-" "already installed"
        else
          # No reliable winget package as of writing -- use the official installer script.
          if powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
            "Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1' -OutFile \"\$env:TEMP\install-pyenv-win.ps1\"; & \"\$env:TEMP\install-pyenv-win.ps1\""; then
            ok "pyenv-win installed."; add_summary "pyenv-win" "OK" "-" "newly installed"
            NEXT_STEPS+=("Open a NEW terminal, then: pyenv install 3.12.4 && pyenv global 3.12.4")
          else
            fail "pyenv-win install failed."; add_summary "pyenv-win" "FAILED" "-" "install command failed"
          fi
        fi
      fi
      ;;
    1)
      step "Python 3..."
      if install_pkg "python@3.12" "Python.Python.3.12"; then
        ok "Python installed."; add_summary "Python" "OK" "$(get_version python3)" "newly installed"
      else
        fail "Python install failed."; add_summary "Python" "FAILED" "-" "install command failed"
      fi
      ;;
    2) add_summary "Python" "SKIPPED" "-" "user chose Skip" ;;
  esac
}

# mac_app_installed <"Name.app"> -- best-effort check for GUI apps on macOS,
# since they don't put a CLI binary on PATH the way has_cmd can check.
# Windows GUI-app installs skip this check and rely on winget's own
# "already installed" handling instead.
mac_app_installed() { [ -d "/Applications/$1" ]; }

# execute_extra_cli <friendly> <already-installed?> <brew-formula> <winget-id> <version-cmd>
# Shared logic for CLI tools we can detect via has_cmd.
execute_extra_cli() {
  local friendly="$1" want="$2" brew_formula="$3" winget_id="$4" vcmd="$5"
  if ! $want; then
    add_summary "$friendly" "SKIPPED" "-" "user chose Skip"
    return
  fi
  step "$friendly..."
  if has_cmd "$vcmd"; then
    skip "$friendly already installed."
    add_summary "$friendly" "OK" "$(get_version "$vcmd")" "already installed"
    return
  fi
  if install_pkg "$brew_formula" "$winget_id"; then
    ok "$friendly installed."
    add_summary "$friendly" "OK" "$(get_version "$vcmd")" "newly installed"
  else
    fail "$friendly install failed."
    add_summary "$friendly" "FAILED" "-" "install command failed"
  fi
}

# execute_extra_gui <friendly> <already-installed?> <brew-cask> <winget-id> <mac-app-bundle-name>
# Shared logic for GUI apps (cask installs on mac, winget on Windows).
execute_extra_gui() {
  local friendly="$1" want="$2" brew_cask="$3" winget_id="$4" mac_app="$5"
  if ! $want; then
    add_summary "$friendly" "SKIPPED" "-" "user chose Skip"
    return
  fi
  step "$friendly..."
  if [ "$PLATFORM" = "mac" ] && mac_app_installed "$mac_app"; then
    skip "$friendly already installed."
    add_summary "$friendly" "OK" "-" "already installed"
    return
  fi
  if install_pkg "$brew_cask" "$winget_id" "true"; then
    ok "$friendly installed."
    add_summary "$friendly" "OK" "-" "newly installed"
  else
    fail "$friendly install failed."
    add_summary "$friendly" "FAILED" "-" "install command failed"
  fi
}

execute_extras() {
  execute_extra_cli "GitHub CLI" "$WANT_GH_CLI" "gh" "GitHub.cli" "gh"
  execute_extra_gui "Docker Desktop" "$WANT_DOCKER" "docker" "Docker.DockerDesktop" "Docker.app"
  execute_extra_gui "Postman" "$WANT_POSTMAN" "postman" "Postman.Postman" "Postman.app"
  execute_extra_gui "Chrome" "$WANT_CHROME" "google-chrome" "Google.Chrome" "Google Chrome.app"
  execute_extra_gui "Firefox" "$WANT_FIREFOX" "firefox" "Mozilla.Firefox" "Firefox.app"
  execute_extra_cli "jq" "$WANT_JQ" "jq" "jqlang.jq" "jq"
  execute_starship
}

# execute_starship -- single static binary on both platforms via
# execute_extra_cli, then a NEXT_STEPS note for wiring it into the shell
# rc file, since that's a one-line edit we shouldn't make for the user
# without them seeing it first.
execute_starship() {
  execute_extra_cli "Starship" "$WANT_STARSHIP" "starship" "Starship.Starship" "starship"
  if $WANT_STARSHIP && has_cmd starship; then
    local rc_file="$HOME/.bashrc"
    [ "$PLATFORM" = "mac" ] && rc_file="$HOME/.zshrc"
    NEXT_STEPS+=("Enable the Starship prompt: add 'eval \"\$(starship init bash)\"' (swap bash for zsh if that's your shell) to the end of $rc_file, then restart your terminal.")
  fi
}

execute_git_config() {
  if ! $GITCONFIG_NEEDED; then
    add_summary "git config" "SKIPPED" "-" "already set or user declined"
    return
  fi
  git config --global user.name "$GITCONFIG_NAME"
  git config --global user.email "$GITCONFIG_EMAIL"
  ok "git config set ($GITCONFIG_NAME <$GITCONFIG_EMAIL>)."
  add_summary "git config" "OK" "-" "newly configured"
}

execute_ssh_key() {
  if ! $WANT_SSH_KEY; then
    add_summary "SSH key" "SKIPPED" "-" "user chose Skip"
    return
  fi
  step "SSH key..."
  local key_path="$HOME/.ssh/id_ed25519"
  if [ -f "$key_path" ]; then
    skip "SSH key already exists at $key_path -- not overwriting."
    add_summary "SSH key" "OK" "-" "already existed"
  else
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f "$key_path" -N ""
    ok "SSH key generated at $key_path"
    add_summary "SSH key" "OK" "-" "newly generated"
  fi
  if [ -f "${key_path}.pub" ]; then
    copy_to_clipboard "$(cat "${key_path}.pub")"
    ok "Public key copied to clipboard."
    if ask_yesno "Open GitHub's 'Add SSH key' page now?" "y"; then
      open_url "https://github.com/settings/keys"
    fi
  fi
}

execute_clone_repos() {
  if ! $WANT_CLONE; then
    add_summary "Clone repo(s)" "SKIPPED" "-" "user chose Skip"
    return
  fi
  step "Cloning repo(s)..."
  mkdir -p "$CLONE_DIR"
  local cloned=0 failed=0 url
  IFS=',' read -ra urls <<< "$CLONE_URLS_RAW"
  for url in "${urls[@]}"; do
    url=$(echo "$url" | xargs)
    [ -z "$url" ] && continue
    if git clone "$url" "$CLONE_DIR/$(basename "$url" .git)"; then
      ok "Cloned into $CLONE_DIR/$(basename "$url" .git)"
      cloned=$((cloned + 1))
    else
      fail "Failed to clone $url"
      failed=$((failed + 1))
    fi
  done
  if [ $failed -eq 0 ]; then
    add_summary "Clone repo(s)" "OK" "-" "$cloned cloned into $CLONE_DIR"
  else
    add_summary "Clone repo(s)" "FAILED" "-" "$cloned OK, $failed failed"
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  banner
  detect_platform
  ensure_pkg_manager

  echo -e "\nA few questions first -- nothing installs until you confirm the plan.\n"

  gather_git
  gather_ide
  gather_node
  gather_python
  gather_extras
  gather_git_config
  gather_ssh_key
  gather_clone_repos

  print_plan_and_confirm

  execute_git
  execute_ide
  execute_node
  execute_package_manager
  execute_python
  execute_extras
  execute_git_config
  execute_ssh_key
  execute_clone_repos

  print_summary_table
  echo "Close and reopen your terminal so PATH changes take effect, then verify with:"
  echo -e "  ${CYAN}git --version${NC}"
  echo -e "  ${CYAN}node --version${NC}"
  echo -e "  ${CYAN}python3 --version${NC}"
  case $PKG_MANAGER_CHOICE in
    1) echo -e "  ${CYAN}pnpm --version${NC}" ;;
    2) echo -e "  ${CYAN}yarn --version${NC}" ;;
  esac
  $WANT_STARSHIP && echo -e "  ${CYAN}starship --version${NC}"
  echo ""
}

main