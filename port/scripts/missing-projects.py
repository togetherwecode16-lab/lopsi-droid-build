#!/usr/bin/env python3
"""List manifest projects that have no directory in the checkout.

A partially synced tree produces a cascade of unrelated-looking build failures
(missing host tools, missing bazel jars) because soong and kati still emit
edges for projects that were never fetched. Comparing the manifest against the
working tree names those projects directly, which is the difference between
patching symptoms and fixing the cause.
"""
import os
import sys
import xml.etree.ElementTree as ET

root = sys.argv[1] if len(sys.argv) > 1 else "."
manifest_dir = os.path.join(root, ".repo/manifests")
manifest = os.path.join(root, ".repo/manifest.xml")

if not os.path.exists(manifest):
    sys.exit(f"no manifest at {manifest}")


def load(path, seen):
    """Resolve <include name=.../> against .repo/manifests/."""
    if path in seen or not os.path.exists(path):
        return []
    seen.add(path)
    out = []
    for elem in ET.parse(path).getroot():
        if elem.tag == "include":
            inc = elem.get("name")
            if inc:
                out.extend(load(os.path.join(manifest_dir, inc), seen))
        elif elem.tag in ("project", "remote-project"):
            out.append(elem)
    return out


elems = load(manifest, set())
projects = []
for elem in elems:
    p = elem.get("path") or elem.get("name")
    if p:
        projects.append((p, elem.get("revision")))

resolved = projects

missing = [(p, r) for p, r in resolved if not os.path.isdir(os.path.join(root, p))]

print(f"manifest projects: {len(resolved)}")
print(f"present on disk:   {len(resolved) - len(missing)}")
print(f"MISSING:           {len(missing)}")
for p, r in sorted(missing):
    print(f"   {p}  ({r})")
