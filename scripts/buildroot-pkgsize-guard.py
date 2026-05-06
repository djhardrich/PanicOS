#!/usr/bin/env python3
"""
Patch Buildroot's pkg-generic.mk to guard pkg_size_before/after calls so they
are no-ops when $(PKG)_DIR is empty (which happens with some host packages).

Without the guard, pkg_size_after writes to /.files-list.after which fails
with Permission Denied inside the Docker container (non-root user can't write
to the container's root filesystem).

Idempotent: re-running is safe.
"""
import re
import sys

if len(sys.argv) != 2:
    sys.exit(f"Usage: {sys.argv[0]} <path/to/pkg-generic.mk>")

path = sys.argv[1]
with open(path) as f:
    text = f.read()

GUARD_MARKER = "pkg_size_guard_applied"
if GUARD_MARKER in text:
    print(f"Already patched: {path}")
    sys.exit(0)

# Replace both define blocks in one pass.
# Original pkg_size_before:
#   define pkg_size_before
#   \tcd $(1); \
#   \tLC_ALL=C find ... > $($(PKG)_DIR)/.files-list$(2).before
#   endef
#
# Original pkg_size_after:
#   define pkg_size_after
#   \tcd $(1); \
#   \tLC_ALL=C find ... > $($(PKG)_DIR)/.files-list$(2).after
#   \tLC_ALL=C comm -13 ... > $($(PKG)_DIR)/.files-list$(2).txt
#   \trm -f $($(PKG)_DIR)/.files-list$(2).before
#   \trm -f $($(PKG)_DIR)/.files-list$(2).after
#   endef
#
# We wrap each define body in $(if $($(PKG)_DIR), ...) so that when PKG is
# empty (and hence $(PKG)_DIR is empty) the shell commands are not emitted.

def wrap_define(text, define_name):
    """Wrap the body of `define define_name ... endef` in $(if $($(PKG)_DIR),<body>)."""
    pattern = re.compile(
        r'(define ' + re.escape(define_name) + r'\n)(.*?)(^endef)',
        re.DOTALL | re.MULTILINE,
    )
    m = pattern.search(text)
    if not m:
        print(f"  WARNING: could not find 'define {define_name}' in {path}")
        return text
    header = m.group(1)
    body = m.group(2)
    footer = m.group(3)
    # Indent the body (already indented with tabs); wrap with $(if ...).
    # Make's $(if cond,then) evaluates cond; if non-empty, expands then.
    wrapped_body = (
        '\t$(if $($(PKG)_DIR),\\\n'
        + body.rstrip('\n')
        + ')\n'
    )
    new_block = header + wrapped_body + footer
    return text[:m.start()] + new_block + text[m.end():]

text = wrap_define(text, 'pkg_size_before')
text = wrap_define(text, 'pkg_size_after')

# Embed the guard marker so we know the patch was applied.
text = text.replace(
    '# Functions to collect statistics about installed files\n',
    '# Functions to collect statistics about installed files\n'
    '# ' + GUARD_MARKER + '\n',
)

with open(path, 'w') as f:
    f.write(text)

print(f"Patched: {path}")
