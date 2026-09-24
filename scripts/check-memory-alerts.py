#!/usr/bin/env python3
"""Validate and exercise the node memory alert with the installed promtool."""
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    spec = yaml.safe_load((root / "platform/observability/71-node-memory-rules.yaml").read_text())["spec"]
    (tmp / "rules.yaml").write_text(yaml.safe_dump(spec))
    shutil.copy(root / "tests/node-memory.test.yaml", tmp / "test.yaml")
    subprocess.run(["promtool", "check", "rules", str(tmp / "rules.yaml")], check=True)
    subprocess.run(["promtool", "test", "rules", str(tmp / "test.yaml")], check=True)
