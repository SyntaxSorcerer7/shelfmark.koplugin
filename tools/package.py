"""Build an installable Shelfmark plugin ZIP from the repository root."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import re

root = Path(__file__).resolve().parents[1]
version = re.search(r'version\s*=\s*"([^"]+)"', (root / "_meta.lua").read_text()).group(1)
output = root / "dist" / f"shelfmark.koplugin-v{version}.zip"
output.parent.mkdir(exist_ok=True)
with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
    for name in ("main.lua", "_meta.lua", "README.md", "LICENSE"):
        archive.write(root / name, f"shelfmark.koplugin/{name}")
print(output)
