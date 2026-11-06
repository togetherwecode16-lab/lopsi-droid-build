#!/usr/bin/env python3
"""Audit the generated ninja graph for inputs that can never be satisfied.

Ninja aborts the whole build on the *first* "missing and no known rule to make
it" input, so fixing them one at a time costs a full graph load per attempt
(~15 min here). This walks the generated .ninja files once and reports every
input that is neither produced by a rule nor present on disk, which turns that
15-minute loop into a single list.
"""
import os
import re
import sys

GRAPHS = [
    "out/build-dot_rosy.ninja",
    "out/soong/build.dot_rosy.ninja",
    "out/build-dot_rosy-package.ninja",
]

# Paths under these prefixes are produced by bazel into a separate output tree
# that is not part of this checkout; treat them as external rather than missing.
EXTERNAL_PREFIXES = ("out/bazel/",)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "/aosp"
    os.chdir(root)

    produced = set()
    inputs = set()

    for fn in GRAPHS:
        if not os.path.exists(fn):
            print(f"skip (absent): {fn}", flush=True)
            continue
        with open(fn, "r", errors="replace") as fh:
            for line in fh:
                if not line.startswith("build "):
                    continue
                body = line.split("\n", 1)[0]
                if ":" not in body:
                    continue
                lhs, rhs = body.split(":", 1)
                for out in lhs[6:].split():
                    if out and not out.startswith("$"):
                        produced.add(out)
                # Drop order-only (||) and implicit (|) dependency sections.
                rhs = re.sub(r"\|\|.*", "", rhs)
                for tok in rhs.split():
                    if not tok or tok.startswith(("$", "|")):
                        continue
                    if tok in ("&&", "||"):
                        continue
                    inputs.add(tok)

    print(f"rules/produced: {len(produced)}   distinct inputs: {len(inputs)}", flush=True)

    missing = []
    for tok in inputs:
        if tok in produced or "$" in tok:
            continue
        path = tok[1:] if tok.startswith("-") else tok
        if path.startswith(EXTERNAL_PREFIXES):
            continue
        if not os.path.exists(path):
            missing.append(path)

    missing.sort()
    print(f"MISSING (no rule, not on disk): {len(missing)}", flush=True)
    for m in missing:
        print("  ", m, flush=True)


if __name__ == "__main__":
    main()
