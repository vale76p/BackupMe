#!/usr/bin/env python3
"""Finds cycles among the computed properties of a type: two that read each other recurse until the stack is over,
and a view that does it crashes at its first render. The compiler cannot see them and the views have no tests here,
so this is the only guard before the app runs.

Usage: check-view-cycles.py file.swift ...   (every file of the module: an extension may live in another one)
Prints each cycle found (the first 100: a last line says when there are more) and exits 1; prints nothing and exits 0
when there is none; exits 2 on a usage error.
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
ATTRIBUTES = r'(?:(?:@[\w.]+(?:\((?:[^()]|\([^()]*\))*\))?)\s*)*'
TYPE = re.compile(START + ATTRIBUTES + r'((?:[A-Za-z_]+\s+)*)(struct|class|actor|enum|protocol|extension)\s+'
                  r'(?!(?:var|func|let)\b)(' + QUALIFIED + r')')
PROPERTY = re.compile(START + ATTRIBUTES + r'((?:' + IDENT + r'(?:\([^)\n]*\))?\s+)*)var\s+(' + IDENT + r')\s*:\s*'
                      r'[^{=\n]*?(?:\n[ \t]*)?\{')
OBSERVER = re.compile(r'\s*(?:willSet|didSet)\b')
HIDDEN = re.compile(r'\b(?:private|fileprivate)\b')
WORD = re.compile(IDENT)
MEMBER = re.compile(r'\.\s*$')
SELF = re.compile(r'\b(?:self|Self)\s*\??\s*\.\s*$')
REGEX_BEFORE = re.compile(r'(?:[=,(\[{:&|?;]|\b(?:return|case|else|try|await|throw|if|guard|in|while|where))\s*$')
BUDGET = 200_000
MAX_LISTED = 100


def blanked(src):
    """The source with comments, strings and regex literals turned into spaces: braces and names inside them are not
    code. The code inside a string interpolation stays, it runs like any other; a string inside it is skipped too."""
    out = list(src)
    i, n, stack = 0, len(src), []

    def space(start, stop):
        for k in range(start, min(stop, n)):
            if out[k] != '\n': out[k] = ' '

    while i < n:
        if stack and stack[-1][0] == 'string':
            _, closer, opening, hashes = stack[-1]
            if src.startswith(opening, i):
                # the interpolation's opening is not code; what is inside is, up to its closing parenthesis
                space(i, i + len(opening))
                i += len(opening)
                stack.append(['interpolation', 1])
            elif src[i] == '\\' and (not hashes or src.startswith('\\' + '#' * hashes, i)):
                # in a raw string only a backslash followed by its hashes escapes: a lone one is a character
                space(i, i + 2 + hashes)
                i += 2 + hashes
            elif src.startswith(closer, i):
                space(i, i + len(closer))
                i += len(closer)
                stack.pop()
            else:
                space(i, i + 1)
                i += 1
        elif stack and src[i] == '(' and stack[-1][0] == 'interpolation':
            stack[-1][1] += 1
            i += 1
        elif stack and src[i] == ')' and stack[-1][0] == 'interpolation':
            stack[-1][1] -= 1
            if not stack[-1][1]: space(i, i + 1); stack.pop()
            i += 1
        else:
            # code, at top level or inside an interpolation
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
                space(i, i + len(quotes))
                i += len(quotes)
                stack.append(['string', quotes[hashes:] + '#' * hashes, '\\' + '#' * hashes + '(', hashes])
            elif src[j:j + 1] == '/' and REGEX_BEFORE.search(src[:i]):
                # a regex literal can hold quotes and braces: it ends at the slash its escapes do not protect
                k = j + 1
                while k < n and not src.startswith('/' + '#' * hashes, k):
                    # in a regex literal a backslash escapes the next character, with or without hashes
                    if src[k] == '\\': k += 1
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
    """Each type declaration of a file, in order: (start, name, hidden, end, extended). `name` is qualified
    (`Outer.Inner`), `hidden` says that only the file can see the type, `extended` is the type an extension
    extends, None for a type."""
    raw = []
    for m in TYPE.finditer(clean):
        brace = clean.find('{', m.end())
        raw.append((m.start(), m.group(2), m.group(3), HIDDEN.search(m.group(1)) is not None,
                    closing(clean, brace) if brace >= 0 else -1))
    hidden, found = {}, []
    for _ in range(2):
        # twice: a type nested in an extension and an extension of it learn of each other in the second pass
        stack, found = [], []
        for start, kind, simple, private, end in raw:
            while stack and stack[-1][2] <= start: stack.pop()
            if kind == 'extension':
                # the extension's own modifiers say who sees its members; they hide a type nested in it, not its type
                own = private or hidden.get(simple, False)
                found.append((start, simple, own, end, simple))
                stack.append((simple, own, end))
            else:
                name = stack[-1][0] + '.' + simple if stack else simple
                own = private or (bool(stack) and stack[-1][1])
                found.append((start, name, own, end, None))
                hidden[name] = own
                stack.append((name, own, end))
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
        # a property at the top level is the whole module's, unless it is declared private
        key = owners[-1] if owners else ((path, '') if HIDDEN.search(m.group(1)) else '')
        found.append((key, m.group(2), src.count('\n', 0, m.start(2)) + 1, body))
    return found


def components(count, edges):
    """The sets of properties that reach each other: a cycle can only run inside one of them."""
    seen, order = set(), []
    for i in range(count):
        if i in seen: continue
        seen.add(i)
        stack = [(i, iter(sorted(edges[i])))]
        while stack:
            node, following = stack[-1]
            j = next(following, None)
            if j is None:
                order.append(node)
                stack.pop()
            elif j not in seen:
                seen.add(j)
                stack.append((j, iter(sorted(edges[j]))))
    back = {}
    for i in range(count):
        for j in edges[i]: back.setdefault(j, []).append(i)
    seen, found = set(), []
    for i in reversed(order):
        if i in seen: continue
        seen.add(i)
        group, stack = [], [i]
        while stack:
            node = stack.pop()
            group.append(node)
            for j in back.get(node, []):
                if j not in seen: seen.add(j); stack.append(j)
        if len(group) > 1 or group[0] in edges[group[0]]: found.append(group)
    return found


def cycles_in(files):
    """(whether a cycle exists, the lines to print). Each cycle is listed from its first property, so it comes out
    once; at most MAX_LISTED of them, then a line says so."""
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

    def label(j):
        declared_in = owner(nodes[j][1])
        return declared_in + '.' + nodes[j][2] if declared_in else nodes[j][2]

    groups = components(len(nodes), edges)
    found, left = [], [BUDGET]

    def walk(members, start, node, path):
        for j in sorted(edges[node]):
            if left[0] < 0: return
            left[0] -= 1
            if j == start: found.append(path)
            elif j in members and j > start and j not in path: walk(members, start, j, path + [j])

    for group in groups:
        for start in sorted(group): walk(set(group), start, start, [start])
    loops = sorted([(nodes[loop[0]][0], nodes[loop[0]][3], [label(j) for j in loop]) for loop in found],
                   key=lambda l: (l[0], l[1], l[2]))
    lines = [f"{path}:{line}: " + " → ".join(names + [names[0]]) for path, line, names in loops[:MAX_LISTED]]
    if not loops:
        # the search gave up before it could list one: the group it ran in still names the properties
        lines += [f"{nodes[g[0]][0]}:{nodes[g[0]][3]}: a cycle runs among: " + ", ".join(label(j) for j in sorted(g))
                  for g in groups]
    if len(loops) > MAX_LISTED or left[0] < 0:
        path = loops[MAX_LISTED][0] if len(loops) > MAX_LISTED else lines[-1].rsplit(":", 2)[0]
        lines.append(f"{path}: more cycles exist: the list stops here")
    return bool(groups), lines


def owner(scope):
    """The type's name, whether it is one every file can see or one that stays in its own file."""
    return scope[1] if isinstance(scope, tuple) else scope


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
    bad, lines = cycles_in(files)
    for line in lines: print(line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
