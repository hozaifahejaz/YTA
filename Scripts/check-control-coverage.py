#!/usr/bin/env python3
"""Fails when an app feature cannot be reached through MCP.

Every non-private method on AppModel must be called from an action in
Sources/YTAApp/AppModel+Control.swift, or be listed in Scripts/control-exempt.txt
with the reason it has no action. Run it from the repository root.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "YTAApp"
CONTROL = APP / "AppModel+Control.swift"
EXEMPT = ROOT / "Scripts" / "control-exempt.txt"

FUNC = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*((?:private|fileprivate|public|internal|static|nonisolated|override|final|\s)*)func\s+(\w+)")
OPENER = re.compile(r"^(?:@\w+\s+)*(?:final\s+)?(?:extension|class)\s+AppModel\b")


def model_methods(path):
    """Names of the methods declared directly on AppModel in one file."""
    names = []
    depth = 0
    inside = False
    in_text = False
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.count('"""') % 2 == 1:
            in_text = not in_text
            continue
        if in_text:
            continue
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line).split("//")[0]
        if depth == 0 and OPENER.match(code):
            inside = True
        if inside and depth == 1:
            match = FUNC.match(code)
            if match and "private" not in match.group(1):
                names.append(match.group(2))
        depth += code.count("{") - code.count("}")
        if depth == 0:
            inside = False
    return names


def main():
    declared = {}
    for path in sorted(APP.glob("*.swift")):
        for name in model_methods(path):
            declared.setdefault(name, path.name)

    control_text = CONTROL.read_text()
    helpers = set(model_methods(CONTROL))

    exempt = {}
    problems = []
    for number, line in enumerate(EXEMPT.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition("#")
        name, reason = name.strip(), reason.strip()
        if not reason:
            problems.append(f"control-exempt.txt line {number}: {name} needs a reason after '#'.")
        exempt[name] = reason

    missing = []
    for name, file in sorted(declared.items()):
        if name in helpers or name in exempt:
            continue
        # Called as m.name or as a bare name( inside an AppModel method; other.name( does not count.
        if not re.search(r"(?:\bm\.|(?<![.\w]))" + name + r"\b", control_text):
            missing.append(f"{name} ({file})")

    stale = sorted(name for name in exempt if name not in declared)
    if missing:
        problems.append("These AppModel methods have no MCP action:\n  " + "\n  ".join(missing)
                        + "\nAdd an action in Sources/YTAApp/AppModel+Control.swift, or list the method in "
                        "Scripts/control-exempt.txt with the reason it needs none.")
    if stale:
        problems.append("control-exempt.txt lists methods that no longer exist: " + ", ".join(stale))
    if problems:
        print("\n\n".join(problems), file=sys.stderr)
        return 1
    print(f"MCP coverage: {len(declared) - len(exempt) - len(helpers & set(declared))} methods reached by actions, "
          f"{len(exempt)} exempt with reasons.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
