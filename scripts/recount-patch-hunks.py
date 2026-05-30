#!/usr/bin/env python3
"""recount-patch-hunks.py — recompute unified-diff @@ hunk line counts.

Hand/AI-authored kernel patches in soc/*/linux/patches/ frequently ship with
wrong @@ -a,b +c,d @@ counts. GNU `patch` tolerates this until a clean
re-extract, then dies with "malformed patch". This rewrites every hunk header's
b/d counts to match the actual body content, leaving a/c (start lines) and the
trailing section header untouched.

Body parsing: a hunk body line starts with ' ', '+', '-', or '\\' (no-newline
marker), or is completely empty (a blank context line). The body ends at the
next '@@', a 'diff --git', a bare 'index '/'--- '/'+++ ' file header, EOF, or
the git format-patch footer ('-- '). Trailing fully-empty lines are treated as
separators, not context. '\\' lines count toward neither side.

Usage: recount-patch-hunks.py FILE [FILE ...]   (rewrites in place)
       recount-patch-hunks.py --check FILE ...   (report only, exit 1 if wrong)
"""
import re
import sys

HUNK_RE = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$')


def is_boundary(lines, j):
    """True if lines[j] ends the current hunk body (structural boundary).

    Handles both git-style ('diff --git') and bare unified-diff file headers
    ('--- a/x' immediately followed by '+++ b/x'), plus the next '@@' hunk and
    the git format-patch '-- ' footer.
    """
    line = lines[j]
    s = line.rstrip('\n')
    if s.startswith('@@ ') or s.startswith('diff --git'):
        return True
    if s in ('--', '-- '):  # git format-patch signature footer
        return True
    # non-git file header pair: '--- X' on this line, '+++ Y' on the next.
    if s.startswith('--- ') and j + 1 < len(lines) and \
            lines[j + 1].startswith('+++ '):
        return True
    return False


def recount_file(path, check_only):
    with open(path, 'r') as f:
        lines = f.readlines()

    out = []
    i = 0
    changed = False
    n = len(lines)
    while i < n:
        line = lines[i]
        m = HUNK_RE.match(line.rstrip('\n'))
        if not m:
            out.append(line)
            i += 1
            continue

        old_start, _old_cnt, new_start, _new_cnt, tail = m.groups()

        # Collect the hunk body.
        body = []
        j = i + 1
        while j < n:
            if is_boundary(lines, j):
                break
            stripped = lines[j].rstrip('\n')
            # Body lines: ' ', '+', '-', '\' prefixes, or truly empty.
            if stripped == '' or stripped[0] in (' ', '+', '-', '\\'):
                body.append(lines[j])
                j += 1
            else:
                break

        # Strip trailing fully-empty lines (separators, not context).
        while body and body[-1].rstrip('\n') == '':
            body.pop()
            j -= 1

        old = new = 0
        for bl in body:
            s = bl.rstrip('\n')
            if s == '' or s[0] == ' ':
                old += 1
                new += 1
            elif s[0] == '-':
                old += 1
            elif s[0] == '+':
                new += 1
            # '\' → neither

        new_header = f'@@ -{old_start},{old} +{new_start},{new} @@{tail}\n'
        if new_header != line:
            changed = True
            if check_only:
                print(f'{path}: {line.rstrip()}  ->  {new_header.rstrip()}')
        out.append(new_header)
        out.extend(body)
        # Re-emit any trailing separators we stripped, plus continue from j.
        i = i + 1 + len(body)

    if not check_only and changed:
        with open(path, 'w') as f:
            f.writelines(out)
    return changed


def main():
    args = sys.argv[1:]
    check_only = False
    if args and args[0] == '--check':
        check_only = True
        args = args[1:]
    if not args:
        print(__doc__)
        return 2
    any_changed = False
    for path in args:
        if recount_file(path, check_only):
            any_changed = True
            print(f'{"WOULD FIX" if check_only else "FIXED"}: {path}')
        else:
            print(f'OK:    {path}')
    return 1 if (check_only and any_changed) else 0


if __name__ == '__main__':
    sys.exit(main())
