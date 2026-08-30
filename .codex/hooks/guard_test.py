"""Case table for guard.py. Run it after editing any pattern in that file.

    python .claude/hooks/guard_test.py

Exits non-zero on the first disagreement, so it works as a pre-commit check.

The five FALSE-POSITIVE cases are the reason this file exists. The guard first
shipped matching anywhere in the command string, and the very next commit -- the
one adding the guard -- was blocked by it, because the commit message explained
which commands the guard denies. Text that names a command is not a command.
Any new pattern needs a case on both sides of that line before it goes in.
"""

import importlib.util
import os
import sys

# Importing guard.py would otherwise leave a __pycache__ beside the hooks --
# an artifact in a directory that holds nothing but source.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("guard", os.path.join(HERE, "guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

COMMIT_MESSAGE = """git commit -F - <<'EOF'
A guidance file short enough to be followed

Denies `flutter build apk` (broken here) and `adb uninstall` (wipes Hive).
A third pattern blocks shell rewrites -- sed -i, Get-Content | Set-Content.
EOF"""

DENY = [
    "flutter build apk --release",
    "flutter build appbundle",
    "cd android && flutter build apk",
    "adb uninstall com.cubechat.cubechat",
    "adb -s emulator-5554 uninstall com.cubechat.cubechat",
    "sed -i 's/a/b/' lib/main.dart",
    "Get-Content lib/main.dart | Set-Content lib/main.dart",
    "echo hi > lib/generated.dart",
]

# Text that only names a command. Every one of these used to be denied.
ALLOW_MENTIONS = [
    COMMIT_MESSAGE,
    'echo "flutter build apk is blocked here"',
    'grep -rn "adb uninstall" .claude/skills/',
    "git commit -m 'explain why sed -i corrupts lib/main.dart'",
    'git log --grep="flutter build apk"',
]

# Ordinary work that must keep flowing.
ALLOW_WORK = [
    "flutter test test/mesh_ttl_test.dart",
    "flutter analyze 2>&1 | tee analyze.log",
    "powershell -ExecutionPolicy Bypass -File tool/build_apk.ps1",
    "sed -n '1,20p' lib/main.dart",
    "grep -n class lib/app.dart",
    "echo hi > /c/Users/kuzme/AppData/Local/Temp/claude/scratchpad/x.md",
]

CASES = (
    [(True, c) for c in DENY]
    + [(False, c) for c in ALLOW_MENTIONS]
    + [(False, c) for c in ALLOW_WORK]
)


def main():
    failed = 0
    for expect_deny, command in CASES:
        got_deny = guard.verdict(command) is not None
        agreed = got_deny == expect_deny
        failed += 0 if agreed else 1
        label = command.splitlines()[0][:64] + (" ..." if "\n" in command else "")
        print("{}  {:5}  {}".format("ok  " if agreed else "FAIL", "deny" if got_deny else "allow", label))

    print()
    if failed:
        print("{} case(s) disagree with guard.py".format(failed))
        return 1
    print("all {} cases correct".format(len(CASES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
