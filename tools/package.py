"""Build an installable Shelfmark plugin ZIP from the repository root."""
import argparse
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import re

root = Path(__file__).resolve().parents[1]
version = re.search(r'version\s*=\s*"([^"]+)"', (root / "_meta.lua").read_text()).group(1)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tag", help="Require the release tag to match the plugin version")
args = parser.parse_args()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
    parser.error("Plugin version must be X.Y.Z with an optional prerelease suffix")
if args.tag is not None and args.tag != f"v{version}":
    parser.error(f"Release tag {args.tag!r} must match plugin version v{version}")
output = root / "dist" / f"shelfmark.koplugin-v{version}.zip"
output.parent.mkdir(exist_ok=True)
with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
    for name in ("main.lua", "_meta.lua", "README.md", "LICENSE"):
        archive.write(root / name, f"shelfmark.koplugin/{name}")
print(output)
