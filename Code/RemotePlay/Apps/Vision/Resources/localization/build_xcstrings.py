#!/usr/bin/env python3
"""Build Localizable.xcstrings from the frozen English keys + locale table."""
from __future__ import annotations

import json
from pathlib import Path

LOCALES = ["es", "fr", "it", "pt-BR", "de", "ko", "zh-Hans", "zh-Hant", "ja"]
REVIEW = {"zh-Hant", "ja"}
HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "Localizable.xcstrings"

# en -> {locale: translation}
# Product names from LOCALIZATION_GLOSSARY.md stay in English inside the sentence.
T: dict[str, dict[str, str]] = {}


def add(en: str, **locs: str) -> None:
    T[en] = locs


def state_for(locale: str, en: str) -> str:
    if locale in REVIEW and len(en.split()) >= 8:
        return "needs_review"
    return "translated"


def main() -> None:
    strings = {}
    for en, locs in T.items():
        entry: dict = {
            "extractionState": "manual",
            "localizations": {},
        }
        for loc in LOCALES:
            value = locs.get(loc)
            if not value:
                continue
            entry["localizations"][loc] = {
                "stringUnit": {"state": state_for(loc, en), "value": value}
            }
        strings[en] = entry
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.1"}
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {OUT} keys={len(strings)}")


from strings_table import rows

T.update(rows())

if __name__ == "__main__":
    main()
