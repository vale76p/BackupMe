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

SENTINEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-view-cycles.py")

# (what the case is about, its files, the cycles expected: for each, the properties that form it)
CASES = [
    ("two properties that read each other", {"S.swift": "struct S {\n    var a: Int { b }\n    var b: Int { a }\n}\n"}, ["S.a S.b"]),
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
    '''}, ["S.a S.b"]),
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
    ("private nested types with the same name in two files are not one",
     {"P.swift": "private struct Outer { struct Inner { var x: Int { y }; var y: Int { 1 } } }\n",
      "Q.swift": "private struct Outer { struct Inner { var y: Int { x }; var x: Int { 5 } } }\n"}, []),
    ("a read inside a string interpolation", {"S.swift": r'''
        struct J {
            var title: String { "\(count)" }
            var count: Int { title.count }
        }
    '''}, ["J.title J.count"]),
    ("a raw string", {"S.swift": r'''
        struct R {
            var a: Int {
                let s = #"a "b" { }"#
                return b
            }
            var b: Int { a }
        }
    '''}, ["R.a R.b"]),
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


def check(files):
    """(exit code, for each cycle: its line and the properties that form it)"""
    with tempfile.TemporaryDirectory() as folder:
        paths = []
        for name, src in files.items():
            paths.append(os.path.join(folder, name))
            with open(paths[-1], "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(src).lstrip("\n"))
        out = subprocess.run([sys.executable, SENTINEL] + paths, capture_output=True, text=True)
        cycles = []
        for line in out.stdout.splitlines():
            where, names = line.rsplit(": ", 1)
            cycles.append((int(where.rsplit(":", 1)[1]), sorted(set(names.split(" → ")))))
        return out.returncode, cycles


def main():
    failed = 0
    for label, files, expected in CASES:
        code, cycles = check(files)
        if code != (1 if expected else 0) or [names for _, names in cycles] != [sorted(name.split()) for name in expected]:
            failed += 1
            print(f"NO   {label}: expected {expected}, found {cycles} (exit {code})")
        else:
            print(f"ok   {label}")
    line = check(CASES[0][1])[1][0][0]
    if line != 2:
        failed += 1
        print(f"NO   the line of the first property: expected 2, found {line}")
    else:
        print("ok   the line of the first property")
    code = subprocess.run([sys.executable, SENTINEL], capture_output=True).returncode
    if code != 2:
        failed += 1
        print(f"NO   no file to check: expected exit 2, found exit {code}")
    else:
        print("ok   no file to check: exit 2")
    print(f"{len(CASES) + 2 - failed} of {len(CASES) + 2} cases passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
