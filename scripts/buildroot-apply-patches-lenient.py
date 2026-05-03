#!/usr/bin/env python3
# Patches buildroot's support/scripts/apply-patches.sh so that patches
# rejected with "Reversed (or previously applied)" are treated as success
# instead of fatal failures.
#
# Why: buildroot 2026.02.1 ships many packages where the bundled patches
# (typically CVE backports or upstream bugfix backports) are already in
# the version-bumped upstream tarball. patch(1) detects this and exits
# non-zero with "Reversed (or previously applied) patch detected!", which
# buildroot treats as a fatal patch failure. Pre-skipping each one is
# whack-a-mole; this transform makes the script forgive that specific
# case once.
#
# Idempotent: re-running on an already-patched file is a no-op.

import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit(f"usage: {sys.argv[0]} <path-to-apply-patches.sh>")

p = Path(sys.argv[1])
content = p.read_text()

OLD = (
    '    ${uncomp} "${path}/$patch" | patch -F2 -g0 -p1 --no-backup-if-mismatch -d "${builddir}" -t -N $silent\n'
    '    if [ $? != 0 ] ; then\n'
    '        echo "Patch failed!  Please fix ${patch}!"\n'
    '        exit 1\n'
    '    fi\n'
)

NEW = (
    '    # PanicOS lenience: treat "Reversed (or previously applied)" exit codes\n'
    '    # as success — buildroot 2026.02.1 ships several already-merged patches.\n'
    '    # Disable set -e around the patch so we can inspect rc + output before\n'
    '    # deciding whether to bail.\n'
    '    set +e\n'
    '    PATCH_OUT=$(${uncomp} "${path}/$patch" | patch -F2 -g0 -p1 --no-backup-if-mismatch -d "${builddir}" -t -N $silent 2>&1)\n'
    '    PATCH_RC=$?\n'
    '    set -e\n'
    '    echo "$PATCH_OUT"\n'
    '    if [ $PATCH_RC != 0 ] && ! echo "$PATCH_OUT" | grep -q "Reversed (or previously applied)" ; then\n'
    '        echo "Patch failed!  Please fix ${patch}!"\n'
    '        exit 1\n'
    '    fi\n'
    '    # Clean up .rej files left behind when patch detected "Reversed" —\n'
    '    # the script\'s end-of-run reject scan would otherwise abort the build.\n'
    '    if echo "$PATCH_OUT" | grep -q "Reversed (or previously applied)" ; then\n'
    '        find "${builddir}/" \\( -name "*.rej" -o -name ".*.rej" \\) -delete 2>/dev/null || true\n'
    '    fi\n'
)

if NEW in content:
    sys.exit(0)  # already patched

if OLD not in content:
    sys.exit(f"ERROR: didn't find expected patch invocation in {p} — buildroot may have changed apply-patches.sh structure")

p.write_text(content.replace(OLD, NEW))
print(f"Patched {p} with PanicOS Reversed-tolerant lenience")
