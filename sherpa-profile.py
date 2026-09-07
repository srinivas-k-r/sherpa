#!/usr/bin/env python3
"""
Parse sherpa.yml and emit shell assignments for sherpa-setup.sh / sherpa-setup.ps1.

No third-party dependencies — handles the sherpa profile schema only.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def _strip_inline_comment(raw: str) -> str:
    in_single = False
    in_double = False
    for i, ch in enumerate(raw):
        if ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "'" and not in_double:
            in_single = not in_single
        elif ch == "#" and not in_single and not in_double:
            return raw[:i].rstrip()
    return raw.strip()


def _parse_scalar(raw: str) -> Any:
    raw = _strip_inline_comment(raw.strip())
    if not raw or raw in ("~", "null", "Null", "NULL"):
        return None
    if raw in ("true", "True", "yes", "Yes"):
        return True
    if raw in ("false", "False", "no", "No"):
        return False
    if raw.startswith('"') or raw.startswith("'"):
        return _strip_quotes(raw)
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return _strip_quotes(raw)


def parse_yaml(text: str) -> dict[str, Any]:
    root: dict[str, Any] = {}
    stack: list[tuple[int, Any]] = [(0, root)]
    lines = text.splitlines()

    def next_content_line(start: int) -> str | None:
        for candidate in lines[start:]:
            if candidate.strip() and not candidate.lstrip().startswith("#"):
                return candidate
        return None

    for lineno, line in enumerate(lines, start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        indent = len(line) - len(line.lstrip(" "))
        if indent % 2 != 0:
            raise ValueError(f"line {lineno}: indent must be multiples of 2 spaces")

        content = line.strip()

        while len(stack) > 1 and indent < stack[-1][0]:
            stack.pop()

        parent = stack[-1][1]

        if content.startswith("- "):
            if not isinstance(parent, list):
                raise ValueError(f"line {lineno}: list item outside of a list")
            parent.append(_parse_scalar(content[2:]))
            continue

        if ":" not in content:
            raise ValueError(f"line {lineno}: expected key: value")

        key, raw_value = content.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()

        if raw_value == "":
            upcoming = next_content_line(lineno)
            if upcoming is not None:
                upcoming_indent = len(upcoming) - len(upcoming.lstrip(" "))
                upcoming_content = upcoming.strip()
                if upcoming_indent == indent + 2 and upcoming_content.startswith("- "):
                    new_container: Any = []
                else:
                    new_container = {}
            else:
                new_container = {}
            if isinstance(parent, dict):
                parent[key] = new_container
            else:
                raise ValueError(f"line {lineno}: nested mapping inside list not supported")
            stack.append((indent + 2, new_container))
            continue

        value = _parse_scalar(raw_value)
        if isinstance(parent, dict):
            parent[key] = value
        else:
            raise ValueError(f"line {lineno}: key/value inside list not supported")

    return root


def _get(data: dict[str, Any], *keys: str, default: Any = None) -> Any:
    cur: Any = data
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def _choice_map(value: str, mapping: dict[str, int], field: str) -> int:
    key = str(value).strip().lower()
    if key not in mapping:
        allowed = ", ".join(sorted(mapping))
        raise ValueError(f"invalid {field}: {value!r} (expected one of: {allowed})")
    return mapping[key]


def _extras_flags(extras: Any) -> dict[str, bool]:
    known = {
        "gh": "WANT_GH_CLI",
        "docker": "WANT_DOCKER",
        "postman": "WANT_POSTMAN",
        "chrome": "WANT_CHROME",
        "firefox": "WANT_FIREFOX",
        "jq": "WANT_JQ",
        "starship": "WANT_STARSHIP",
    }
    flags = {name: False for name in known.values()}
    if not extras:
        return flags
    if not isinstance(extras, list):
        raise ValueError("extras must be a list")
    for item in extras:
        key = str(item).strip().lower()
        if key not in known:
            allowed = ", ".join(sorted(known))
            raise ValueError(f"unknown extra: {item!r} (expected one of: {allowed})")
        flags[known[key]] = True
    return flags


def build_profile(path: Path) -> dict[str, Any]:
    data = parse_yaml(path.read_text(encoding="utf-8"))

    node_manager = _choice_map(
        _get(data, "node", "manager", default="skip"),
        {"nvm": 0, "direct": 1, "skip": 2},
        "node.manager",
    )
    python_manager = _choice_map(
        _get(data, "python", "manager", default="skip"),
        {"pyenv": 0, "direct": 1, "skip": 2},
        "python.manager",
    )
    ide_choice = _choice_map(
        _get(data, "ide", "choice", default="skip"),
        {"zed": 0, "vscode": 1, "both": 2, "skip": 3},
        "ide.choice",
    )
    pkg_manager = _choice_map(
        _get(data, "package_manager", default="npm"),
        {"npm": 0, "pnpm": 1, "yarn": 2},
        "package_manager",
    )

    extras = _extras_flags(_get(data, "extras", default=[]))

    git_protocol = str(_get(data, "git", "protocol", default="ssh")).lower()
    git_ssh = _get(data, "git", "ssh", default=None)
    if git_ssh is None:
        git_ssh = git_protocol == "ssh"

    clone_dir = _get(data, "git", "clone", "dir", default="~/dev")
    repos = _get(data, "git", "clone", "repos", default=[]) or []
    if not isinstance(repos, list):
        raise ValueError("git.clone.repos must be a list")

    want_clone = len(repos) > 0
    if want_clone and git_ssh:
        extras["WANT_GH_CLI"] = True

    return {
        "PROFILE_NAME": str(_get(data, "name", default=path.stem)),
        "NODE_CHOICE": node_manager,
        "NODE_VERSION": str(_get(data, "node", "version", default="lts")),
        "PYTHON_CHOICE": python_manager,
        "PYTHON_VERSION": str(_get(data, "python", "version", default="3.12.4")),
        "IDE_CHOICE": ide_choice,
        "WANT_VSCODE_EXTENSIONS": bool(_get(data, "ide", "vscode_extensions", default=False)),
        "PKG_MANAGER_CHOICE": pkg_manager,
        "GIT_SSH_SETUP": bool(git_ssh),
        "WANT_CLONE": want_clone,
        "CLONE_DIR": str(clone_dir),
        "CLONE_REPOS": [str(r).strip() for r in repos if str(r).strip()],
        **extras,
    }


def _shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def emit_bash(profile: dict[str, Any]) -> None:
  lines = [
      "PROFILE_MODE=true",
      f"PROFILE_NAME={_shell_quote(profile['PROFILE_NAME'])}",
      f"NODE_CHOICE={profile['NODE_CHOICE']}",
      f"NODE_VERSION={_shell_quote(profile['NODE_VERSION'])}",
      f"PYTHON_CHOICE={profile['PYTHON_CHOICE']}",
      f"PYTHON_VERSION={_shell_quote(profile['PYTHON_VERSION'])}",
      f"IDE_CHOICE={profile['IDE_CHOICE']}",
      f"WANT_VSCODE_EXTENSIONS={'true' if profile['WANT_VSCODE_EXTENSIONS'] else 'false'}",
      f"PKG_MANAGER_CHOICE={profile['PKG_MANAGER_CHOICE']}",
      f"GIT_SSH_SETUP={'true' if profile['GIT_SSH_SETUP'] else 'false'}",
      f"WANT_CLONE={'true' if profile['WANT_CLONE'] else 'false'}",
      f"CLONE_DIR={_shell_quote(profile['CLONE_DIR'])}",
  ]

  for flag in (
      "WANT_GH_CLI", "WANT_DOCKER", "WANT_POSTMAN", "WANT_CHROME",
      "WANT_FIREFOX", "WANT_JQ", "WANT_STARSHIP",
  ):
      lines.append(f"{flag}={'true' if profile[flag] else 'false'}")

  repos = profile["CLONE_REPOS"]
  if repos:
      lines.append(f"CLONE_REPOS=({' '.join(_shell_quote(r) for r in repos)})")
  else:
      lines.append("CLONE_REPOS=()")

  print("\n".join(lines))


def emit_powershell(profile: dict[str, Any]) -> None:
    def ps_bool(value: bool) -> str:
        return "$true" if value else "$false"

    def ps_quote(value: str) -> str:
        return "'" + value.replace("'", "''") + "'"

    repos = ", ".join(ps_quote(r) for r in profile["CLONE_REPOS"])
    print(f"$script:ProfileMode = $true")
    print(f"$script:ProfileName = {ps_quote(profile['PROFILE_NAME'])}")
    print(f"$script:NodeChoice = {profile['NODE_CHOICE']}")
    print(f"$script:NodeVersion = {ps_quote(profile['NODE_VERSION'])}")
    print(f"$script:PythonChoice = {profile['PYTHON_CHOICE']}")
    print(f"$script:PythonVersion = {ps_quote(profile['PYTHON_VERSION'])}")
    print(f"$script:IdeChoice = {profile['IDE_CHOICE']}")
    print(f"$script:WantVsCodeExtensions = {ps_bool(profile['WANT_VSCODE_EXTENSIONS'])}")
    print(f"$script:PkgManagerChoice = {profile['PKG_MANAGER_CHOICE']}")
    print(f"$script:GitSshSetup = {ps_bool(profile['GIT_SSH_SETUP'])}")
    print(f"$script:WantClone = {ps_bool(profile['WANT_CLONE'])}")
    print(f"$script:CloneDir = {ps_quote(profile['CLONE_DIR'])}")
    print(f"$script:CloneRepos = @({repos})")

    for flag in (
        "WantGhCli", "WantDocker", "WantPostman", "WantChrome",
        "WantFirefox", "WantJq", "WantStarship",
    ):
        key = {
            "WantGhCli": "WANT_GH_CLI",
            "WantDocker": "WANT_DOCKER",
            "WantPostman": "WANT_POSTMAN",
            "WantChrome": "WANT_CHROME",
            "WantFirefox": "WANT_FIREFOX",
            "WantJq": "WANT_JQ",
            "WantStarship": "WANT_STARSHIP",
        }[flag]
        print(f"$script:{flag} = {ps_bool(profile[key])}")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sherpa-profile.py <profile.yml> <bash|powershell>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    target = sys.argv[2].lower()
    if not path.is_file():
        print(f"profile not found: {path}", file=sys.stderr)
        return 1

    try:
        profile = build_profile(path)
    except ValueError as exc:
        print(f"profile error: {exc}", file=sys.stderr)
        return 1

    if target == "bash":
        emit_bash(profile)
    elif target in ("powershell", "ps1"):
        emit_powershell(profile)
    else:
        print(f"unknown target: {target}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
