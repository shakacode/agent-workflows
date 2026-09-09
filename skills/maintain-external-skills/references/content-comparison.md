# Compare installed contents

Set `UPSTREAM_SKILL_DIR` and `INSTALLED_SKILL_DIR` to one selected skill's
directories, then run:

```bash
python3 - "$UPSTREAM_SKILL_DIR" "$INSTALLED_SKILL_DIR" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: python3 - UPSTREAM_SKILL_DIR INSTALLED_SKILL_DIR")

def manifest(argument):
    root = Path(argument).resolve(strict=True)
    if not root.is_dir():
        raise RuntimeError(f"skill root is not a directory: {root}")
    files = {}
    def onerror(error): raise error
    for directory, directories, names in os.walk(root, onerror=onerror):
        for path in sorted(Path(directory) / name for name in directories + names):
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                path.resolve(strict=True)
                raise RuntimeError(f"unsupported nested symlink: {path}")
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise RuntimeError(f"unsupported path type: {path}")
            files[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if "SKILL.md" not in files:
        raise RuntimeError(f"missing SKILL.md in {root}")
    return files

upstream, installed = map(manifest, sys.argv[1:])
if upstream != installed:
    for name in sorted(set(upstream) | set(installed)):
        if upstream.get(name) != installed.get(name): print(f"content differs: {name}", file=sys.stderr)
    raise SystemExit(1)
print("content matches")
PY
```

The command follows a top-level skill-directory symlink, but rejects nested
symlinks and special files. A nonzero result is evidence to investigate, not a
request to overwrite the installed copy.
