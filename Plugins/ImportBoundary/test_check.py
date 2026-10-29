import pathlib
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from check import check_sources, imported_modules


class ImportBoundaryTests(unittest.TestCase):
    def test_utf8_sources_under_non_utf8_locale(self):
        with tempfile.TemporaryDirectory() as folder:
            source = pathlib.Path(folder) / "fixture.swift"
            source.write_text("// 한글 주석\nimport AppKit\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "-X", "utf8=0", str(pathlib.Path(__file__).with_name("check.py")),
                 "Core", "Core", "Core", str(pathlib.Path(folder) / "output.swift"), str(source)],
                env={**os.environ, "LC_ALL": "ko_KR.eucKR", "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0"},
                capture_output=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"Core may import only Foundation; found AppKit", result.stderr)

    def test_leading_bom_preserves_first_import(self):
        self.assertEqual(imported_modules("\ufeffimport AppKit\nimport Foundation"), ["AppKit", "Foundation"])

    def test_lone_carriage_return_imports(self):
        source = "// import Shell\rimport Foundation\rlet text = \"import Storage\"\rimport AppKit\rimport Core"
        self.assertEqual(imported_modules(source), ["Foundation", "AppKit", "Core"])

    def test_comments_and_strings_are_not_imports(self):
        source = '''
// import Outbound
/* import AppKit /* import Storage */ */
let prose = "rows we import from elsewhere; import Shell"
let escaped = "escaped \\\"; import Outbound"
let raw = ##"raw \\"; import AppKit"##
let multiline = """
import AppKit
"""
let rawMultiline = #"""
import Outbound
"""#
import Foundation
'''
        self.assertEqual(imported_modules(source), ["Foundation"])

    def test_import_requires_a_statement_start(self):
        self.assertEqual(imported_modules("rows we import from elsewhere"), [])
        self.assertEqual(imported_modules("let x = 1; import Core"), ["Core"])

    def test_comments_inside_import_and_backticks(self):
        self.assertEqual(
            imported_modules("import /* x /* nested */ */ Outbound\nimport `AppKit`"),
            ["Outbound", "AppKit"],
        )

    def test_attributed_scoped_and_conditional_imports(self):
        source = '''
#if canImport(AppKit)
@testable import Core
@_exported import Outbound
@_spi(Testing) public import struct Storage.Row
@preconcurrency import AppKit
@_implementationOnly import Shell
internal import Foundation.NSObject
#endif
'''
        self.assertEqual(
            imported_modules(source),
            ["Core", "Outbound", "Storage", "AppKit", "Shell", "Foundation"],
        )

    def test_core_sources_import_only_foundation(self):
        root = pathlib.Path(__file__).resolve().parents[2] / "Sources" / "Core"
        sources = list(root.rglob("*.swift"))
        self.assertTrue(sources, "Core source check must not silently scan an empty directory")
        check_sources("Core", ["Core"], ["Core"], sources)

    def test_both_boundary_rules(self):
        modules = ["Core", "Storage", "Inbound", "Outbound", "Shell"]
        for module in ["AppKit", "Dispatch", "Storage"]:
            with self.subTest(module=module), patch.object(pathlib.Path, "read_text", return_value=f"import {module}"):
                with self.assertRaisesRegex(ValueError, "Core may import only Foundation"):
                    check_sources("Core", modules, ["Core"], ["fixture.swift"])
        with patch.object(pathlib.Path, "read_text", return_value="import /* x */ Outbound"):
            with self.assertRaisesRegex(ValueError, "Storage may not import Outbound"):
                check_sources("Storage", modules, ["Core", "Storage"], ["fixture.swift"])
        with patch.object(pathlib.Path, "read_text", return_value="import Foundation\nimport Core"):
            check_sources("Storage", modules, ["Core", "Storage"], ["fixture.swift"])

    def test_undeclared_external_product_module(self):
        modules = ["Core", "Storage", "VendorKit"]
        with patch.object(pathlib.Path, "read_text", return_value="import VendorKit"):
            with self.assertRaisesRegex(ValueError, "Storage may not import VendorKit"):
                check_sources("Storage", modules, ["Core", "Storage"], ["fixture.swift"])
            check_sources("Storage", modules, ["Core", "Storage", "VendorKit"], ["fixture.swift"])

    def test_query_target_never_imports_shell_even_when_declared(self):
        modules = ["Core", "Storage", "Inbound", "Outbound", "Shell", "Query", "ActivityQueryServer"]
        for target in ["Query", "ActivityQueryServer"]:
            for text in ["import Shell", "@testable import Shell", "@_exported import Shell"]:
                with self.subTest(target=target, text=text), \
                        patch.object(pathlib.Path, "read_text", return_value=f"import Core\n{text}"):
                    with self.assertRaisesRegex(ValueError, f"{target} may not import Shell; the query helper"):
                        check_sources(target, modules, modules, ["fixture.swift"])
        with patch.object(pathlib.Path, "read_text", return_value="import Core\nimport Darwin\nimport Foundation\nimport Outbound"):
            check_sources("Query", modules, ["Core", "Outbound", "Query"], ["fixture.swift"])
        # The rule is the query target's own: Shell itself and the executables may still import Shell.
        with patch.object(pathlib.Path, "read_text", return_value="import Shell"):
            check_sources("ActivityProbe", modules, ["Shell", "ActivityProbe"], ["fixture.swift"])



if __name__ == "__main__":
    unittest.main(verbosity=2)
