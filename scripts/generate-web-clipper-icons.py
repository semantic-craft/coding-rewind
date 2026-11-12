#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import json
from pathlib import Path
import subprocess


root = Path(__file__).resolve().parent.parent
extension = root / "extensions" / "web-clipper"
manifest = json.loads((extension / "manifest.json").read_text())
artwork = root / "Resources" / "AppIcon-artwork.png"

for size, resource in manifest["icons"].items():
    destination = extension / resource
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["sips", "-z", size, size, str(artwork), "--out", str(destination)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    print(f"Generated {destination.relative_to(root)} ({size}x{size})")
