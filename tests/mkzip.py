import os
import sys
import zipfile

# usage: mkzip.py <source-dir> <out.zip>
# GitHub's Linux runners ship zip(1); Git Bash on Windows does not, so the test
# suite builds its fixture archives with the standard library instead.
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for base, _, files in os.walk(src):
        for name in sorted(files):
            full = os.path.join(base, name)
            zf.write(full, os.path.relpath(full, src).replace(os.sep, "/"))
