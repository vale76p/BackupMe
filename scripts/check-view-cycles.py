#!/usr/bin/env python3
"""Finds cycles among the computed properties of a type: two that read each other recurse until the stack is over,
and a view that does it crashes at its first render. The compiler cannot see them and the views have no tests here,
so this is the only guard before the app runs.

Usage: check-view-cycles.py file.swift ...   (every file of the module: an extension may live in another one)
Prints each cycle found and exits 1; prints nothing and exits 0 when there is none; exits 2 on a usage error.
check-view-cycles-test.py, next to it, proves all of this: run it after changing this file.

What counts as a property: every `var name: Type { … }`, whatever its attributes and modifiers, wherever its brace
is; an extension is part of its type, in this file or in another one (a private type stays in its own file). What
counts as a read: the name in a body as a free identifier or after `self.`, outside comments, strings and regex
literals (the code inside a string interpolation counts: it runs).

What it does not see: a cycle that passes through a function. What it can get wrong: a local variable or a closure
parameter with a property's name reads as that property, which can report a cycle that is not there.
"""
import re
import sys

IDENT = r'[A-Za-z_][A-Za-z0-9_]*'
START = r'(?:^|[\n;{}])[ \t]*'
ATTRIBUTES = r'(?:(?:@[\w.]+(?:\([^\n]*\))?)\s*)*'
TYPE = re.compile(START + ATTRIBUTES + r'((?:(?:final|public|open|internal|private|fileprivate|indirect)\s+)*)'
                  r'(?:struct|class|actor|enum|extension)\s+(?!(?:var|func|let)\b)(' + IDENT + r')')
PROPERTY = re.compile(START + ATTRIBUTES + r'(?:' + IDENT + r'(?:\([^)\n]*\))?\s+)*?var\s+(' + IDENT + r')\s*:\s*'
                      r'[^{=\n]*?(?:\n[ \t]*)?\{')
OBSERVER = re.compile(r'\s*(?:willSet|didSet)\b')
WORD = re.compile(IDENT)
MEMBER = re.compile(r'\.\s*$')
SELF = re.compile(r'\bself\s*\.\s*$')
REGEX_BEFORE = re.compile(r'[=,(\[{!&|?;]\s*$')


def blanked(src):
    """The source with comments, strings and regex literals turned into spaces: braces and names inside them are not
    code. The code inside a string interpolation stays, it runs like any other."""
    out = list(src)
    i, n = 0, len(src)

    def space(start, stop):
        for k in range(start, min(stop, n)):
            if out[k] != '\n': out[k] = ' '

    while i < n:
        if src.startswith('//', i):
            end = src.find('\n', i)
            space(i, n if end < 0 else end)
            i = n if end < 0 else end
        elif src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j): depth, j = depth + 1, j + 2
                elif src.startswith('*/', j): depth, j = depth - 1, j + 2
                else: j += 1
            space(i, j)
            i = j
        elif src[i] == '/' and REGEX_BEFORE.search(src[:i]):
            # a regex literal can hold quotes and braces; one that does not close on its line is not read as one
            end = src.find('\n', i)
            stop = src.find('/', i + 1, n if end < 0 else end)
            space(i, stop + 1)
            i = stop + 1 if stop >= 0 else i + 1
        else:
            j = i
            while src[j:j + 1] == '#': j += 1
            if src.startswith('"""', j): quotes = src[i:j + 3]
            elif src[j:j + 1] == '"': quotes = src[i:j + 1]
            else:
                i += 1
                continue
            hashes = len(quotes) - len(quotes.lstrip('#'))
            closer = quotes[hashes:] + '#' * hashes
            interpolation = '\\' + '#' * hashes + '('
            space(i, i + len(quotes))
            i += len(quotes)
            while i < n:
                if src.startswith(interpolation, i):
                    # the interpolation's opening is not code; what is inside is, up to its closing parenthesis
                    space(i, i + len(interpolation))
                    i, depth = i + len(interpolation), 1
                    while i < n and depth:
                        depth += (src[i] == '(') - (src[i] == ')')
                        if not depth: space(i, i + 1)
                        i += 1
                elif src[i] == '\\':
                    j = i + 1
                    while hashes and src[j:j + 1] == '#': j += 1
                    space(i, j + 1)
                    i = j + 1
                elif src.startswith(closer, i):
                    space(i, i + len(closer))
                    i += len(closer)
                    break
                else:
                    space(i, i + 1)
                    i += 1
    return ''.join(out)


def closing(clean, opening):
    """Where the brace opened at `opening` closes; the end of the text if it never does."""
    depth, i = 1, opening + 1
    while i < len(clean) and depth:
        depth += (clean[i] == '{') - (clean[i] == '}')
        i += 1
    return i - 1


def owner(scope):
    """The type's name, whether it is one every file can see or one that stays in its own file."""
    return scope[1] if isinstance(scope, tuple) else scope


def properties(path, src):
    """The computed properties of a file: the type they are declared in, their name, their line, their body."""
    clean = blanked(src)
    types = []
    for m in TYPE.finditer(clean):
        brace = clean.find('{', m.end())
        if brace >= 0:
            # a type that only its own file can see cannot be extended from another one
            types.append((m.start(), (path, m.group(2)) if 'private' in m.group(1) else m.group(2), closing(clean, brace)))
    found = []
    for m in PROPERTY.finditer(clean):
        opening = m.end() - 1
        end = closing(clean, opening)
        body = clean[opening + 1:end]
        # a stored property has braces too, for its observers, and reading it in its own didSet is no recursion
        if OBSERVER.match(body): continue
        owners = [scope for start, scope, stop in types if start <= m.start() and end <= stop]
        found.append((owners[-1] if owners else (path, ''), m.group(1), src.count('\n', 0, m.start(1)) + 1, body))
    return found


def cycles_in(files):
    """Each cycle once: the file and the line of its first property, and the names that form it, back to the first."""
    nodes, by_name = [], {}
    for path, src in files:
        for scope, name, line, body in properties(path, src):
            by_name.setdefault((scope, name), []).append(len(nodes))
            nodes.append((path, scope, name, line, body))
    edges = []
    for _, scope, _, _, body in nodes:
        reads = set()
        for word in WORD.finditer(body):
            # a member access is somebody else's, unless it goes through `self`
            if MEMBER.search(body, 0, word.start()) and not SELF.search(body, 0, word.start()): continue
            reads.add(word.group())
        edges.append({j for read in reads for j in by_name.get((scope, read), [])})
    found, seen, stack, done = [], set(), [], set()

    def visit(i):
        if i in stack:
            loop = stack[stack.index(i):]
            if frozenset(loop) not in seen:
                seen.add(frozenset(loop))
                found.append(loop)
            return
        if i in done: return
        stack.append(i)
        for j in sorted(edges[i]): visit(j)
        stack.pop()
        done.add(i)

    for i in range(len(nodes)): visit(i)
    cycles = []
    for loop in found:
        path, _, _, line, _ = nodes[loop[0]]
        names = [owner(nodes[j][1]) + '.' + nodes[j][2] for j in loop]
        cycles.append((path, line, names + [names[0]]))
    return cycles


def main(paths):
    if not paths:
        print("usage: check-view-cycles.py file.swift ...", file=sys.stderr)
        return 2
    files = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                files.append((path, f.read()))
        except OSError as error:
            print(error, file=sys.stderr)
            return 2
    found = cycles_in(files)
    for path, line, names in found:
        print(f"{path}:{line}: " + " → ".join(names))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
