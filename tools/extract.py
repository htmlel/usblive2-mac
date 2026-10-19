#!/usr/bin/env python3
"""Extract whole C function definitions, verbatim, from Linux driver sources.

Usage: extract.py FILE func1 func2 ...
Prints each function (with its leading comment-free signature) in the order
requested, prefixed with a '/* from FILE:LINE */' marker so every ported
function can be traced back to the exact upstream line.
"""
import re
import sys


def find_function(src, name):
    # signature: start of line, return type..., name, '('  — not a call or prototype
    pat = re.compile(r'^(?!\s)([^\n;#{}]*?\b' + re.escape(name) + r')\s*\(', re.M)
    for m in pat.finditer(src):
        start = m.start()
        # walk to the matching ')' of the parameter list
        i = m.end() - 1
        depth = 0
        while i < len(src):
            c = src[i]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        j = i + 1
        while j < len(src) and src[j] in ' \t\n':
            j += 1
        if j >= len(src) or src[j] != '{':
            continue  # prototype, not a definition
        # brace match the body (ignoring braces in strings/chars/comments)
        k = j
        depth = 0
        in_str = None
        while k < len(src):
            c = src[k]
            nxt = src[k + 1] if k + 1 < len(src) else ''
            if in_str:
                if c == '\\':
                    k += 2
                    continue
                if c == in_str:
                    in_str = None
            elif c == '/' and nxt == '*':
                k = src.index('*/', k + 2) + 2
                continue
            elif c == '/' and nxt == '/':
                k = src.index('\n', k)
                continue
            elif c in '"\'':
                in_str = c
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    line = src.count('\n', 0, start) + 1
                    return src[start:k + 1], line
            k += 1
    raise SystemExit(f'function {name} not found')


def main():
    path = sys.argv[1]
    src = open(path).read()
    short = path.split('/')[-1]
    for name in sys.argv[2:]:
        body, line = find_function(src, name)
        print(f'/* ---- verbatim from linux {short}:{line} ---- */')
        print(body)
        print()


if __name__ == '__main__':
    main()
