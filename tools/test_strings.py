#!/usr/bin/env python3
"""Manual shell labels survive compiler extraction, including removal of legacy callers."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import strings


class ExtractionTest(unittest.TestCase):
    def test_shared_manual_keys_survive_found_then_vanished(self):
        keys = ["%lld min", "Other", "Distraction", "Private"]
        original = strings.load(strings.CATALOG)
        catalog = {"strings": {key: original["strings"][key] for key in keys}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            path.write_text(json.dumps(catalog))
            data = Path(directory) / "compiler.stringsdata"
            data.touch()
            found = {"tables": {"Localizable": [{"key": key} for key in keys]}}
            with patch.object(strings, "CATALOG", path), patch.object(strings, "STRINGS_DIR", Path(directory)), \
                    patch.object(strings.subprocess, "run"), patch.object(strings.plistlib, "loads", return_value=found), \
                    contextlib.redirect_stdout(io.StringIO()):
                strings.extract()
                self.assertTrue(all(entry.get("extractionState") == "manual"
                                    for entry in strings.load(path)["strings"].values()))
                data.unlink()
                strings.extract()
            self.assertEqual(strings.load(path), catalog)


if __name__ == "__main__":
    unittest.main()
