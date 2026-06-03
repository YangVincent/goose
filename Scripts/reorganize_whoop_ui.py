#!/usr/bin/env python3
"""Move all WHOOP-look UI files into GooseSwift/WhoopUI/ and rename
HomeWhoop* → Whoop* for naming consistency. Updates project.pbxproj
to reflect new paths.

Run from the project root:
    python3 Scripts/reorganize_whoop_ui.py
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SWIFT_DIR = ROOT / "GooseSwift"
TARGET_DIR = SWIFT_DIR / "WhoopUI"
PBX = ROOT / "GooseSwift.xcodeproj" / "project.pbxproj"

# (current_basename, new_basename) — None means keep the name.
MOVES = [
    ("WhoopAPIClient.swift", None),
    ("WhoopHomeView.swift", None),
    ("WhoopWorkoutsView.swift", None),
    ("WhoopAgeView.swift", None),
    ("WhoopMetricDetailView.swift", None),
    ("WhoopTodaySection.swift", None),
    ("HomeWhoopScoreCard.swift", "WhoopScoreCard.swift"),
    ("HomeWhoopSleepCard.swift", "WhoopSleepCard.swift"),
]


def main() -> int:
    TARGET_DIR.mkdir(exist_ok=True)
    pbx_text = PBX.read_text()
    renamed_classes: list[tuple[str, str]] = []

    for current, new in MOVES:
        src = SWIFT_DIR / current
        if not src.exists():
            print(f"  skip {current} (not present, maybe already moved)")
            continue

        target_basename = new or current
        dst = TARGET_DIR / target_basename

        # Move on disk (rename to new basename if requested).
        shutil.move(str(src), str(dst))
        print(f"  moved {current} → WhoopUI/{target_basename}")

        # Update the pbxproj PBXFileReference path. With sourceTree=<group>,
        # path is relative to the parent group, so we set it to "WhoopUI/Foo.swift".
        # We also need to update the comment markers that include the filename.
        old_path_attr = f'path = {current};'
        new_path_attr = f'path = WhoopUI/{target_basename};'
        if old_path_attr in pbx_text:
            pbx_text = pbx_text.replace(old_path_attr, new_path_attr)
        else:
            print(f"    ⚠️  could not find `path = {current};` in pbxproj — file may not have been registered")

        # If renaming, update all the `/* OldName.swift */` comment markers
        # to `/* NewName.swift */`. These appear next to PBXBuildFile and
        # PBXFileReference IDs throughout the file.
        if new and new != current:
            pbx_text = pbx_text.replace(f"/* {current} */", f"/* {target_basename} */")
            pbx_text = pbx_text.replace(f"/* {current} in Sources */", f"/* {target_basename} in Sources */")

            # Update Swift type name references in the source file too.
            current_type = current.removesuffix(".swift")
            new_type = target_basename.removesuffix(".swift")
            renamed_classes.append((current_type, new_type))

    PBX.write_text(pbx_text)

    # Update Swift type name references project-wide.
    if renamed_classes:
        print()
        print("Renaming Swift types in source files:")
        for swift_file in SWIFT_DIR.rglob("*.swift"):
            text = swift_file.read_text()
            original = text
            for old_type, new_type in renamed_classes:
                # Word-boundary substitution to avoid partial matches.
                text = re.sub(rf"\b{old_type}\b", new_type, text)
            if text != original:
                swift_file.write_text(text)
                print(f"  updated {swift_file.relative_to(ROOT)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
