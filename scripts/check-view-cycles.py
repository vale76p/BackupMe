#!/usr/bin/env python3
"""Finds cycles among the computed properties of a Swift file's types.

The compiler cannot see them: two computed properties that read each other recurse until the stack is over, and a
view that does it crashes at its first render. Views have no tests here, so this is the only guard before the app runs.

Usage: check-view-cycles.py file.swift ...
Prints every cycle found and exits 1; prints nothing and exits 0 when there is none. It goes by names, the whole
body included: a property's name used for a local variable or inside a closure can give a false cycle, never a
missed one.
"""
import re
import sys


def properties(src):
    """Name and body of every computed property (`var name: Type { … }`), its attributes (`@ViewBuilder`, …) included."""
    found = {}
    for m in re.finditer(r'^[ \t]*(?:@[\w.]+(?:\([^\n]*\))?\s*)*(?:private\s+|fileprivate\s+)?var\s+(\w+)\s*:\s*[^{=\n]+?\{', src, flags=re.M):
        name, start = m.group(1), m.end()
        depth, i = 1, start
        while i < len(src) and depth:
            depth += (src[i] == '{') - (src[i] == '}')
            i += 1
        found[name] = src[start:i - 1]
    return found


def cycles(props):
    """Each cycle as the path of property names that comes back to its start."""
    edges = {n: {w for w in re.findall(r'\b(\w+)\b', body) if w in props and w != n} for n, body in props.items()}
    found, stack, done = [], [], set()

    def visit(n):
        if n in stack:
            found.append(stack[stack.index(n):] + [n])
            return
        if n in done:
            return
        stack.append(n)
        for m in sorted(edges[n]):
            visit(m)
        stack.pop()
        done.add(n)

    for n in sorted(edges):
        visit(n)
    return found


def main(paths):
    bad = False
    for path in paths:
        with open(path, encoding="utf-8") as f:
            found = cycles(properties(f.read()))
        for c in found:
            print(f"{path}: {' → '.join(c)}")
        bad = bad or bool(found)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
