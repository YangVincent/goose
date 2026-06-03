#!/usr/bin/env python3
"""Register one or more Swift files in GooseSwift.xcodeproj/project.pbxproj.

Xcode 16 projects support synchronized folder groups, but Goose's project uses
explicit file references. Each Swift file needs four entries in the pbxproj:
  1. PBXBuildFile (links the file to a build phase)
  2. PBXFileReference (declares the file path/type)
  3. PBXGroup children entry (so it appears in the project navigator)
  4. PBXSourcesBuildPhase files entry (so it actually compiles)

Pass the basenames of the swift files to register. IDs are minted in the
F-series (F100... for BuildFile, F200... for FileReference). The script is
idempotent: files already present are skipped.

Usage:
  python3 Scripts/register_swift_in_pbxproj.py WhoopTodaySection.swift NewView.swift
"""
import sys
import re
from pathlib import Path

PBX = Path(__file__).resolve().parent.parent / "GooseSwift.xcodeproj" / "project.pbxproj"

# Anchor on GooseBLEClient.swift — a stable existing file. We insert new
# entries directly after it in each of the four sections.
BUILD_ANCHOR = "A10000000000000000000008 /* GooseBLEClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000008 /* GooseBLEClient.swift */; };"
FILEREF_ANCHOR = 'A20000000000000000000008 /* GooseBLEClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GooseBLEClient.swift; sourceTree = "<group>"; };'
GROUP_ANCHOR = "\t\t\t\tA20000000000000000000008 /* GooseBLEClient.swift */,"
SOURCES_ANCHOR = "\t\t\t\tA10000000000000000000008 /* GooseBLEClient.swift in Sources */,"


def next_id_pair(text: str) -> tuple[str, str]:
    """Find next unused F-series ID pair."""
    existing = set(re.findall(r"F[12]00000000000000000000([0-9A-F]{2})", text))
    for i in range(0xA1, 0x100):
        suffix = f"{i:02X}"
        if suffix not in existing:
            return (f"F100000000000000000000{suffix}", f"F200000000000000000000{suffix}")
    raise RuntimeError("Exhausted F-series IDs")


def register(text: str, name: str) -> str:
    if f"/* {name} */" in text:
        print(f"  skip {name} (already registered)")
        return text
    bf, fr = next_id_pair(text)
    text = text.replace(
        BUILD_ANCHOR,
        BUILD_ANCHOR + f"\n\t\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};",
        1,
    )
    text = text.replace(
        FILEREF_ANCHOR,
        FILEREF_ANCHOR + f"\n\t\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};",
        1,
    )
    text = text.replace(
        GROUP_ANCHOR,
        GROUP_ANCHOR + f"\n\t\t\t\t{fr} /* {name} */,",
        1,
    )
    text = text.replace(
        SOURCES_ANCHOR,
        SOURCES_ANCHOR + f"\n\t\t\t\t{bf} /* {name} in Sources */,",
        1,
    )
    # Sanity: BuildFile id should appear twice (definition + sources list),
    # FileReference id three times (definition + group children + build file ref).
    assert text.count(bf) == 2, f"BuildFile count wrong for {name}: {text.count(bf)}"
    assert text.count(fr) == 3, f"FileRef count wrong for {name}: {text.count(fr)}"
    print(f"  added {name} ({bf} / {fr})")
    return text


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: register_swift_in_pbxproj.py <Name.swift> [<Name.swift> ...]", file=sys.stderr)
        return 1
    text = PBX.read_text()
    for name in argv:
        text = register(text, name)
    PBX.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
