#!/usr/bin/env python3
# Patches buildroot's support/scripts/pyinstaller.py so that installing a
# host Python wheel succeeds even when a previous (partial) install left
# orphaned scripts in host/bin/.
#
# Why: the installer library's SchemeDictionaryDestination raises
# FileExistsError if a target path already exists instead of overwriting it.
# pyinstaller.py's clean() removes old files by reading the package's
# .dist-info/RECORD — but if a previous install failed before writing
# .dist-info (e.g. the build was interrupted), clean() finds nothing and the
# subsequent install() hits FileExistsError on the orphaned script.
#
# Fix: wrap install() in a retry loop that removes each conflicting file and
# retries until the install succeeds or a hard limit is reached.
#
# Idempotent: re-running on an already-patched file is a no-op.

import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit(f"usage: {sys.argv[0]} <path-to-pyinstaller.py>")

p = Path(sys.argv[1])
content = p.read_text()

MARKER = "# PANICOS_OVERWRITE_FIX"

if MARKER in content:
    sys.exit(0)  # already patched

OLD = (
    "    with WheelFile.open(glob.glob(args.wheel_file)[0]) as source:\n"
    "        clean(source, destination)\n"
    "        install(\n"
    "            source=source,\n"
    "            destination=destination,\n"
    "            additional_metadata={},\n"
    "        )\n"
)

NEW = (
    f"    {MARKER}: retry install() when orphaned files block SchemeDictionaryDestination.\n"
    "    # clean() removes old files via .dist-info/RECORD, but if a previous\n"
    "    # install failed before writing .dist-info the record is gone and\n"
    "    # install() hits FileExistsError.  Remove each conflicting file and retry.\n"
    "    import re as _re\n"
    "    _wheel_path = glob.glob(args.wheel_file)[0]\n"
    "    with WheelFile.open(_wheel_path) as source:\n"
    "        clean(source, destination)\n"
    "    for _attempt in range(20):\n"
    "        try:\n"
    "            with WheelFile.open(_wheel_path) as source:\n"
    "                install(source=source, destination=destination, additional_metadata={})\n"
    "            break\n"
    "        except FileExistsError as _exc:\n"
    "            _m = _re.search(r'File already exists: (.+)', str(_exc))\n"
    "            if not _m:\n"
    "                raise\n"
    "            pathlib.Path(_m.group(1).strip()).unlink()\n"
    "    else:\n"
    "        raise RuntimeError('pyinstaller: stuck on FileExistsError after 20 attempts')\n"
)

if OLD not in content:
    sys.exit(
        f"ERROR: didn't find expected install() block in {p} — "
        "buildroot may have changed pyinstaller.py structure"
    )

p.write_text(content.replace(OLD, NEW))
print(f"Patched {p} with PanicOS overwrite-retry fix")
