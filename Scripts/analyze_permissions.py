#!/usr/bin/env python3
"""Analyze recent Claude Code transcripts to suggest a permission allowlist.

Scans the 50 most-recently-modified JSONL files under ~/.claude/projects/,
counts Bash + MCP tool calls, filters to safe read-only commands that aren't
already auto-allowed by the harness, and prints a prioritized table.

Run:
    python3 Scripts/analyze_permissions.py
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

PROJECTS = Path.home() / ".claude" / "projects"
MAX_FILES = 50

# Auto-allowed by the harness — never propose these. Source: skill instructions.
AUTO_ANY_ARGS = {
    "cal", "uptime", "cat", "head", "tail", "wc", "stat", "strings", "hexdump",
    "od", "nl", "id", "uname", "free", "df", "du", "locale", "groups", "nproc",
    "basename", "dirname", "realpath", "cut", "paste", "tr", "column", "tac",
    "rev", "fold", "expand", "unexpand", "fmt", "comm", "cmp", "numfmt",
    "readlink", "diff", "true", "false", "sleep", "which", "type", "expr",
    "test", "getconf", "seq", "tsort", "pr", "echo", "printf", "ls", "cd",
    "find",
}
AUTO_ZERO_ARGS = {"pwd", "whoami", "alias"}
AUTO_SAFE_FLAGS = {
    "xargs", "file", "sed", "sort", "man", "help", "netstat", "ps", "base64",
    "grep", "egrep", "fgrep", "sha256sum", "sha1sum", "md5sum", "tree", "date",
    "hostname", "info", "lsof", "pgrep", "tput", "ss", "fd", "fdfind", "aki",
    "rg", "jq", "uniq", "history", "arch", "ifconfig", "pyright",
}
GIT_READ = {
    "status", "log", "diff", "show", "blame", "branch", "tag", "remote",
    "ls-files", "ls-remote", "rev-parse", "describe", "reflog", "shortlog",
    "cat-file", "for-each-ref",
}
GH_READ = {
    "pr", "issue", "run", "workflow", "repo", "release", "api", "auth",
    "browse", "search",
}

# Categorically dangerous — never allowlist.
ARBITRARY_EXEC = {
    "python", "python3", "node", "bun", "deno", "ruby", "perl", "php", "lua",
    "bash", "sh", "zsh", "fish", "eval", "exec", "ssh", "npx", "bunx", "uvx",
    "sudo", "make", "just",
}

# Commands that mutate / push / install — never allowlist (or include any flag).
MUTATING_PREFIX = {
    "rm", "mv", "cp", "ln", "mkdir", "rmdir", "touch", "chmod", "chown",
    "kill", "killall", "shutdown", "reboot", "halt", "umount", "mount",
    "git push", "git commit", "git merge", "git rebase", "git reset",
    "git checkout", "git clean", "git pull", "git fetch", "git stash",
    "git restore", "git add", "git rm", "git mv", "git apply", "git revert",
    "git cherry-pick", "git tag", "git remote add", "git remote set-url",
    "git worktree add", "git worktree remove",
    "gh pr create", "gh pr edit", "gh pr merge", "gh pr close", "gh pr review",
    "gh pr comment", "gh issue create", "gh issue close", "gh issue edit",
    "gh issue comment", "gh release create", "gh release edit",
    "npm install", "npm i ", "yarn add", "yarn install", "bun install",
    "bun add", "pip install", "cargo install", "brew install", "brew upgrade",
    "docker run", "docker exec", "docker rm", "docker stop", "docker kill",
    "docker pull", "docker push", "docker build",
    "kubectl apply", "kubectl delete", "kubectl exec", "kubectl create",
    "kubectl edit", "kubectl patch", "kubectl rollout",
    "xcodebuild",  # has side effects (builds artifacts) and is slow; user can allowlist explicitly
    "xcrun devicectl device install", "xcrun devicectl device uninstall",
    "xcrun devicectl device process launch",
    "xcrun devicectl device process terminate",
    "tmux kill", "tmux new", "tmux send-keys",
    "pm2 start", "pm2 stop", "pm2 restart", "pm2 delete", "pm2 save",
}


def leading_command_pair(cmd: str) -> tuple[str, str] | None:
    """Return (head, subcommand) for the leading command in a shell string.

    Strips env-var prefixes (FOO=bar), source-then-&&, leading `sudo`/`timeout`,
    and stops at the first real command. Returns None for empty.
    """
    s = cmd.strip()
    if not s:
        return None

    # Drop common prefix wrappers.
    while True:
        if m := re.match(r"^[A-Z_][A-Z0-9_]*=\S+\s+", s):
            s = s[m.end():]
            continue
        if m := re.match(r"^(sudo|nohup|time|env)\s+", s):
            s = s[m.end():]
            continue
        if m := re.match(r"^timeout(?:\s+--?\S+)*\s+\d+\S*\s+", s):
            s = s[m.end():]
            continue
        if m := re.match(r"^source\s+\S+\s+&&\s+", s):
            s = s[m.end():]
            continue
        break

    # Just take the first token chain (head + optional subcommand).
    tokens = re.split(r"\s+", s, maxsplit=2)
    if not tokens:
        return None
    head = tokens[0]
    # Strip path prefix: /usr/bin/git → git
    head = head.rsplit("/", 1)[-1]
    sub = tokens[1] if len(tokens) > 1 else ""
    # Subcommands shouldn't be flags or paths.
    if sub.startswith("-") or "/" in sub or "*" in sub or "{" in sub:
        sub = ""
    return (head, sub)


def is_arbitrary_exec(head: str) -> bool:
    return head in ARBITRARY_EXEC


def is_mutating(head: str, sub: str) -> bool:
    pair = f"{head} {sub}".strip()
    for prefix in MUTATING_PREFIX:
        if pair == prefix or pair.startswith(prefix + " ") or pair.startswith(prefix):
            return True
    return False


def is_auto_allowed(head: str, sub: str) -> bool:
    if head in AUTO_ANY_ARGS:
        return True
    if head in AUTO_ZERO_ARGS and not sub:
        return True
    if head in AUTO_SAFE_FLAGS:
        return True
    if head == "git" and sub in GIT_READ:
        return True
    if head == "gh" and sub in GH_READ:
        # gh has many subcommands; the harness auto-allows the read-only ones,
        # so don't propose them.
        return True
    if head == "docker" and sub in {"ps", "images", "logs", "inspect"}:
        return True
    return False


def pattern_for(head: str, sub: str) -> str:
    """Suggested allowlist pattern for a (head, sub) pair."""
    if sub:
        return f"Bash({head} {sub} *)"
    return f"Bash({head} *)"


def describe(head: str, sub: str) -> str:
    pair = f"{head} {sub}".strip()
    map_ = {
        "xcodebuild": "Xcode builds",
        "curl": "HTTP GET (read-only when used without -X POST/etc)",
        "ssh": "Remote shell access",
        "tmux": "Terminal multiplexer",
        "pm2": "PM2 process manager",
        "rustup": "Rust toolchain manager",
        "rustup target": "Add/list Rust cross-compile targets",
        "xcrun": "Xcode tooling",
        "xcrun devicectl": "iOS device control",
        "xcrun simctl": "iOS simulator control",
        "brew": "Homebrew",
        "security": "macOS keychain inspection",
        "defaults": "macOS defaults read",
    }
    return map_.get(pair, map_.get(head, ""))


def main() -> int:
    if not PROJECTS.exists():
        print(f"No transcripts dir at {PROJECTS}", file=sys.stderr)
        return 1

    files = sorted(
        (f for f in PROJECTS.rglob("*.jsonl") if f.is_file()),
        key=lambda f: f.stat().st_mtime,
        reverse=True,
    )[:MAX_FILES]

    print(f"Scanning {len(files)} most-recent transcript files...", file=sys.stderr)

    bash_counter: Counter[tuple[str, str]] = Counter()
    mcp_counter: Counter[str] = Counter()

    for path in files:
        try:
            with path.open() as f:
                for line in f:
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg = record.get("message", {})
                    if not isinstance(msg, dict):
                        continue
                    content = msg.get("content")
                    if not isinstance(content, list):
                        continue
                    for entry in content:
                        if not isinstance(entry, dict):
                            continue
                        if entry.get("type") != "tool_use":
                            continue
                        name = entry.get("name", "")
                        inp = entry.get("input", {}) or {}
                        if name == "Bash":
                            cmd = inp.get("command", "")
                            if not isinstance(cmd, str):
                                continue
                            pair = leading_command_pair(cmd)
                            if pair:
                                bash_counter[pair] += 1
                        elif name.startswith("mcp__"):
                            mcp_counter[name] += 1
        except OSError:
            continue

    # Filter Bash candidates.
    candidates: list[tuple[int, str, str, str]] = []
    for (head, sub), count in bash_counter.items():
        if not head:
            continue
        if is_arbitrary_exec(head):
            continue
        if is_mutating(head, sub):
            continue
        if is_auto_allowed(head, sub):
            continue
        if count < 3:
            continue
        candidates.append((count, head, sub, describe(head, sub)))

    candidates.sort(reverse=True)
    # Cap to top 20.
    candidates = candidates[:20]

    # MCP: include read/get/list/search/view in name.
    mcp_safe_patterns = {"read", "get", "list", "search", "view", "describe"}
    mcp_candidates: list[tuple[int, str]] = []
    for name, count in mcp_counter.items():
        lower = name.lower()
        if any(token in lower for token in mcp_safe_patterns):
            if count >= 3:
                mcp_candidates.append((count, name))
    mcp_candidates.sort(reverse=True)
    mcp_candidates = mcp_candidates[:10]

    # Print results.
    print("\n# Prioritized Bash candidates\n")
    print("| # | Pattern | Count | Notes |")
    print("|---|---------|-------|-------|")
    for i, (count, head, sub, note) in enumerate(candidates, start=1):
        pat = pattern_for(head, sub)
        print(f"| {i} | `{pat}` | {count} | {note} |")

    if mcp_candidates:
        print("\n# MCP read-only candidates\n")
        print("| # | Tool | Count |")
        print("|---|------|-------|")
        for i, (count, name) in enumerate(mcp_candidates, start=1):
            print(f"| {i} | `{name}` | {count} |")

    # Output as JSON for downstream merge.
    payload = {
        "bash_patterns": [pattern_for(h, s) for (_, h, s, _) in candidates],
        "mcp_tools": [name for (_, name) in mcp_candidates],
    }
    print("\n# JSON\n")
    print(json.dumps(payload, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
