"""PostToolUse reminder: an edited .arb needs gen-l10n run and committed.

lib/l10n/app_localizations*.dart is generated but checked in on purpose -- CI
does not regenerate it before building. So an .arb edit that stops there
compiles fine locally off the stale generated file and breaks on the runner, or
worse, ships a build whose new string is missing. Nothing enforces the second
step, which is what this line is for.

Advisory only: prints context, never blocks.
"""

import json
import sys


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return

    tool_input = payload.get("tool_input") or {}
    response = payload.get("tool_response") or {}
    path = response.get("filePath") or tool_input.get("file_path") or ""

    if not path.replace("\\", "/").lower().endswith(".arb"):
        return

    json.dump(
        {
            "systemMessage": "ARB edited - run flutter gen-l10n and commit the generated files.",
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": (
                    "An .arb file was edited. Run `flutter gen-l10n` and commit the "
                    "regenerated lib/l10n/app_localizations*.dart -- they are checked in "
                    "and CI does not rebuild them. Keep app_en.arb and app_uk.arb at the "
                    "same key set; they are currently in sync."
                ),
            },
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
