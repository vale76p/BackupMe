#!/usr/bin/env python3
"""Proves check-view-cycles.py: the cycles it has to find and the code it has to leave alone. Run it after changing
the sentinel:

python3 scripts/check-view-cycles-test.py
"""
import os
import subprocess
import sys
import tempfile
import textwrap
import time

SENTINEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-view-cycles.py")

# (what the case is about, its files, the cycles expected: for each, the properties that form it)
CYCLE = ["S.a S.b"]
CASES = [
    ("two properties that read each other", {"S.swift": "struct S {\n    var a: Int { b }\n    var b: Int { a }\n}\n"}, CYCLE),
    ("a property that reads itself", {"S.swift": "struct S {\n    var a: Int { self.a }\n}\n"}, ["S.a"]),
    ("a stored property with an observer is not one", {"S.swift": "struct S {\n    var a: String? { didSet { load(a) } }\n}\n"}, []),
    ("the same name in two types: only the one that cycles", {"S.swift": """
        struct A { var x: Int { y }; var y: Int { x } }
        struct B { var x: Int { 1 }; var y: Int { x } }
    """}, ["A.x A.y"]),
    ("a view with three properties and a later view with one of their names", {"S.swift": """
        struct W {
            var plan: Int { selection }
            var selection: Int { barFile }
            var barFile: Int? { plan }
        }
        struct OtherView { var selection: Int { 5 } }
    """}, ["W.plan W.selection W.barFile"]),
    ("a member access is not a read", {"S.swift": r'''
        struct V {
            var body: some View { Text("x").font(.body.monospaced()) }
            var text: String { body }
        }
    '''}, []),
    ("a brace inside a string", {"S.swift": r'''
        struct S {
            var a: Int {
                let s = "}"
                return b
            }
            var b: Int { a }
        }
    '''}, CYCLE),
    ("a name inside a comment or a string is not a read", {"S.swift": r'''
        struct S {
            var a: Int { b }
            var b: Int { 1 } // a
            var c: String { "a" }
        }
    '''}, []),
    ("static properties", {"S.swift": """
        enum E {
            static var a: Int { b }
            static var b: Int { a }
        }
    """}, ["E.a E.b"]),
    ("a read through `Self.`", {"S.swift": """
        enum E {
            static var a: Int { Self.b }
            static var b: Int { Self.a }
        }
    """}, ["E.a E.b"]),
    ("any attributes and modifiers", {"S.swift": """
        struct T {
            @ViewBuilder
            @MainActor public private(set) nonisolated var a: some View { b }
            private var b: some View { a }
        }
    """}, ["T.a T.b"]),
    ("an attribute written on several lines", {"S.swift": r'''
        struct A {
            @Attribute(
                key: "value {"
            )
            var a: Int { b }
            var b: Int { a }
        }
    '''}, ["A.a A.b"]),
    ("a brace on the next line", {"S.swift": """
        struct G
        {
            var a: Int { b }
            var b: Int
            {
                a
            }
        }
    """}, ["G.a G.b"]),
    ("an extension is part of its type", {"S.swift": """
        struct H { var a: Int { b } }
        extension H { var b: Int { a } }
    """}, ["H.a H.b"]),
    ("an extension in another file", {"H.swift": "struct H { var a: Int { b } }\n",
                                      "H+More.swift": "extension H { var b: Int { a } }\n"}, ["H.a H.b"]),
    ("a `private extension` does not hide the type", {"S.swift": """
        struct S { var a: Int { b } }
        private extension S { var b: Int { a } }
        struct U { var a: Int { b } }
        fileprivate extension U { var b: Int { a } }
    """}, ["S.a S.b", "U.a U.b"]),
    ("an extension of a private type of the same file", {"S.swift": """
        private struct Row { var a: Int { b } }
        extension Row { var b: Int { a } }
    """}, ["Row.a Row.b"]),
    ("a `package` type extended in another file", {"S.swift": "package struct S { var a: Int { b } }\n",
                                                   "S+More.swift": "extension S { var b: Int { a } }\n"}, ["S.a S.b"]),
    ("an extension of a nested type", {"S.swift": """
        struct Outer {
            struct Inner { var a: Int { b } }
        }
        extension Outer.Inner { var b: Int { a } }
    """}, ["Outer.Inner.a Outer.Inner.b"]),
    ("a type nested in an extension, extended again", {"S.swift": """
        struct Outer { }
        extension Outer {
            struct Inner { var a: Int { b } }
        }
        extension Outer.Inner { var b: Int { a } }
    """}, ["Outer.Inner.a Outer.Inner.b"]),
    ("two unrelated types with the same names", {"S.swift": """
        struct P { var a: Int { b } }
        struct Q { var b: Int { 1 } }
    """}, []),
    ("two private types with the same name in two files are not one", {"P.swift": "private struct Row { var a: Int { b } }\n",
                                                                       "Q.swift": "private struct Row { var b: Int { a } }\n"}, []),
    ("nested types with the same name under two types are not one", {"S.swift": """
        struct P { struct Inner { var x: Int { y }; var y: Int { 1 } } }
        struct Q { struct Inner { var y: Int { x }; var x: Int { 5 } } }
    """}, []),
    ("types with the same name nested in two extensions are not one", {"S.swift": """
        struct P { }
        struct Q { }
        extension P { struct Inner { var x: Int { y }; var y: Int { 1 } } }
        extension Q { struct Inner { var y: Int { x }; var x: Int { 5 } } }
    """}, []),
    ("private nested types with the same name in two files are not one",
     {"P.swift": "private struct Outer { struct Inner { var x: Int { y }; var y: Int { 1 } } }\n",
      "Q.swift": "private struct Outer { struct Inner { var y: Int { x }; var x: Int { 5 } } }\n"}, []),
    ("types with the same name in two private extensions in two files are not one",
     {"P.swift": "struct P { }\nprivate extension P { struct Helper { var x: Int { y }; var y: Int { 1 } } }\n",
      "Q.swift": "struct Q { }\nprivate extension Q { struct Helper { var y: Int { x }; var x: Int { 5 } } }\n"}, []),
    ("a read inside a string interpolation", {"S.swift": r'''
        struct J {
            var title: String { "\(count)" }
            var count: Int { title.count }
        }
    '''}, ["J.title J.count"]),
    ("a string inside an interpolation, holding a brace", {"S.swift": r'''
        struct N {
            var a: Int {
                let s = "\(wrap("{"))"
                return s.count + b
            }
            var b: Int { a }
        }
    '''}, ["N.a N.b"]),
    ("a raw string", {"S.swift": r'''
        struct R {
            var a: Int {
                let s = #"a "b" { }"#
                return b
            }
            var b: Int { a }
        }
    '''}, ["R.a R.b"]),
    ("computed properties at the top level of two files", {"A.swift": "var a: Int { b }\n", "B.swift": "var b: Int { a }\n"}, ["a b"]),
    ("private computed properties at the top level of two files are not one",
     {"A.swift": "private var a: Int { b }\n", "B.swift": "private var b: Int { a }\n"}, []),
    ("a string inside an interpolation of a raw string, holding a brace", {"S.swift": r'''
        struct N {
            var a: Int {
                let s = #"\#(wrap("{"))"#
                return s.count + b
            }
            var b: Int { a }
        }
    '''}, ["N.a N.b"]),
    ("a raw string that ends with a backslash", {"S.swift": r'''
        struct R {
            var a: Int {
                let s = #"a\"#
                return s.count + b
            }
            var b: Int { a }
        }
    '''}, ["R.a R.b"]),
    ("an extended regex literal with a lone backslash", {"S.swift": r'''
        struct X {
            var a: Int {
                let r = #/a\*/#
                return r == nil ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("an extended regex literal whose escaped slash comes before its hashes", {"S.swift": r'''
        struct X {
            var a: Int {
                let r = #/x\/#[{]/#
                return r == nil ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal", {"S.swift": r'''
        struct X {
            var a: Int {
                let r = /"|{/
                return b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal after `return`, holding a brace", {"S.swift": r'''
        struct X {
            var a: Int {
                let s = "x"
                return /^}$/.wholeMatch(in: s) == nil ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal after `where`, holding a brace", {"S.swift": r'''
        struct X {
            var a: Int {
                var n = 0
                for s in ["x", "y"] where /^}$/.wholeMatch(in: s) != nil { n += 1 }
                return n > 0 ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("an extended regex literal", {"S.swift": r'''
        struct X {
            var a: Int {
                let ok = #/^}$/#.wholeMatch(in: "x") == nil
                return ok ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal on several lines", {"S.swift": r'''
        struct X {
            var a: Int {
                let r = /^
                    }|{
                    $/
                return (r.wholeMatch(in: "x") == nil) ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a division after a force unwrap is not a regex literal", {"S.swift": r'''
        struct D {
            var a: Int {
                let d = [1: 2]
                let x = d[1]! / 2
                return x + b
            }
            var b: Int { a }
        }
    '''}, ["D.a D.b"]),
    ("cycles that share properties, each one listed", {"S.swift": """
        struct S {
            var a: Int { flag ? b : c }
            var b: Int { a }
            var c: Int { b }
            var flag: Bool { true }
        }
    """}, ["S.a S.b", "S.a S.b S.c"]),
    ("a nested type is its own", {"S.swift": """
        struct Outer {
            var a: Int { inner }
            var inner: Inner { Inner() }
            struct Inner {
                var x: Int { y }
                var y: Int { x }
            }
        }
    """}, ["Outer.Inner.x Outer.Inner.y"]),
    ("a stored property is not read as one", {"S.swift": "struct S {\n    var a: Int = 0\n    var b: Int { a }\n}\n"}, []),
]

def dense(count, back):
    """A type whose every property reads all the later ones; with `back`, the last one reads the first."""
    rows = ["    var p%d: Int { %s }" % (i, " ".join("p%d" % j for j in range(i + 1, count)) or "0") for i in range(count)]
    if back: rows[-1] = "    var p%d: Int { p0 }" % (count - 1)
    return {"D.swift": "struct D {\n" + "\n".join(rows) + "\n}\n"}


def pairs(count):
    """`count` types of two properties that read each other: as many cycles, and not one more."""
    return {"P.swift": "".join("struct P%d {\n    var a: Int { b }\n    var b: Int { a }\n}\n" % i for i in range(count))}


# (what the case is about, its files, the exit code expected, how many cycles must be listed, whether a last line
# says there are more)
BOUNDED = [
    ("a type dense with reads and no cycle is fast", lambda: dense(40, False), 0, 0, False),
    ("a type dense with reads and one cycle is answered in bounded time", lambda: dense(24, True), 1, 100, True),
    ("a hundred cycles are all listed, and no line says there are more", lambda: pairs(100), 1, 100, False),
    ("a hundred and one cycles: a hundred listed, then a line that says there are more", lambda: pairs(101), 1, 100, True),
]


def check(files):
    """(exit code, seconds, for each cycle: its line and the properties that form it)"""
    with tempfile.TemporaryDirectory() as folder:
        paths = []
        for name, src in files.items():
            paths.append(os.path.join(folder, name))
            with open(paths[-1], "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(src).lstrip("\n"))
        started = time.time()
        out = subprocess.run([sys.executable, SENTINEL] + paths, capture_output=True, text=True)
        cycles = []
        for line in out.stdout.splitlines():
            where, names = line.rsplit(": ", 1)
            cycles.append((int(where.rsplit(":", 1)[1]) if where.rsplit(":", 1)[-1].isdigit() else None,
                           sorted(set(names.split(" → ")))))
        return out.returncode, time.time() - started, cycles


def main():
    failed, passed = 0, 0

    def ok(label, good, found):
        nonlocal failed, passed
        if good: passed += 1; print(f"ok   {label}")
        else: failed += 1; print(f"NO   {label}: {found}")

    for label, files, expected in CASES:
        code, _, cycles = check(files)
        ok(label, code == (1 if expected else 0) and [names for _, names in cycles] == [sorted(name.split()) for name in expected],
           f"expected {expected}, found {cycles} (exit {code})")
    for label, files, expected, listed, more in BOUNDED:
        code, seconds, cycles = check(files())
        listed_here = [line for line, _ in cycles if line is not None]
        ok(label, code == expected and seconds < 10 and len(listed_here) == listed and (len(cycles) > len(listed_here)) == more,
           f"expected exit {expected} with {listed} cycles listed and a last line saying there are more: {more}; "
           f"found exit {code} in {seconds:.1f} s with {len(listed_here)} cycles listed and {len(cycles) - len(listed_here)} other lines")
    line = check(CASES[0][1])[2][0][0]
    ok("the line of the first property", line == 2, f"expected 2, found {line}")
    code = subprocess.run([sys.executable, SENTINEL], capture_output=True).returncode
    ok("no file to check: exit 2", code == 2, f"expected exit 2, found exit {code}")
    print(f"{passed} of {passed + failed} cases passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
