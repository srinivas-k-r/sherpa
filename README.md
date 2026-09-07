# 🏔️ Sherpa

> **Let me carry the heavy gear.**

Sherpa is an interactive developer-machine bootstrapper for **macOS and Windows**.

Instead of installing a fixed list of tools, Sherpa asks what you actually want, shows you the complete installation plan, and only then executes it.

### Why Sherpa?

Setting up a new development machine usually means installing a long list of tools, remembering package-manager commands, configuring Git, setting up SSH keys, and cloning repositories.

Sherpa turns that into one guided setup experience.

```text
GATHER → PLAN → CONFIRM → EXECUTE → SUMMARY
```

You decide what gets installed. Sherpa handles the heavy lifting.

---

## ✨ Features

* 🖥️ **Cross-platform**

  * macOS
  * Windows
* 📋 **Interactive setup**

  * Choose exactly what you want installed
* 🔍 **Plan before execution**

  * Review the complete plan before installation starts
* 🧰 **Developer essentials**

  * Git
  * Node.js
  * npm / pnpm / Yarn
  * Python
  * GitHub CLI
  * Docker Desktop
  * Postman
  * Chrome
  * Firefox
  * jq
  * Starship
* 💻 **Editors**

  * VS Code
  * Zed
  * VS Code extensions: Prettier, ESLint, GitLens
* 🔐 **Git configuration**

  * Configure `user.name`
  * Configure `user.email`
* 🔑 **SSH setup**

  * Generate an `ed25519` SSH key
  * Copy the public key to the clipboard
  * Optionally open GitHub's SSH-key settings
* 📦 **Node version management**

  * nvm on macOS
  * nvm-windows on Windows
  * Direct Node.js LTS installation
* 🐍 **Python version management**

  * pyenv on macOS
  * pyenv-win on Windows
  * Direct Python installation
* 📁 **Repository cloning**

  * Clone one or more repositories into a chosen directory
* 📊 **Installation summary**

  * Shows `OK`, `SKIPPED`, or `FAILED`
  * Displays versions and useful next steps
* 🏔️ **A little mountain personality**

  * ASCII mountain banner
  * Random mountain facts

---

## 🖥️ Supported Platforms

| Platform | Script             | Terminal   |
| -------- | ------------------ | ---------- |
| macOS    | `sherpa-setup.sh`  | Terminal   |
| Windows  | `sherpa-setup.ps1` | PowerShell |
| Windows  | `sherpa-setup.sh`  | Git Bash   |

The Bash version supports macOS natively and Windows through Git Bash. The PowerShell version provides a native Windows experience.

---

## 🚀 Quick Start

### macOS

Clone the repository:

```bash
git clone <YOUR_REPOSITORY_URL>
cd sherpa
```

Make the script executable:

```bash
chmod +x sherpa-setup.sh
```

Run interactively:

```bash
./sherpa-setup.sh
```

Or apply a profile file (team / personal stack):

```bash
./sherpa-setup.sh --profile sherpa.yml
```

---

### Windows — PowerShell

Clone the repository:

```powershell
git clone <YOUR_REPOSITORY_URL>
cd sherpa
```

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\sherpa-setup.ps1
```

Or apply a profile:

```powershell
.\sherpa-setup.ps1 -Profile sherpa.yml
```

The execution-policy change only applies to the current PowerShell process.

---

### Windows — Git Bash

If you prefer Git Bash:

```bash
git clone <YOUR_REPOSITORY_URL>
cd sherpa
./sherpa-setup.sh
```

---

## 📄 Profile files (`sherpa.yml`)

Instead of answering the wizard every time, you can share a **profile file** that describes the stack to install.

```bash
./sherpa-setup.sh --profile sherpa.yml
```

Sherpa reads the file, prints a plan, asks for confirmation, then installs. You still get prompted for personal details (git name/email, GitHub token for SSH) — those never belong in a shared file.

### Example profile

See [`sherpa.yml`](sherpa.yml) in this repo. A minimal team profile looks like:

```yaml
version: 1
name: acme-frontend

node:
  manager: nvm
  versions: "18|20|22"   # pipe, YAML list, or single "22"
  default: "22"

package_manager: pnpm

extras:
  - gh
  - jq

git:
  protocol: ssh
  clone:
    dir: ~/dev
    repos:
      - acme/web        # → git@github.com:acme/web.git
```

### Sharing via Slack (no git repo required)

Zip these files and post to your internal `#eng-onboarding` channel:

**macOS (no Python needed):**

```text
onboarding.zip
├── sherpa-setup.sh
└── sherpa.yml
```

**Windows:**

```text
onboarding.zip
├── sherpa-setup.ps1
├── sherpa-profile.py     # still used on Windows for now
└── sherpa.yml
```

New hire:

```bash
unzip onboarding.zip && cd onboarding
./sherpa-setup.sh --profile sherpa.yml
```

Later, when the team is ready, move `sherpa.yml` into a git repo — same file, better delivery.

### SSH setup (terminal only)

When `git.protocol: ssh` is set (or repos are listed), Sherpa:

1. Installs `gh` if listed in `extras` (auto-enabled when cloning via SSH)
2. Prompts for a GitHub token in the terminal
3. Generates an SSH key if needed
4. Uploads it with `gh ssh-key add` — no browser, no clipboard
5. Clones repos via `git@github.com:...`

---

## 🧭 How It Works

Sherpa intentionally separates configuration from execution.

### 1. Gather

Sherpa asks you what you want.

For example:

```text
? Which IDE would you like to install?

> Zed
  VS Code
  Both
  Skip
```

It collects your choices without immediately executing the selected installations.

### 2. Plan

Sherpa builds a human-readable plan:

```text
=================== Plan =====================
Here's what I'm about to do:
  - Git: already installed
  - IDE: install VS Code
  - VS Code extensions: install Prettier, ESLint, GitLens
  - Node.js: install via nvm
  - Package manager: pnpm
  - Python: install via pyenv
  - GitHub CLI: install
  - Docker Desktop: skip
================================================
```

You then get a final confirmation:

```text
? Proceed? [Y/n]
```

### 3. Execute

Only after confirmation does Sherpa perform the requested installations.

Each operation reports its result:

```text
>> GitHub CLI...
   [OK] GitHub CLI installed.

>> Docker Desktop...
   [SKIP] user chose Skip

>> Python...
   [FAILED] Python install failed.
```

### 4. Summary

At the end, Sherpa prints a summary of what happened and any manual follow-up steps.

---

## 🧰 What Can Be Installed?

### Git

Sherpa detects whether Git is already installed and only installs it when needed.

### IDEs

Choose:

* Zed
* VS Code
* Both
* Skip

For VS Code, Sherpa can optionally install:

* Prettier
* ESLint
* GitLens

### Node.js

Choose:

* `nvm` / `nvm-windows`
* Direct Node.js LTS installation
* Skip

For package management:

* npm
* pnpm
* Yarn

pnpm and Yarn are enabled through Corepack.

### Python

Choose:

* `pyenv` / `pyenv-win`
* Direct Python installation
* Skip

### Optional Tools

Sherpa can also install:

* GitHub CLI (`gh`)
* Docker Desktop
* Postman
* Google Chrome
* Firefox
* jq
* Starship

---

## 🔐 Git & SSH Setup

Sherpa can configure:

```bash
git config --global user.name
git config --global user.email
```

For SSH (interactive mode or profiles with `git.protocol: ssh`):

1. Authenticate `gh` with a token pasted in the terminal
2. Generate an Ed25519 key at `~/.ssh/id_ed25519` (if missing)
3. Upload the public key with `gh ssh-key add`

Sherpa will **not overwrite an existing `id_ed25519` key**.

---

## 📦 Clone Repositories

Sherpa can clone multiple repositories during setup.

For example:

```text
Repo URL(s), comma-separated:
git@github.com:org/project-a.git,git@github.com:org/project-b.git

Parent folder to clone into:
~/dev
```

Repositories are cloned into the selected parent directory.

---

## ⚠️ Important Notes

### Package managers

Sherpa relies on:

* **Homebrew** on macOS
* **winget** on Windows

If Homebrew is not installed on macOS, Sherpa offers to install it.

On Windows, `winget` must be available. It is normally provided through Microsoft's App Installer.

### PATH changes

Some installations modify your `PATH`.

After Sherpa finishes, close and reopen your terminal before using newly installed commands.

For example:

```bash
git --version
node --version
python3 --version
```

Depending on your package-manager selection:

```bash
pnpm --version
```

or:

```bash
yarn --version
```

### nvm / pyenv

Version managers generally require a new shell before their commands become available.

Sherpa prints the required follow-up commands when additional shell configuration is needed.

### Internet connection

Sherpa installs packages using external package managers and installer scripts, so an active internet connection is required.

---

## 🛡️ Safety Philosophy

Sherpa is designed around **visibility before execution**.

The intended flow is:

```text
Questions
   ↓
Installation Plan
   ↓
User Confirmation
   ↓
Installation
   ↓
Summary
```

You can answer the questions and review the proposed plan before the main installation phase begins.

> **Note:** package-manager bootstrapping is a prerequisite to the main Gather phase. For example, the macOS script may install Homebrew if it is missing.

Pressing `Ctrl+C` during the main Gather/Plan flow stops Sherpa without proceeding with the requested installations. If an earlier prerequisite installation has already happened, that change remains.

---

## 🗂️ Project Structure

```text
.
├── README.md
├── sherpa.yml            # example profile
├── sherpa-profile.py     # profile parser (no dependencies)
├── sherpa-setup.sh       # macOS + Git Bash implementation
├── sherpa-setup.ps1      # Windows PowerShell implementation
├── LICENSE
└── .gitignore
```

The Bash implementation is organized into:

```text
Config & globals
      ↓
UI helpers
      ↓
Platform helpers
      ↓
Gather functions
      ↓
Execute functions
      ↓
Main
```

Each installation area follows a `Gather_*` / `Execute_*` pattern, making it easier to split the project into modules in the future.

---

## 🧪 Verification

Before submitting changes, verify the Bash script syntax:

```bash
bash -n sherpa-setup.sh
```

For Windows, run the PowerShell script in a Windows PowerShell environment and verify the complete interactive flow.

---

## 🛣️ Roadmap

Potential future improvements:

* [ ] Dry-run / non-interactive mode
* [x] Configuration file support (`sherpa.yml` + `--profile`)
* [ ] `--minimal` / `--full` setup profiles
* [ ] Linux support
* [ ] Better package-manager detection
* [ ] Idempotent installation checks for every tool
* [ ] Modular tool registry
* [ ] Automated tests
* [ ] CI validation for both scripts
* [ ] Logging to a file
* [ ] Custom tool definitions
* [ ] Homebrew / winget package manifest generation

---

## 🤝 Contributing

Contributions are welcome.

When adding a new tool, try to follow the existing pattern:

1. Add configuration state.
2. Add a Gather step.
3. Add an Execute step.
4. Add installation status to the summary.
5. Add any required follow-up instructions to `NextSteps`.
6. Update this README.

Keep the separation between **gathering user intent** and **executing changes** intact.

---

## 📄 License

This project is licensed under the MIT License. See `LICENSE` for details.

---

## 🏔️ Why "Sherpa"?

A Sherpa carries the heavy gear so you can focus on the climb.

That's exactly what this script is meant to do for a new development machine.

**You choose the destination. Sherpa carries the setup.**
