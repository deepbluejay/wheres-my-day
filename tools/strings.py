#!/usr/bin/env python3
"""String Catalog upkeep for ActivityProbe.

  strings.py extract              keys the compiler finds in the code → Resources/Localizable.xcstrings
                                  (new keys added, vanished keys marked stale)
  strings.py import LANG FILE     merge translations from a JSON object {"English key": "translation"}
                                  (ko is marked translated, other languages needs_review)
  strings.py check                list keys without a translation, per language; exit 1 if any
  strings.py compile DIR          compile both catalogs into DIR/<lang>.lproj (probe.sh build does this);
                                  stale keys stay in the catalog as history and are left out of the bundle

Keys are the English text. SwiftUI literals (Text, Button, Toggle…), String(localized:) and
Loc.out/Loc.text all take String.LocalizationValue / LocalizedStringKey, so the compiler's own
extraction (-emit-localized-strings, what Xcode uses) finds them; xcstringstool's lightweight
`extract` misses SwiftUI literals and its `sync` did not add new keys when tried, hence this script.
"""
import json
import re
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources/Localizable.xcstrings"
INFOPLIST_CATALOG = ROOT / "Resources/InfoPlist.xcstrings"
CATALOGS = [CATALOG, INFOPLIST_CATALOG]
LANGUAGES = ["ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"]
STRINGS_DIR = ROOT / ".build/strings"


def load(path):
    if path.exists():
        return json.loads(path.read_text())
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(path, catalog):
    catalog["strings"] = dict(sorted(catalog["strings"].items(), key=lambda kv: kv[0].lower()))
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n")


def extract():
    subprocess.run(
        ["swift", "build", "--jobs", "1", "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path",
         "-Xswiftc", str(STRINGS_DIR)], cwd=ROOT, check=True, capture_output=True)
    found = {}
    for path in STRINGS_DIR.glob("*.stringsdata"):
        data = plistlib.loads(subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(path)],
                                             capture_output=True, check=True).stdout)
        for entry in data.get("tables", {}).get("Localizable", []):
            if entry["key"].strip():  # hidden labels (Picker("")) have nothing to translate
                found.setdefault(entry["key"], path.stem)
    catalog = load(CATALOG)
    strings = catalog["strings"]
    added = [k for k in found if k not in strings]
    for key in added:
        strings[key] = {}
    # A vanished key nobody translated yet is simply dropped; translated ones stay, marked stale.
    for key in [k for k, v in strings.items() if k not in found and not v.get("localizations")
                and v.get("extractionState") != "manual"]:
        del strings[key]
    stale = 0
    for key, entry in strings.items():
        if key in found:
            if entry.get("extractionState") != "manual":
                entry.pop("extractionState", None)
        elif entry.get("extractionState") != "manual":
            entry["extractionState"] = "stale"
            stale += 1
    save(CATALOG, catalog)
    print(f"{len(found)} keys in code, {len(added)} new, {stale} stale")
    for key in added:
        print(f"  + [{found[key]}] {key}")


def import_translations(language, file):
    path = INFOPLIST_CATALOG if file.endswith("infoplist.json") else CATALOG
    catalog = load(path)
    translations = json.loads(pathlib.Path(file).read_text())
    state = "translated" if language in ("ko", "en") else "needs_review"
    unknown = []
    for key, value in translations.items():
        if key not in catalog["strings"]:
            if path == INFOPLIST_CATALOG:
                catalog["strings"][key] = {"extractionState": "manual"}
            else:
                unknown.append(key)
                continue
        if isinstance(value, dict):  # plural forms: {"one": "...", "other": "..."}
            unit = {"variations": {"plural": {form: {"stringUnit": {"state": state, "value": text}}
                                              for form, text in value.items()}}}
        else:
            unit = {"stringUnit": {"state": state, "value": value}}
        catalog["strings"][key].setdefault("localizations", {})[language] = unit
    save(path, catalog)
    print(f"{language}: {len(translations) - len(unknown)} set in {path.name}")
    for key in unknown:
        print(f"  ? not in catalog: {key}")


def specifiers(text):
    """Format specifiers as a sorted list of types, positional or not ("%1$@" → "@")."""
    return sorted(re.findall(r"%(?:\d+\$)?(lld|ld|d|@|f)", text))


def check():
    missing_any = False
    for path in CATALOGS:
        strings = load(path)["strings"]
        live = {k: v for k, v in strings.items() if v.get("extractionState") != "stale"}
        for language in LANGUAGES:
            missing = [k for k, v in live.items() if language not in v.get("localizations", {})]
            for key, entry in live.items():
                unit = entry.get("localizations", {}).get(language, {})
                value = unit.get("stringUnit", {}).get("value")
                if value is None and "variations" in unit:
                    value = unit["variations"]["plural"]["other"]["stringUnit"]["value"]
                if value is not None and path != INFOPLIST_CATALOG and specifiers(value) != specifiers(key):
                    missing_any = True
                    print(f"{path.name} {language}: format specifiers differ: {key!r} → {value!r}")
            if missing:
                missing_any = True
                print(f"{path.name} {language}: {len(missing)} missing")
                for key in missing[:10]:
                    print(f"  - {key}")
    if not missing_any:
        print("all keys translated in every language")
    return 1 if missing_any else 0


def compile_into(directory):
    for path in CATALOGS:
        if path.exists():
            # No code looks a stale key up, so it has no place in the built bundle.
            catalog = load(path)
            catalog["strings"] = {k: v for k, v in catalog["strings"].items() if v.get("extractionState") != "stale"}
            live = STRINGS_DIR / "live" / path.name
            live.parent.mkdir(parents=True, exist_ok=True)
            live.write_text(json.dumps(catalog, ensure_ascii=False))
            subprocess.run(["xcrun", "xcstringstool", "compile", str(live), "--output-directory", directory], check=True)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "extract":
        extract()
    elif command == "import":
        import_translations(sys.argv[2], sys.argv[3])
    elif command == "check":
        sys.exit(check())
    elif command == "compile":
        compile_into(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
