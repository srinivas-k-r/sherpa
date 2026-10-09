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
# Two ways to walk:
#   Picnic   (no args)     You pack the basket. Leaving something behind is
#                          allowed.
#   Catered  (--profile)   The yaml is the menu. You don't send a dish back.
#
# Both ways: gear that's already installed is walked past, and one spill
# (a failed install, a failed clone) never cancels the rest of the meal.
# The summary always prints. Ctrl+C during GATHER or PLAN is safe — nothing
# has been installed yet. Homebrew, if it's missing, is the one thing that
# may download before the menu, because the rest of the picnic rides on it.
#
# Flow: GATHER → PLAN → CONFIRM → EXECUTE → SUMMARY
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Config & globals
# =============================================================================

PLATFORM=""   # "mac" | "windows"

PROFILE_FILE=""
PROFILE_MODE=false
PROFILE_NAME=""
NODE_VERSION="lts"
NODE_DEFAULT="lts"
NODE_VERSIONS=("lts")
PYTHON_VERSION="3.12.4"
GIT_SSH_SETUP=false
CLONE_REPOS=()

# --- Answers collected during GATHER, consumed during EXECUTE ---
GIT_ALREADY_INSTALLED=false
GIT_WANT_INSTALL=false

IDE_CHOICE=4           # 0=Zed 1=VSCode 2=Cursor 3=Zed+VSCode 4=Skip
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
WANT_CLAUDE=false

GITCONFIG_NEEDED=false
GITCONFIG_NAME=""
GITCONFIG_EMAIL=""

WANT_CLONE=false
CLONE_URLS_RAW=""
CLONE_DIR=""

# True once brew (mac) or winget (windows) is actually usable.
PKG_MGR_READY=false
# Set by execute_extra_cli so Starship only nags when it was just installed.
EXTRA_FRESH=false

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

# Already on the machine: don't install it again.
walk_past() { skip "$1 is already in the pack. Walking past it."; }

# This step failed. The next one still runs.
slipped() { fail "$1 slipped off the yak. Noted. Still walking."; }

# Why a row was skipped on purpose (a choice), as opposed to "already here".
left_behind() {
  if $PROFILE_MODE; then
    printf '%s' "not on the menu"
  else
    printf '%s' "left at camp"
  fi
}

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
  if $PROFILE_MODE; then
    echo -e "${CYAN}=================== The menu =================${NC}"
    echo "Catered. No sending plates back."
  else
    echo -e "${CYAN}=================== The basket ================${NC}"
    echo "Picnic. This is everything you said yes to."
  fi
  local line
  for line in "${PLAN_LINES[@]}"; do
    echo "  - $line"
  done
  echo -e "${CYAN}================================================${NC}"
  echo ""
  if ! ask_yesno "Pack it?" "y"; then
    echo -e "${GRAY}Leaving the basket on the blanket. Nothing was packed.${NC}"
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

usage() {
  cat <<'EOF'
Usage: sherpa-setup.sh [options]

Picnic (just run it):
  You pack the basket. Say no to anything you don't want to carry.

Catered (--profile <file>):
  The yaml is the menu. You don't get to send a dish back.

Either way, gear that's already installed is walked past, and one spill
doesn't cancel the rest of the meal.

Options:
  --profile <file>   Catered mode. Cook the menu in this file.
  -h, --help         Show this help

Examples:
  ./sherpa-setup.sh
  ./sherpa-setup.sh --profile sherpa.yml
  ./sherpa-setup.sh --profile ./team-bundle/sherpa.yml
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        [ $# -ge 2 ] || { echo -e "${RED}--profile requires a file path.${NC}"; exit 1; }
        PROFILE_FILE="$2"
        PROFILE_MODE=true
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo -e "${RED}Unknown option: $1${NC}"
        usage
        exit 1
        ;;
    esac
  done
}

expand_home() {
  local path="$1"
  if [ "$path" = "~" ]; then
    printf '%s\n' "$HOME"
  elif [ "${path#\~/}" != "$path" ]; then
    printf '%s\n' "$HOME/${path#\~/}"
  else
    printf '%s\n' "$path"
  fi
}

resolve_repo_url() {
  local repo="$1"
  if [[ "$repo" == git@* ]] || [[ "$repo" == https://* ]] || [[ "$repo" == http://* ]]; then
    echo "$repo"
  elif [[ "$repo" == */* ]]; then
    echo "git@github.com:${repo}.git"
  else
    echo "$repo"
  fi
}

yaml_strip() {
  # strip inline comments outside quotes, then trim, then outer quotes
  local s="$1" out="" i=0 in_s=0 in_d=0 ch
  while [ $i -lt ${#s} ]; do
    ch="${s:$i:1}"
    if [ "$ch" = '"' ] && [ $in_s -eq 0 ]; then
      in_d=$((1 - in_d)); out+="$ch"
    elif [ "$ch" = "'" ] && [ $in_d -eq 0 ]; then
      in_s=$((1 - in_s)); out+="$ch"
    elif [ "$ch" = "#" ] && [ $in_s -eq 0 ] && [ $in_d -eq 0 ]; then
      break
    else
      out+="$ch"
    fi
    i=$((i + 1))
  done
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  if [[ "$out" == \"*\" && "$out" == *\" ]]; then
    out="${out:1:${#out}-2}"
  elif [[ "$out" == \'*\' && "$out" == *\' ]]; then
    out="${out:1:${#out}-2}"
  fi
  printf '%s' "$out"
}

yaml_map_choice() {
  local field="$1" value="$2"
  case "$field:$value" in
    node.manager:nvm) echo 0 ;;
    node.manager:direct) echo 1 ;;
    node.manager:skip) echo 2 ;;
    python.manager:pyenv) echo 0 ;;
    python.manager:direct) echo 1 ;;
    python.manager:skip) echo 2 ;;
    ide.choice:zed) echo 0 ;;
    ide.choice:vscode) echo 1 ;;
    ide.choice:cursor) echo 2 ;;
    ide.choice:both) echo 3 ;;
    ide.choice:skip) echo 4 ;;
    package_manager:npm) echo 0 ;;
    package_manager:pnpm) echo 1 ;;
    package_manager:yarn) echo 2 ;;
    *)
      echo -e "${RED}Invalid $field: $value${NC}" >&2
      return 1
      ;;
  esac
}

# Pure bash profile loader — no python required (blank laptop friendly).
load_profile() {
  if [ ! -f "$PROFILE_FILE" ]; then
    echo -e "${RED}Profile not found: $PROFILE_FILE${NC}"
    exit 1
  fi

  PROFILE_MODE=true
  PROFILE_NAME="$(basename "$PROFILE_FILE" .yml)"
  PROFILE_NAME="${PROFILE_NAME%.yaml}"
  NODE_CHOICE=2
  NODE_VERSION="lts"
  NODE_DEFAULT="lts"
  NODE_VERSIONS=()
  PYTHON_CHOICE=2
  PYTHON_VERSION="3.12.4"
  IDE_CHOICE=4
  WANT_VSCODE_EXTENSIONS=false
  PKG_MANAGER_CHOICE=0
  WANT_GH_CLI=false
  WANT_DOCKER=false
  WANT_POSTMAN=false
  WANT_CHROME=false
  WANT_FIREFOX=false
  WANT_JQ=false
  WANT_STARSHIP=false
  WANT_CLAUDE=false
  GIT_SSH_SETUP=false
  WANT_CLONE=false
  CLONE_DIR="$HOME/dev"
  CLONE_REPOS=()

  local section="" indent=0 line raw key value item choice
  local git_protocol="ssh"
  local versions_raw=""

  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    indent=0
    while [[ "$line" =~ ^"  " ]]; do
      indent=$((indent + 1))
      line="${line:2}"
    done
    raw="$(yaml_strip "$line")"
    [ -z "$raw" ] && continue

    if [[ "$raw" == -* ]]; then
      item="$(yaml_strip "${raw#-}")"
      item="$(yaml_strip "$item")"
      case "$section" in
        extras)
          case "$item" in
            gh) WANT_GH_CLI=true ;;
            docker) WANT_DOCKER=true ;;
            postman) WANT_POSTMAN=true ;;
            chrome) WANT_CHROME=true ;;
            firefox) WANT_FIREFOX=true ;;
            jq) WANT_JQ=true ;;
            starship) WANT_STARSHIP=true ;;
            claude) WANT_CLAUDE=true ;;
            *) echo -e "${RED}Unknown extra: $item${NC}"; exit 1 ;;
          esac
          ;;
        git.clone.repos)
          [ -n "$item" ] && CLONE_REPOS+=("$item")
          ;;
        node.versions)
          [ -n "$item" ] && NODE_VERSIONS+=("$item")
          ;;
      esac
      continue
    fi

    [[ "$raw" == *:* ]] || continue
    key="${raw%%:*}"
    value="$(yaml_strip "${raw#*:}")"
    key="$(yaml_strip "$key")"

    if [ $indent -eq 0 ]; then
      section=""
      case "$key" in
        name) [ -n "$value" ] && PROFILE_NAME="$value" ;;
        package_manager)
          choice="$(yaml_map_choice package_manager "$value")" || exit 1
          PKG_MANAGER_CHOICE=$choice
          ;;
        node|python|ide|extras|git) section="$key" ;;
      esac
      continue
    fi

    if [ $indent -eq 1 ]; then
      case "$section:$key" in
        node:manager)
          choice="$(yaml_map_choice node.manager "$value")" || exit 1
          NODE_CHOICE=$choice
          ;;
        node:version)
          versions_raw="$value"
          NODE_DEFAULT="$value"
          ;;
        node:versions)
          versions_raw="$value"
          ;;
        node:default)
          NODE_DEFAULT="$value"
          ;;
        python:manager)
          choice="$(yaml_map_choice python.manager "$value")" || exit 1
          PYTHON_CHOICE=$choice
          ;;
        python:version)
          PYTHON_VERSION="$value"
          ;;
        ide:choice)
          choice="$(yaml_map_choice ide.choice "$value")" || exit 1
          IDE_CHOICE=$choice
          ;;
        ide:vscode_extensions)
          case "$value" in true|True|yes|Yes) WANT_VSCODE_EXTENSIONS=true ;; *) WANT_VSCODE_EXTENSIONS=false ;; esac
          ;;
        git:protocol)
          git_protocol="$value"
          ;;
        git:clone)
          section="git.clone"
          ;;
        node:*) section="node.$key" ;;
        git:*) section="git.$key" ;;
      esac
      # empty value after key: means nested block follows
      if [ -z "$value" ]; then
        case "$section:$key" in
          *:versions) section="node.versions" ;;
          git:clone) section="git.clone" ;;
          *:extras) section="extras" ;;
        esac
      fi
      continue
    fi

    if [ $indent -ge 2 ]; then
      case "$section:$key" in
        git.clone:dir) CLONE_DIR="$value" ;;
        git.clone:repos) section="git.clone.repos" ;;
      esac
    fi
  done < "$PROFILE_FILE"

  # Resolve node versions from scalar / pipe / list
  if [ ${#NODE_VERSIONS[@]} -eq 0 ] && [ -n "$versions_raw" ]; then
    if [[ "$versions_raw" == *"|"* ]]; then
      IFS='|' read -ra NODE_VERSIONS <<< "$versions_raw"
      local i
      for i in "${!NODE_VERSIONS[@]}"; do
        NODE_VERSIONS[$i]="$(yaml_strip "${NODE_VERSIONS[$i]}")"
      done
    else
      NODE_VERSIONS=("$versions_raw")
    fi
  fi
  if [ ${#NODE_VERSIONS[@]} -eq 0 ]; then
    NODE_VERSIONS=("lts")
  fi
  # drop empties
  local cleaned=()
  for item in "${NODE_VERSIONS[@]}"; do
    [ -n "$item" ] && cleaned+=("$item")
  done
  NODE_VERSIONS=("${cleaned[@]}")
  [ -z "$NODE_DEFAULT" ] && NODE_DEFAULT="${NODE_VERSIONS[$((${#NODE_VERSIONS[@]} - 1))]}"
  NODE_VERSION="$NODE_DEFAULT"
  local found=false
  for item in "${NODE_VERSIONS[@]}"; do
    [ "$item" = "$NODE_DEFAULT" ] && found=true
  done
  $found || NODE_VERSIONS+=("$NODE_DEFAULT")

  case "$git_protocol" in
    ssh|SSH) GIT_SSH_SETUP=true ;;
    *) GIT_SSH_SETUP=false ;;
  esac

  if [ ${#CLONE_REPOS[@]} -gt 0 ]; then
    WANT_CLONE=true
    $GIT_SSH_SETUP && WANT_GH_CLI=true
  fi

  CLONE_DIR="$(expand_home "$CLONE_DIR")"
}

plan_from_profile() {
  plan_line "Profile: $PROFILE_NAME (from $(basename "$PROFILE_FILE"))"

  if has_cmd git; then
    GIT_ALREADY_INSTALLED=true
    plan_line "Git: already in the pack — walking past it"
  else
    GIT_WANT_INSTALL=true
    plan_line "Git: install"
  fi

  case $IDE_CHOICE in
    0) plan_line "IDE: install Zed" ;;
    1) plan_line "IDE: install VS Code" ;;
    2) plan_line "IDE: install Cursor" ;;
    3) plan_line "IDE: install Zed and VS Code" ;;
    4) plan_line "IDE: not on the menu" ;;
  esac
  if [ "$IDE_CHOICE" -eq 1 ] || [ "$IDE_CHOICE" -eq 3 ]; then
    if $WANT_VSCODE_EXTENSIONS; then
      plan_line "VS Code extensions: install Prettier, ESLint, GitLens"
    else
      plan_line "VS Code extensions: not on the menu"
    fi
  fi

  case $NODE_CHOICE in
    0)
      local joined
      joined=$(IFS=', '; echo "${NODE_VERSIONS[*]}")
      plan_line "Node.js: install via nvm (versions: $joined; default: $NODE_DEFAULT)"
      ;;
    1) plan_line "Node.js: install LTS directly" ;;
    2) plan_line "Node.js: not on the menu" ;;
  esac
  case $PKG_MANAGER_CHOICE in
    0) plan_line "Package manager: npm" ;;
    1) plan_line "Package manager: pnpm" ;;
    2) plan_line "Package manager: yarn" ;;
  esac

  case $PYTHON_CHOICE in
    0) plan_line "Python: install via pyenv (version: $PYTHON_VERSION)" ;;
    1) plan_line "Python: install directly" ;;
    2) plan_line "Python: not on the menu" ;;
  esac

  $WANT_GH_CLI && plan_line "GitHub CLI: install" || plan_line "GitHub CLI: not on the menu"
  $WANT_DOCKER && plan_line "Docker Desktop: install" || plan_line "Docker Desktop: not on the menu"
  $WANT_POSTMAN && plan_line "Postman: install" || plan_line "Postman: not on the menu"
  $WANT_CHROME && plan_line "Chrome: install" || plan_line "Chrome: not on the menu"
  $WANT_FIREFOX && plan_line "Firefox: install" || plan_line "Firefox: not on the menu"
  $WANT_JQ && plan_line "jq: install" || plan_line "jq: not on the menu"
  $WANT_STARSHIP && plan_line "Starship prompt: install" || plan_line "Starship prompt: not on the menu"
  $WANT_CLAUDE && plan_line "Claude Desktop: install" || plan_line "Claude Desktop: not on the menu"

  local name email
  name=$(git config --global user.name 2>/dev/null || true)
  email=$(git config --global user.email 2>/dev/null || true)
  if [ -n "$name" ] && [ -n "$email" ]; then
    plan_line "git config: already set ($name <$email>)"
  else
    plan_line "git config: prompt for user.name / user.email"
  fi

  if $GIT_SSH_SETUP; then
    plan_line "SSH: generate key if needed, upload to GitHub via gh (terminal only)"
  else
    plan_line "SSH: not on the menu"
  fi

  if $WANT_CLONE; then
    local repo resolved
    plan_line "Clone repo(s) into $CLONE_DIR:"
    for repo in "${CLONE_REPOS[@]}"; do
      resolved="$(resolve_repo_url "$repo")"
      plan_line "  - $resolved"
    done
  else
    plan_line "Clone repo(s): not on the menu"
  fi
}

gather_git_config_interactive() {
  local name email
  name=$(git config --global user.name 2>/dev/null || true)
  email=$(git config --global user.email 2>/dev/null || true)
  if [ -n "$name" ] && [ -n "$email" ]; then
    if $PROFILE_MODE; then return; fi
    plan_line "git config: already set ($name <$email>)"
    return
  fi
  if $PROFILE_MODE; then
    echo -e "\n${GRAY}Git doesn't know your name yet. Catered menus don't carry that — it's personal.${NC}"
    GITCONFIG_NEEDED=true
    [ -z "$name" ]  && name=$(ask_text "Your name for git commits")
    [ -z "$email" ] && email=$(ask_text "Your email for git commits")
    GITCONFIG_NAME="$name"
    GITCONFIG_EMAIL="$email"
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
    plan_line "git config: left at camp"
  fi
}

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

# Download the Homebrew installer ourselves so a failed curl can't look like
# success (bash -c "" exits 0) and can't take the rest of the picnic with it.
install_homebrew() {
  local script rc
  script="$(mktemp)"
  if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$script"; then
    rm -f "$script"
    return 1
  fi
  /bin/bash "$script"
  rc=$?
  rm -f "$script"
  return $rc
}

ensure_pkg_manager() {
  if [ "$PLATFORM" = "mac" ]; then
    step "Checking Homebrew..."
    if has_cmd brew; then
      walk_past "Homebrew"
      PKG_MGR_READY=true
      add_summary "Homebrew" "SKIPPED" "-" "already in the pack"
    else
      local install_it=false
      if $PROFILE_MODE; then
        echo -e "  ${GRAY}Catered mode. Homebrew isn't here, so I'm fetching it. The menu doesn't ask.${NC}"
        install_it=true
      elif ask_yesno "Homebrew isn't installed. Bring it? Most of the picnic rides on it."; then
        install_it=true
      fi
      if $install_it; then
        if install_homebrew; then
          [ -d "/opt/homebrew/bin" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
          ok "Homebrew is on the yak."
          PKG_MGR_READY=true
          add_summary "Homebrew" "OK" "-" "fresh off the trail"
        else
          slipped "Homebrew"
          PKG_MGR_READY=false
          add_summary "Homebrew" "FAILED" "-" "install slipped"
          echo -e "  ${GRAY}Anything that needed Homebrew will slip too. The rest of the picnic keeps going.${NC}"
        fi
      else
        skip "Homebrew left at camp. Anything that needs it will slip, and we'll keep walking."
        PKG_MGR_READY=false
        add_summary "Homebrew" "SKIPPED" "-" "left at camp"
      fi
    fi
  else
    step "Checking winget..."
    if has_cmd winget.exe || has_cmd winget; then
      walk_past "winget"
      PKG_MGR_READY=true
      add_summary "winget" "SKIPPED" "-" "already in the pack"
    else
      slipped "winget"
      PKG_MGR_READY=false
      add_summary "winget" "FAILED" "-" "not on this machine"
      echo -e "  ${GRAY}Install 'App Installer' from the Microsoft Store, then run me again. Meanwhile, I'll keep walking.${NC}"
    fi
  fi
}

# install_pkg <brew-formula> <winget-id> [cask: true|false]
install_pkg() {
  local brew_formula="$1" winget_id="$2" is_cask="${3:-false}"
  if ! $PKG_MGR_READY; then
    return 1
  fi
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
    plan_line "Git: already in the pack — walking past it"
  else
    if ask_yesno "Git isn't installed. Toss it in the basket?"; then
      GIT_WANT_INSTALL=true
      plan_line "Git: install"
    else
      plan_line "Git: left at camp"
    fi
  fi
}

gather_ide() {
  select_menu "Which IDE would you like to install?" \
    "Zed (fast, Rust-based, built-in AI)" \
    "VS Code (most popular, huge extension ecosystem)" \
    "Cursor (AI editor, chat in the sidebar)" \
    "Zed and VS Code" \
    "Skip"
  IDE_CHOICE=$MENU_RESULT
  case $IDE_CHOICE in
    0) plan_line "IDE: install Zed" ;;
    1) plan_line "IDE: install VS Code" ;;
    2) plan_line "IDE: install Cursor" ;;
    3) plan_line "IDE: install Zed and VS Code" ;;
    4) plan_line "IDE: left at camp" ;;
  esac

  if [ "$IDE_CHOICE" -eq 1 ] || [ "$IDE_CHOICE" -eq 3 ]; then
    if ask_yesno "Toss in a VS Code snack pack (Prettier, ESLint, GitLens)?" "y"; then
      WANT_VSCODE_EXTENSIONS=true
      plan_line "VS Code extensions: Prettier, ESLint, GitLens"
    else
      plan_line "VS Code extensions: left at camp"
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
    2) plan_line "Node.js: left at camp" ;;
  esac

  gather_package_manager
}

gather_package_manager() {
  if [ "$NODE_CHOICE" -eq 2 ] && ! has_cmd node; then
    plan_line "Package manager: left at camp (no Node.js)"
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
    2) plan_line "Python: left at camp" ;;
  esac
}

gather_extras() {
  echo -e "\n${BOLD}Snack table.${NC} Take what you want, leave what you don't."
  if ask_yesno "Install GitHub CLI (gh)?" "y"; then
    WANT_GH_CLI=true; plan_line "GitHub CLI: install"
  else
    plan_line "GitHub CLI: left at camp"
  fi
  if ask_yesno "Install Docker Desktop?" "n"; then
    WANT_DOCKER=true; plan_line "Docker Desktop: install"
  else
    plan_line "Docker Desktop: left at camp"
  fi
  if ask_yesno "Install Postman?" "y"; then
    WANT_POSTMAN=true; plan_line "Postman: install"
  else
    plan_line "Postman: left at camp"
  fi
  if ask_yesno "Install Chrome?" "y"; then
    WANT_CHROME=true; plan_line "Chrome: install"
  else
    plan_line "Chrome: left at camp"
  fi
  if ask_yesno "Install Firefox?" "n"; then
    WANT_FIREFOX=true; plan_line "Firefox: install"
  else
    plan_line "Firefox: left at camp"
  fi
  if ask_yesno "Install jq (JSON CLI tool)?" "y"; then
    WANT_JQ=true; plan_line "jq: install"
  else
    plan_line "jq: left at camp"
  fi
  if ask_yesno "Install Starship (fast, cross-shell prompt)?" "y"; then
    WANT_STARSHIP=true; plan_line "Starship prompt: install"
  else
    plan_line "Starship prompt: left at camp"
  fi
  if ask_yesno "And Claude Desktop? The other brain, in its own window." "y"; then
    WANT_CLAUDE=true; plan_line "Claude Desktop: install"
  else
    plan_line "Claude Desktop: left at camp"
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
    plan_line "git config: left at camp"
  fi
}

gather_ssh_setup() {
  if $PROFILE_MODE; then return; fi
  if ask_yesno "Mint a GitHub SSH key and hand it to gh? No browser, I promise." "n"; then
    GIT_SSH_SETUP=true
    WANT_GH_CLI=true
    plan_line "SSH: mint a key if needed, hand it to gh"
  else
    plan_line "SSH: left at camp"
  fi
}

gather_clone_repos() {
  if ask_yesno "Toss any repos in the basket now?" "n"; then
    CLONE_URLS_RAW=$(ask_text "Repo URL(s), comma-separated" "")
    if [ -z "$CLONE_URLS_RAW" ]; then
      plan_line "Clone repo(s): left at camp (no URL)"
      return
    fi
    CLONE_DIR=$(ask_text "Parent folder to clone into" "$HOME/dev")
    WANT_CLONE=true
    plan_line "Clone repo(s) into $CLONE_DIR: $CLONE_URLS_RAW"
  else
    plan_line "Clone repo(s): left at camp"
  fi
}

# =============================================================================
# EXECUTE phase -- act on the answers gathered above.
# =============================================================================

execute_git() {
  if $GIT_ALREADY_INSTALLED || has_cmd git; then
    walk_past "Git"
    add_summary "Git" "SKIPPED" "$(git --version 2>/dev/null | awk '{print $3}')" "already in the pack"
    return
  fi
  if ! $GIT_WANT_INSTALL; then
    add_summary "Git" "SKIPPED" "-" "$(left_behind)"
    return
  fi
  step "Git..."
  if install_pkg "git" "Git.Git"; then
    ok "Git is in the pack."
    add_summary "Git" "OK" "$(get_version git | awk '{print $3}')" "fresh off the trail"
  else
    slipped "Git"
    add_summary "Git" "FAILED" "-" "install slipped"
  fi
}

zed_present() {
  has_cmd zed && return 0
  [ "$PLATFORM" = "mac" ] && mac_app_installed "Zed.app"
}

code_present() {
  has_cmd code && return 0
  [ "$PLATFORM" = "mac" ] && mac_app_installed "Visual Studio Code.app"
}

cursor_present() {
  has_cmd cursor && return 0
  [ "$PLATFORM" = "mac" ] && mac_app_installed "Cursor.app"
}

execute_ide() {
  install_zed() {
    if zed_present; then
      walk_past "Zed"
      add_summary "Zed" "SKIPPED" "-" "already in the pack"
      return
    fi
    step "Zed..."
    if install_pkg "zed" "ZedIndustries.Zed" "true"; then
      ok "Zed is in the pack."; add_summary "Zed" "OK" "-" "fresh off the trail"
    else
      slipped "Zed"; add_summary "Zed" "FAILED" "-" "install slipped"
    fi
  }
  install_vscode() {
    if code_present; then
      walk_past "VS Code"
      add_summary "VS Code" "SKIPPED" "-" "already in the pack"
    else
      step "VS Code..."
      if install_pkg "visual-studio-code" "Microsoft.VisualStudioCode" "true"; then
        ok "VS Code is in the pack."; add_summary "VS Code" "OK" "-" "fresh off the trail"
      else
        slipped "VS Code"; add_summary "VS Code" "FAILED" "-" "install slipped"
      fi
    fi
    install_vscode_extensions
  }
  install_cursor() {
    if cursor_present; then
      walk_past "Cursor"
      add_summary "Cursor" "SKIPPED" "-" "already in the pack"
      return
    fi
    step "Cursor..."
    if install_pkg "cursor" "Anysphere.Cursor" "true"; then
      ok "Cursor is in the pack."; add_summary "Cursor" "OK" "-" "fresh off the trail"
    else
      slipped "Cursor"; add_summary "Cursor" "FAILED" "-" "install slipped"
    fi
  }
  case $IDE_CHOICE in
    0) install_zed ;;
    1) install_vscode ;;
    2) install_cursor ;;
    3) install_zed; install_vscode ;;
    4) add_summary "IDE" "SKIPPED" "-" "$(left_behind)" ;;
  esac
}

# install_vscode_extensions -- starter pack (Prettier, ESLint, GitLens), run
# right after install_vscode. Needs the `code` CLI on PATH, which a
# freshly-installed VS Code often isn't until the terminal restarts -- in
# that case we hand the command back to the user as a next step instead of
# failing outright.
install_vscode_extensions() {
  if ! $WANT_VSCODE_EXTENSIONS; then
    add_summary "VS Code extensions" "SKIPPED" "-" "$(left_behind)"
    return
  fi
  step "VS Code snack pack..."
  if ! has_cmd code; then
    skip "The code command hasn't caught up yet. Extensions can wait at camp."
    add_summary "VS Code extensions" "SKIPPED" "-" "code CLI not on PATH"
    NEXT_STEPS+=("After a new terminal: code --install-extension esbenp.prettier-vscode && code --install-extension dbaeumer.vscode-eslint && code --install-extension eamodio.gitlens")
    return
  fi
  local exts=(esbenp.prettier-vscode dbaeumer.vscode-eslint eamodio.gitlens)
  local failed=0 skipped=0 installed=0 ext have=""
  have="$(code --list-extensions 2>/dev/null || true)"
  for ext in "${exts[@]}"; do
    if printf '%s\n' "$have" | grep -qx "$ext"; then
      skipped=$((skipped + 1))
    elif code --install-extension "$ext" --force >/dev/null 2>&1; then
      installed=$((installed + 1))
    else
      slipped "$ext"
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -gt 0 ]; then
    add_summary "VS Code extensions" "FAILED" "-" "$installed packed, $skipped already there, $failed slipped"
  elif [ "$installed" -eq 0 ]; then
    walk_past "VS Code extensions"
    add_summary "VS Code extensions" "SKIPPED" "-" "already in the pack"
  else
    ok "Snack pack's in. Prettier, ESLint, GitLens."
    add_summary "VS Code extensions" "OK" "-" "Prettier, ESLint, GitLens"
  fi
}

execute_node() {
  case $NODE_CHOICE in
    0)
      step "nvm..."
      local nvm_ok=false
      if [ "$PLATFORM" = "mac" ]; then
        if [ -d "$HOME/.nvm" ] || has_cmd nvm; then
          walk_past "nvm"; add_summary "nvm" "SKIPPED" "-" "already in the pack"
          nvm_ok=true
        elif curl -fsSL -o "$HOME/.sherpa-nvm-install.sh" https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh && bash "$HOME/.sherpa-nvm-install.sh"; then
          rm -f "$HOME/.sherpa-nvm-install.sh"
          ok "nvm is in the pack."; add_summary "nvm" "OK" "-" "fresh off the trail"
          nvm_ok=true
        else
          rm -f "$HOME/.sherpa-nvm-install.sh"
          slipped "nvm"; add_summary "nvm" "FAILED" "-" "install slipped"
        fi
      else
        if has_cmd nvm; then
          walk_past "nvm-windows"; add_summary "nvm-windows" "SKIPPED" "-" "already in the pack"
          nvm_ok=true
        elif install_pkg "" "CoreyButler.NVMforWindows"; then
          ok "nvm-windows is in the pack."; add_summary "nvm-windows" "OK" "-" "fresh off the trail"
          nvm_ok=true
        else
          slipped "nvm-windows"; add_summary "nvm-windows" "FAILED" "-" "install slipped"
        fi
      fi
      if $nvm_ok; then
        install_node_versions_via_nvm
      else
        add_summary "Node versions" "SKIPPED" "-" "nvm slipped, so versions stayed home"
      fi
      ;;
    1)
      if has_cmd node; then
        walk_past "Node.js"
        add_summary "Node.js" "SKIPPED" "$(get_version node)" "already in the pack"
      else
        step "Node.js LTS..."
        if install_pkg "node@22" "OpenJS.NodeJS.LTS"; then
          ok "Node.js is in the pack."; add_summary "Node.js" "OK" "$(get_version node)" "fresh off the trail"
        else
          slipped "Node.js"; add_summary "Node.js" "FAILED" "-" "install slipped"
        fi
      fi
      ;;
    2) add_summary "Node.js" "SKIPPED" "-" "$(left_behind)" ;;
  esac
}

# Load nvm into the current shell (mac). nvm-windows is a different binary.
load_nvm() {
  if [ "$PLATFORM" = "mac" ]; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  fi
  has_cmd nvm || type nvm >/dev/null 2>&1
}

nvm_install_one() {
  local ver="$1"
  if [ "$ver" = "lts" ]; then
    if [ "$PLATFORM" = "mac" ]; then
      nvm install --lts
    else
      nvm install lts
    fi
  else
    nvm install "$ver"
  fi
}

# nvm version prints "v22.x" when that version is already installed, "N/A" otherwise.
nvm_has() {
  local ver="$1" out=""
  if [ "$ver" = "lts" ]; then
    out="$(nvm version --lts 2>/dev/null || true)"
  else
    out="$(nvm version "$ver" 2>/dev/null || true)"
  fi
  [[ "$out" == v* ]]
}

install_node_versions_via_nvm() {
  step "Node.js versions via nvm..."
  if ! load_nvm; then
    skip "nvm not available in this shell yet — reopen terminal, then install versions."
    add_summary "Node versions" "SKIPPED" "-" "nvm not in PATH yet"
    local cmds=""
    local ver
    for ver in "${NODE_VERSIONS[@]}"; do
      cmds+="nvm install $ver; "
    done
    if [ "$PLATFORM" = "mac" ]; then
      NEXT_STEPS+=("Open a new terminal (or 'source ~/.nvm/nvm.sh'), then: ${cmds}nvm alias default $NODE_DEFAULT && nvm use $NODE_DEFAULT")
    else
      NEXT_STEPS+=("Open a NEW terminal, then: ${cmds}nvm use $NODE_DEFAULT")
    fi
    return
  fi

  local ver installed=0 failed=0 skipped=0
  for ver in "${NODE_VERSIONS[@]}"; do
    if nvm_has "$ver"; then
      walk_past "Node $ver"
      skipped=$((skipped + 1))
    elif nvm_install_one "$ver"; then
      ok "Node $ver is in the pack."
      installed=$((installed + 1))
    else
      slipped "Node $ver"
      failed=$((failed + 1))
    fi
  done

  if [ "$PLATFORM" = "mac" ]; then
    nvm alias default "$NODE_DEFAULT" >/dev/null 2>&1 || true
    nvm use "$NODE_DEFAULT" >/dev/null 2>&1 || true
  else
    nvm use "$NODE_DEFAULT" >/dev/null 2>&1 || true
  fi

  if [ "$failed" -gt 0 ]; then
    add_summary "Node versions" "FAILED" "-" "$installed packed, $skipped already there, $failed slipped"
  elif [ "$installed" -eq 0 ]; then
    add_summary "Node versions" "SKIPPED" "$NODE_DEFAULT" "already in the pack"
  else
    add_summary "Node versions" "OK" "$NODE_DEFAULT" "packed: ${NODE_VERSIONS[*]} (default $NODE_DEFAULT)"
  fi
}

# execute_package_manager -- npm needs nothing extra (it ships with Node).
# pnpm/yarn are activated through corepack, which itself ships with Node
# >=16.9, so this only makes sense once Node is actually on PATH.
execute_package_manager() {
  case $PKG_MANAGER_CHOICE in
    0)
      if has_cmd npm || has_cmd node; then
        if has_cmd npm; then
          walk_past "npm"
          add_summary "Package manager" "SKIPPED" "$(get_version npm)" "already in the pack"
        else
          add_summary "Package manager" "OK" "npm" "tagged along with Node"
        fi
      else
        add_summary "Package manager" "SKIPPED" "-" "Node isn't here, so npm stayed home"
      fi
      ;;
    1)
      if has_cmd pnpm; then
        walk_past "pnpm"
        add_summary "pnpm" "SKIPPED" "$(get_version pnpm)" "already in the pack"
      elif ! has_cmd node; then
        skip "Node isn't here, so pnpm stays home."
        add_summary "pnpm" "SKIPPED" "-" "Node isn't here, so pnpm stayed home"
      else
        step "pnpm via corepack..."
        if corepack enable >/dev/null 2>&1 && corepack prepare pnpm@latest --activate >/dev/null 2>&1; then
          ok "pnpm is in the pack."
          add_summary "pnpm" "OK" "$(get_version pnpm)" "activated via corepack"
          NEXT_STEPS+=("Open a new terminal, then: pnpm --version")
        else
          slipped "pnpm"
          add_summary "pnpm" "FAILED" "-" "corepack slipped"
        fi
      fi
      ;;
    2)
      if has_cmd yarn; then
        walk_past "yarn"
        add_summary "yarn" "SKIPPED" "$(get_version yarn)" "already in the pack"
      elif ! has_cmd node; then
        skip "Node isn't here, so yarn stays home."
        add_summary "yarn" "SKIPPED" "-" "Node isn't here, so yarn stayed home"
      else
        step "yarn via corepack..."
        if corepack enable >/dev/null 2>&1 && corepack prepare yarn@stable --activate >/dev/null 2>&1; then
          ok "yarn is in the pack."
          add_summary "yarn" "OK" "$(get_version yarn)" "activated via corepack"
          NEXT_STEPS+=("Open a new terminal, then: yarn --version")
        else
          slipped "yarn"
          add_summary "yarn" "FAILED" "-" "corepack slipped"
        fi
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
          walk_past "pyenv"; add_summary "pyenv" "SKIPPED" "-" "already in the pack"
        elif install_pkg "pyenv" ""; then
          ok "pyenv is in the pack."; add_summary "pyenv" "OK" "-" "fresh off the trail"
          # Single-quoted on purpose: this is instructional text for the user, not meant to expand.
          # shellcheck disable=SC2016
          NEXT_STEPS+=('Add eval "$(pyenv init -)" to ~/.zshrc, restart terminal, then: pyenv install 3.12.4 && pyenv global 3.12.4')
        else
          slipped "pyenv"; add_summary "pyenv" "FAILED" "-" "install slipped"
        fi
      else
        if has_cmd pyenv; then
          walk_past "pyenv-win"; add_summary "pyenv-win" "SKIPPED" "-" "already in the pack"
        else
          # No reliable winget package as of writing -- use the official installer script.
          if powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
            "Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1' -OutFile \"\$env:TEMP\install-pyenv-win.ps1\"; & \"\$env:TEMP\install-pyenv-win.ps1\""; then
            ok "pyenv-win is in the pack."; add_summary "pyenv-win" "OK" "-" "fresh off the trail"
            NEXT_STEPS+=("Open a NEW terminal, then: pyenv install 3.12.4 && pyenv global 3.12.4")
          else
            slipped "pyenv-win"; add_summary "pyenv-win" "FAILED" "-" "install slipped"
          fi
        fi
      fi
      ;;
    1)
      if has_cmd python3; then
        walk_past "Python"
        add_summary "Python" "SKIPPED" "$(get_version python3)" "already in the pack"
      else
        step "Python 3..."
        if install_pkg "python@3.12" "Python.Python.3.12"; then
          ok "Python is in the pack."; add_summary "Python" "OK" "$(get_version python3)" "fresh off the trail"
        else
          slipped "Python"; add_summary "Python" "FAILED" "-" "install slipped"
        fi
      fi
      ;;
    2) add_summary "Python" "SKIPPED" "-" "$(left_behind)" ;;
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
  EXTRA_FRESH=false
  if ! $want; then
    add_summary "$friendly" "SKIPPED" "-" "$(left_behind)"
    return
  fi
  if has_cmd "$vcmd"; then
    walk_past "$friendly"
    add_summary "$friendly" "SKIPPED" "$(get_version "$vcmd")" "already in the pack"
    return
  fi
  step "$friendly..."
  if install_pkg "$brew_formula" "$winget_id"; then
    ok "$friendly is in the pack."
    add_summary "$friendly" "OK" "$(get_version "$vcmd")" "fresh off the trail"
    EXTRA_FRESH=true
  else
    slipped "$friendly"
    add_summary "$friendly" "FAILED" "-" "install slipped"
  fi
}

# execute_extra_gui <friendly> <already-installed?> <brew-cask> <winget-id> <mac-app-bundle-name>
# Shared logic for GUI apps (cask installs on mac, winget on Windows).
execute_extra_gui() {
  local friendly="$1" want="$2" brew_cask="$3" winget_id="$4" mac_app="$5"
  if ! $want; then
    add_summary "$friendly" "SKIPPED" "-" "$(left_behind)"
    return
  fi
  if [ "$PLATFORM" = "mac" ] && mac_app_installed "$mac_app"; then
    walk_past "$friendly"
    add_summary "$friendly" "SKIPPED" "-" "already in the pack"
    return
  fi
  step "$friendly..."
  if install_pkg "$brew_cask" "$winget_id" "true"; then
    ok "$friendly is in the pack."
    add_summary "$friendly" "OK" "-" "fresh off the trail"
  else
    slipped "$friendly"
    add_summary "$friendly" "FAILED" "-" "install slipped"
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
  execute_extra_gui "Claude Desktop" "$WANT_CLAUDE" "claude" "Anthropic.Claude" "Claude.app"
}

# execute_starship -- single static binary on both platforms via
# execute_extra_cli, then a NEXT_STEPS note for wiring it into the shell
# rc file, since that's a one-line edit we shouldn't make for the user
# without them seeing it first.
execute_starship() {
  execute_extra_cli "Starship" "$WANT_STARSHIP" "starship" "Starship.Starship" "starship"
  if $EXTRA_FRESH && has_cmd starship; then
    local rc_file="$HOME/.bashrc"
    [ "$PLATFORM" = "mac" ] && rc_file="$HOME/.zshrc"
    NEXT_STEPS+=("Enable the Starship prompt: add 'eval \"\$(starship init bash)\"' (swap bash for zsh if that's your shell) to the end of $rc_file, then restart your terminal.")
  fi
}

execute_git_config() {
  if ! $GITCONFIG_NEEDED; then
    if git config --global user.name >/dev/null 2>&1 && git config --global user.email >/dev/null 2>&1; then
      walk_past "git config"
      add_summary "git config" "SKIPPED" "-" "already in the pack"
    else
      add_summary "git config" "SKIPPED" "-" "$(left_behind)"
    fi
    return
  fi
  if git config --global user.name "$GITCONFIG_NAME" && git config --global user.email "$GITCONFIG_EMAIL"; then
    ok "Git now knows you as $GITCONFIG_NAME <$GITCONFIG_EMAIL>."
    add_summary "git config" "OK" "-" "fresh off the trail"
  else
    slipped "git config"
    add_summary "git config" "FAILED" "-" "git config slipped"
  fi
}

execute_gh_auth() {
  if ! $GIT_SSH_SETUP; then return; fi
  if ! has_cmd gh; then
    slipped "GitHub auth"
    add_summary "GitHub auth" "FAILED" "-" "gh not installed"
    return
  fi
  if gh auth status >/dev/null 2>&1; then
    walk_past "GitHub auth"
    add_summary "GitHub auth" "SKIPPED" "-" "already in the pack"
    return
  fi
  step "GitHub authentication..."
  echo -e "  ${GRAY}Create a token at: https://github.com/settings/tokens${NC}"
  echo -e "  ${GRAY}Scopes: repo, admin:public_key (or read:org + admin:public_key)${NC}"
  local token=""
  read -rs -p "  Paste GitHub token (hidden): " token
  echo ""
  if [ -z "$token" ]; then
    slipped "GitHub auth"
    add_summary "GitHub auth" "FAILED" "-" "no token provided"
    return
  fi
  if printf '%s' "$token" | gh auth login --with-token >/dev/null 2>&1; then
    ok "GitHub authenticated."
    add_summary "GitHub auth" "OK" "-" "authenticated via token"
  else
    slipped "GitHub auth"
    add_summary "GitHub auth" "FAILED" "-" "gh auth login failed"
  fi
}

execute_ssh_setup() {
  if ! $GIT_SSH_SETUP; then
    add_summary "SSH key" "SKIPPED" "-" "$(left_behind)"
    return
  fi
  if ! has_cmd gh; then
    slipped "SSH key"
    add_summary "SSH key" "FAILED" "-" "gh not installed"
    return
  fi

  execute_gh_auth
  if ! gh auth status >/dev/null 2>&1; then
    slipped "SSH key"
    add_summary "SSH key" "FAILED" "-" "gh not authenticated"
    return
  fi

  step "SSH key..."
  local key_path="$HOME/.ssh/id_ed25519"
  local email
  email="${GITCONFIG_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
  if [ -f "$key_path" ]; then
    walk_past "SSH key"
    add_summary "SSH key" "SKIPPED" "-" "already in the pack"
  else
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if ssh-keygen -t ed25519 -C "${email:-sherpa@$(hostname)}" -f "$key_path" -N ""; then
      ok "Minted an SSH key at $key_path"
      add_summary "SSH key" "OK" "-" "fresh off the trail"
    else
      slipped "SSH key"
      add_summary "SSH key" "FAILED" "-" "ssh-keygen slipped"
      return
    fi
  fi

  if [ ! -f "${key_path}.pub" ]; then
    slipped "SSH upload"
    add_summary "SSH upload" "FAILED" "-" "missing public key"
    return
  fi

  local key_blob title
  key_blob="$(awk '{print $2}' "${key_path}.pub" 2>/dev/null || true)"
  if [ -n "$key_blob" ] && gh ssh-key list 2>/dev/null | grep -q "$key_blob"; then
    walk_past "SSH upload"
    add_summary "SSH upload" "SKIPPED" "-" "already in the pack"
    return
  fi

  step "Handing the SSH key to GitHub..."
  title="$(hostname)-sherpa"
  if gh ssh-key add "${key_path}.pub" -t "$title" >/dev/null 2>&1; then
    ok "GitHub has the key."
    add_summary "SSH upload" "OK" "-" "uploaded via gh"
  else
    slipped "SSH upload"
    add_summary "SSH upload" "FAILED" "-" "gh ssh-key add slipped"
  fi
}

# One repo is one box on the yak. A failed clone does not stop the next repo.
clone_one() {
  local raw="$1" url name dest
  url="$(resolve_repo_url "$raw")"
  name="$(basename "$url" .git)"
  dest="$CLONE_DIR/$name"
  if [ -d "$dest/.git" ]; then
    walk_past "$name"
    add_summary "$name" "SKIPPED" "-" "already in the pack"
    return 0
  fi
  if git clone "$url" "$dest"; then
    ok "$name is in the basket ($dest)."
    add_summary "$name" "OK" "-" "fresh off the trail"
  else
    slipped "$name"
    add_summary "$name" "FAILED" "-" "clone slipped"
  fi
}

execute_clone_repos() {
  if ! $WANT_CLONE; then
    add_summary "Clone repo(s)" "SKIPPED" "-" "$(left_behind)"
    return
  fi
  step "Repos..."
  mkdir -p "$CLONE_DIR" || slipped "clone folder"
  local repo url
  if [ ${#CLONE_REPOS[@]} -gt 0 ]; then
    for repo in "${CLONE_REPOS[@]}"; do
      clone_one "$repo" || true
    done
    return
  fi
  [ -n "${CLONE_URLS_RAW:-}" ] || return
  local urls=()
  IFS=',' read -ra urls <<< "$CLONE_URLS_RAW"
  [ "${#urls[@]}" -gt 0 ] || return
  for url in "${urls[@]}"; do
    url=$(echo "$url" | xargs)
    [ -z "$url" ] && continue
    clone_one "$url" || true
  done
}

# =============================================================================
# Main
# =============================================================================

# One random camp note, then SMILE every time.
# The note uses the terminal's own text color so it stays readable on a
# light background. SMILE is bright yellow, which still shows up there.
sign_off() {
  local gold=$'\033[1;93m'
  local notes=(
    "Have a glass of water."
    "Drop your shoulders."
    "Unclench your jaw."
    "Blink. You forgot."
    "Roll your shoulders back."
    "Look out a window for a second."
    "Wiggle your toes. They're still on the job."
    "The yak sat down. You can too."
    "Drink something. The summit can wait."
    "Your face is doing the concentrating thing. Knock it off."
  )
  local note="${notes[$((RANDOM % ${#notes[@]}))]}"
  echo ""
  echo -e "${GRAY}A note from camp:${NC}"
  echo -e "${BOLD}   ${note}${NC}"
  echo ""
  echo -e "${gold}"
  cat << 'SMILE'
   ███    █   █   ███   █     ███
   █      ██ ██    █    █     █
   ███    █ █ █    █    █     ███
     █    █   █    █    █     █
   ███    █   █   ███   ███   ███
SMILE
  echo -e "${NC}"
  echo -e "${GRAY}The mountain will still be there when you get back.${NC}"
  echo ""
}

farewell() {
  local any=false s
  if [ ${#SUMMARY_STATUS[@]} -gt 0 ]; then
    for s in "${SUMMARY_STATUS[@]}"; do
      [ "$s" = "FAILED" ] && any=true
    done
  fi
  echo ""
  if $any; then
    echo -e "${YELLOW}Some things slipped off the yak. The rest still made it to camp.${NC}"
    echo -e "${GRAY}Run me again. What's already packed gets a wave, not another receipt.${NC}"
  elif $PROFILE_MODE; then
    echo -e "${GREEN}Menu's served. Try not to start a food fight.${NC}"
  else
    echo -e "${GREEN}Basket's packed. Go build something ridiculous.${NC}"
  fi
  sign_off
  $any && exit 1
  exit 0
}

main() {
  parse_args "$@"
  banner
  detect_platform

  if $PROFILE_MODE; then
    load_profile
    echo -e "\n${CYAN}${BOLD}Catered.${NC} The menu is ${BOLD}${PROFILE_NAME}${NC}."
    echo -e "${GRAY}No sending plates back. If the soup spills, dessert still shows up.${NC}"
    echo -e "${GRAY}Anything already on the table gets a nod, not a second serving.${NC}\n"
    ensure_pkg_manager
    echo -e "${GRAY}Glance at the menu, then we cook. Your name and email are the only personal questions.${NC}\n"
    plan_from_profile
    print_plan_and_confirm
    gather_git_config_interactive
  else
    echo -e "\n${CYAN}${BOLD}Picnic.${NC} You pack the basket."
    echo -e "${GRAY}Say no to anything you don't want to carry. If a jar breaks, the sandwiches still make it.${NC}\n"
    ensure_pkg_manager
    echo -e "${GRAY}A few questions first. Nothing else gets packed until you say so.${NC}\n"
    gather_git
    gather_ide
    gather_node
    gather_python
    gather_extras
    gather_git_config
    gather_ssh_setup
    gather_clone_repos
    print_plan_and_confirm
  fi

  # No set -e anywhere in this script. One spilled dish must not end the meal,
  # so each of these keeps going even when the one before it returns sad.
  execute_git || true
  execute_ide || true
  execute_node || true
  execute_package_manager || true
  execute_python || true
  execute_extras || true
  execute_git_config || true
  execute_ssh_setup || true
  execute_clone_repos || true

  print_summary_table
  echo -e "${GRAY}Pop a new terminal so the new gear can find the trail, then poke at:${NC}"
  echo -e "  ${CYAN}git --version${NC}"
  echo -e "  ${CYAN}node --version${NC}"
  echo -e "  ${CYAN}python3 --version${NC}"
  case $PKG_MANAGER_CHOICE in
    1) echo -e "  ${CYAN}pnpm --version${NC}" ;;
    2) echo -e "  ${CYAN}yarn --version${NC}" ;;
  esac
  $WANT_STARSHIP && echo -e "  ${CYAN}starship --version${NC}"
  farewell
}

main "$@"