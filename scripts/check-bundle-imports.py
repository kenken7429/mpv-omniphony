#!/usr/bin/env python3
"""Verify that every named DLL import in a staged Windows bundle resolves.

The MinGW libraries we bundle come prebuilt from a binary package repo that
can be mid-rebuild when a build job runs: a library gets bumped while its
dependants were built against the previous version. Cross-compiling never
resolves runtime imports, so a mismatched pair ships silently and every
Windows machine then fails at launch with an "entry point not found" dialog
(mgth/Omniphony#200: avcodec-62.dll importing x265_api_get_215 next to a
libx265.dll exporting x265_api_get_216).

For every .dll/.exe in the staging directory, parse imports with objdump and
check each named symbol against the export table of the staged DLL it comes
from. Imports from DLLs that are not staged (Windows system DLLs, the MSVC
runtime pulled by orender.dll) are listed for log visibility but do not fail
the check — the packaging worklist is responsible for deciding what gets
staged.

Usage: check-bundle-imports.py <staging-dir>
Env:   OBJDUMP  objdump binary to use (default: x86_64-w64-mingw32-objdump)
"""

import os
import re
import subprocess
import sys


def objdump(path: str) -> str:
    tool = os.environ.get("OBJDUMP", "x86_64-w64-mingw32-objdump")
    return subprocess.run(
        [tool, "-p", path], capture_output=True, text=True, check=True
    ).stdout


# Export table entries look like:  [   0] +base[   1]  0000 x265_api_get_215
EXPORT_RE = re.compile(r"^\s*\[\s*\d+\]\s+\+base\[\s*\d+\]\s+\S+\s+(\S+)\s*$", re.M)
DLL_NAME_RE = re.compile(r"DLL Name:\s*(\S+)")
HEX_RE = re.compile(r"^[0-9a-f]+$")


def import_entry_symbol(line: str) -> str | None:
    """Return the imported symbol on an import-table entry line, else None.

    Entry lines start with a hex vma; the symbol is the last token. Import
    descriptor lines are all-hex and header lines start with a keyword, so
    both are filtered out.
    """
    tokens = line.split()
    if len(tokens) < 2 or not HEX_RE.fullmatch(tokens[0]):
        return None
    if all(HEX_RE.fullmatch(t) for t in tokens):
        return None  # descriptor line (all-hex), not an import entry
    sym = tokens[-1]
    if sym == "<none>" or sym.isdigit():
        return None  # ordinal-only import
    return sym


def main() -> int:
    staging = sys.argv[1] if len(sys.argv) > 1 else "staging"

    def is_pe(name: str) -> bool:
        # Detect by MZ magic, not extension — the bundle carries PE files with
        # Unix-style versioned names (e.g. libgsm.dll.1.0.23).
        path = os.path.join(staging, name)
        if not os.path.isfile(path):
            return False
        with open(path, "rb") as fh:
            return fh.read(2) == b"MZ"

    pes = sorted(f for f in os.listdir(staging) if is_pe(f))
    if not pes:
        print(f"error: no PE files found in {staging}/", file=sys.stderr)
        return 1

    dumps = {f: objdump(os.path.join(staging, f)) for f in pes}
    exports = {f.lower(): set(EXPORT_RE.findall(out)) for f, out in dumps.items()}

    errors = []
    unstaged = set()
    for f in pes:
        cur = None
        in_imports = False
        for line in dumps[f].splitlines():
            # Section headers sit at column 0 ("The Import Tables …", "The
            # Function Table …"); only parse entries inside the import tables,
            # or unwind-info hex lines get misread as import entries.
            if line and line[0] not in " \t":
                in_imports = line.startswith(("The Import Tables", "The Delay Import"))
                cur = None
                continue
            if not in_imports:
                continue
            m = DLL_NAME_RE.search(line)
            if m:
                cur = m.group(1)
                continue
            if cur is None:
                continue
            sym = import_entry_symbol(line)
            if sym is None:
                continue
            if cur.lower() in exports:
                if sym not in exports[cur.lower()]:
                    errors.append(
                        f"{f} imports {sym} from {cur}, "
                        f"but the staged {cur} does not export it"
                    )
            else:
                unstaged.add(cur)

    if unstaged:
        print("imports resolved outside the bundle (system DLLs expected):")
        for d in sorted(unstaged, key=str.lower):
            print(f"  {d}")

    if errors:
        print(
            "\nFATAL: staged bundle has unresolvable imports "
            "(mismatched prebuilt packages?):",
            file=sys.stderr,
        )
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    print(f"\nOK: all imports against staged DLLs resolve ({len(pes)} PE files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
