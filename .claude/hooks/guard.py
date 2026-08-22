"""PreToolUse guard for shell commands in the cubechat repo.

Three failures this repo hits often enough to be worth blocking rather than
documenting. Each of them used to be a line in CLAUDE.md, which is guidance the
model can weigh against everything else in the file; here they are code that
runs before the command does.

Contract: hook input JSON on stdin, decision JSON on stdout, exit 0. A deny is
expressed as hookSpecificOutput.permissionDecision so the reason reaches the
model as an explanation rather than as a crashed hook.

Deliberately ASCII-only: this prints through a Windows console codepage, and a
non-ASCII reason can come back mangled -- which is, fittingly, the third rule.
"""

import json
import re
import sys

# Paths under these are scratch space, not the repository. Rewriting a file
# there through the shell is fine -- nothing round-trips back into git.
SCRATCH = re.compile(r"(scratchpad|[/\\]tmp[/\\]|appdata[/\\]local[/\\]temp)", re.I)

# Extensions whose contents are read back by a human or a compiler, i.e. where
# a CP1251 round-trip is destructive rather than cosmetic.
TEXT_EXT = r"\.(dart|md|arb|ya?ml|kt|swift|json|gradle|kts)"

# A command only counts where a command can start. Without this the guard fires
# on any text that merely names the thing -- a commit message explaining why
# `flutter build apk` is blocked, a grep for "adb uninstall" in the docs -- which
# is how this hook first blocked its own commit.
CMD_POS = r"(?:^|[;&|(]\s*|\n\s*|\$\(\s*|`\s*)"

BUILD = re.compile(CMD_POS + r"flutter(\.bat)?\s+build\s+(apk|appbundle)", re.I)

UNINSTALL = re.compile(
    CMD_POS + r"(adb(\.exe)?\s+(-s\s+\S+\s+)?uninstall|pm\s+uninstall)\b", re.I
)

# In-place rewrites through the shell, by the three shapes that actually occur:
# sed -i, a PowerShell content cmdlet, and a redirect into a tracked file.
REWRITES = (
    re.compile(CMD_POS + r"sed\s+(-[a-z]*i\b|--in-place)", re.I),
    re.compile(r"\|\s*(Set-Content|Add-Content|Out-File)\b", re.I),
    re.compile(CMD_POS + r"(Set-Content|Add-Content|Out-File)\b", re.I),
    re.compile(r"(?<![0-9&])>>?\s*[\"']?([^\s\"'|;&]+" + TEXT_EXT + r")", re.I),
)

# Heredoc bodies are data, not commands. A commit message or a generated file
# written this way routinely quotes the very commands below.
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1\r?\n.*?\r?\n\2\b", re.S)

TARGET = re.compile(r"[\w./\\:-]+" + TEXT_EXT, re.I)


def repo_text_targets(command):
    """Text files named in the command that are not scratch paths."""
    return [m.group(0) for m in TARGET.finditer(command) if not SCRATCH.search(m.group(0))]


def verdict(command):
    command = HEREDOC.sub("<<heredoc", command)

    if BUILD.search(command):
        return (
            "`flutter build apk` does not work in this repo. Every pub get rewrites "
            ".flutter-plugins-dependencies with double-escaped paths, so Gradle dies in ~2s "
            "reporting a plugin directory that does exist. Build with "
            "`powershell -ExecutionPolicy Bypass -File tool/build_apk.ps1` instead -- it "
            "repairs the file, pins the version and verifies the build stamp. Load the "
            "`release-build` skill for the full procedure."
        )

    if UNINSTALL.search(command):
        return (
            "Uninstalling cubechat wipes Hive and the Keystore, which means a new identity, "
            "a new Nostr key, and every existing chat on that device broken. Install the new "
            "APK over the top instead. If the install is refused, the signing fingerprint "
            "changed -- see the `release-build` skill, not an uninstall."
        )

    for pattern in REWRITES:
        if pattern.search(command):
            targets = repo_text_targets(command)
            if targets:
                return (
                    "Rewriting {} through the shell corrupts non-ASCII: both Bash and "
                    "PowerShell here re-encode through CP1251 in both directions, and a "
                    "Get-Content | Set-Content round-trip has already destroyed every "
                    "em-dash in a source file. Use the Write or Edit tool instead. "
                    "Reading (cat, sed -n, grep) is unaffected.".format(", ".join(targets[:3]))
                )

    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return  # Malformed input is not grounds for blocking a command.

    command = (payload.get("tool_input") or {}).get("command") or ""
    reason = verdict(command)
    if not reason:
        return

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
