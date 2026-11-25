#!/usr/bin/env python3
"""Finds cycles among the computed properties of a type: two that read each other recurse until the stack is over,
and a view that does it crashes at its first render. The compiler cannot see them and the views have no tests here,
so this is the only guard before the app runs.

Usage: check-view-cycles.py file.swift ...   (every file of the module: an extension may live in another one)
Prints each cycle found and exits 1; prints nothing and exits 0 when there is none; exits 2 on a usage error.
check-view-cycles-test.py, next to it, proves all of this: run it after changing this file.

What counts as a property: every `var name: Type { … }`, whatever its attributes and modifiers, wherever its brace
is. A property belongs to the type it is declared in, and an extension is part of its type, in this file or in
another one; a type declared private, or nested in one, is known only inside its own file. What counts as a read:
the name in a body as a free identifier or after `self.` or `Self.`, outside comments, strings and regex literals
(the code inside a string interpolation counts: it runs).

What it does not see: a cycle that passes through a function. What it can get wrong: a local variable or a closure
parameter with a property's name reads as that property, which can report a cycle that is not there.
"""
import re
import sys

IDENT = r'[A-Za-z_][A-Za-z0-9_]*'
QUALIFIED = IDENT + r'(?:\.' + IDENT + r')*'
START = r'(?:^|[\n;{}])[ \t]*'
ATTRIBUTES = r'(?:(?:@[\w.]+(?:\([^\n]*\))?)\s*)*'
TYPE = re.compile(START + ATTRIBUTES + r'((?:[A-Za-z_]+\s+)*)(struct|class|actor|enum|protocol|extension)\s+'
                  r'(?!(?:var|func|let)\b)(' + QUALIFIED + r')')
PROPERTY = re.compile(START + ATTRIBUTES + r'(?:' + IDENT + r'(?:\([^)\n]*\))?\s+)*?var\s+(' + IDENT + r')\s*:\s*'
                      r'[^{=\n]*?(?:\n[ \t]*)?\{')
OBSERVER = re.compile(r'\s*(?:willSet|didSet)\b')
HIDDEN = re.compile(r'\b(?:private|fileprivate)\b')
WORD = re.compile(IDENT)
MEMBER = re.compile(r'\.\s*$')
SELF = re.compile(r'\b(?:self|Self)\s*\.\s*$')
REGEX_BEFORE = re.compile(r'(?:[=,(\[{:&|?;]|\b(?:return|case|else|try|await|throw|if|guard|in))\s*$')
LIMIT = 1000


def blanked(src):
    """The source with comments, strings and regex literals turned into spaces: braces and names inside them are not
    code. The code inside a string interpolation stays, it runs like any other."""
    out = list(src)
    i, n = 0, len(src)

    def space(start, stop):
        for k in range(start, min(stop, n)):
            if out[k] != '\n': out[k] = ' '

    while i < n:
        j = i
        while src[j:j + 1] == '#': j += 1
        hashes = j - i
        if src.startswith('//', j):
            end = src.find('\n', j)
            space(i, n if end < 0 else end)
            i = n if end < 0 else end
        elif src.startswith('/*', j):
            depth, k = 1, j + 2
            while k < n and depth:
                if src.startswith('/*', k): depth, k = depth + 1, k + 2
                elif src.startswith('*/', k): depth, k = depth - 1, k + 2
                else: k += 1
            space(i, k)
            i = k
        elif src.startswith('"""', j) or src[j:j + 1] == '"':
            quotes = src[i:j + 3] if src.startswith('"""', j) else src[i:j + 1]
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
                    k = i + 1
                    while hashes and src[k:k + 1] == '#': k += 1
                    space(i, k + 1)
                    i = k + 1
                elif src.startswith(closer, i):
                    space(i, i + len(closer))
                    i += len(closer)
                    break
                else:
                    space(i, i + 1)
                    i += 1
        elif src[j:j + 1] == '/' and REGEX_BEFORE.search(src[:i]):
            # a regex literal can hold quotes and braces: it ends at the slash its escapes do not protect
            k = j + 1
            while k < n and not src.startswith('/' + '#' * hashes, k):
                if src[k] == '\\':
                    k += 1
                    while hashes and src[k:k + 1] == '#': k += 1
                k += 1
            space(i, min(k + 1 + hashes, n))
            i = min(k + 1 + hashes, n)
        else:
            i += 1
    return ''.join(out)


def closing(clean, opening):
    """Where the brace opened at `opening` closes; the end of the text if it never does."""
    depth, i = 1, opening + 1
    while i < len(clean) and depth:
        depth += (clean[i] == '{') - (clean[i] == '}')
        i += 1
    return i - 1


def declarations(clean):
    """Each type declaration of a file, in order: (start, qualified name, hidden, end, extended). `hidden` says that
    only the file can see the type; `extended` is the type an extension extends, None for a type."""
    found, stack = [], []
    for m in TYPE.finditer(clean):
        while stack and stack[-1][3] <= m.start(): stack.pop()
        brace = clean.find('{', m.end())
        end = closing(clean, brace) if brace >= 0 else -1
        if m.group(2) == 'extension':
            # the extension's own modifiers say who sees its members, not who knows the type
            found.append((m.start(), m.group(3), False, end, m.group(3)))
            continue
        name = stack[-1][1] + '.' + m.group(3) if stack else m.group(3)
        hidden = HIDDEN.search(m.group(1)) is not None or (bool(stack) and stack[-1][2])
        found.append((m.start(), name, hidden, end, None))
        stack.append((m.start(), name, hidden, end))
    return found


def scopes(path, decls):
    """For each declaration: the key its properties are known under. A type only its own file can see gets the file."""
    local = {name for _, name, hidden, _, extended in decls if extended is None and hidden}
    keys = []
    for _, name, hidden, _, extended in decls:
        if extended is None: keys.append((path, name) if hidden else name)
        else: keys.append((path, extended) if extended in local else extended)
    return keys


def properties(path, src):
    """The computed properties of a file: the key of their type, their name, their line, their body."""
    clean = blanked(src)
    decls = declarations(clean)
    keys = scopes(path, decls)
    found = []
    for m in PROPERTY.finditer(clean):
        opening = m.end() - 1
        end = closing(clean, opening)
        body = clean[opening + 1:end]
        # a stored property has braces too, for its observers, and reading it in its own didSet is no recursion
        if OBSERVER.match(body): continue
        owners = [k for k, d in zip(keys, decls) if d[0] <= m.start() and end <= d[3]]
        found.append((owners[-1] if owners else (path, ''), m.group(1), src.count('\n', 0, m.start(1)) + 1, body))
    return found


def owner(scope):
    """The type's name, whether it is one every file can see or one that stays in its own file."""
    return scope[1] if isinstance(scope, tuple) else scope


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
    found = []

    def walk(start, node, path):
        # a cycle is listed from its first property, so each comes out once
        for j in sorted(edges[node]):
            if len(found) >= LIMIT: return
            if j == start: found.append(path)
            elif j > start and j not in path: walk(start, j, path + [j])

    for start in range(len(nodes)): walk(start, start, [start])
    cycles = []
    for loop in found:
        path, _, _, line, _ = nodes[loop[0]]
        names = []
        for j in loop:
            type = owner(nodes[j][1])
            names.append(type + '.' + nodes[j][2] if type else nodes[j][2])
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
