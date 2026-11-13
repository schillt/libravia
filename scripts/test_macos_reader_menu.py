#!/usr/bin/env python3
"""Run the production Mac menu class against synthetic selection transactions.

Usage: python3 scripts/test_macos_reader_menu.py
Requires macOS, Swift, AppKit and WebKit. Does not read books or accounts.
"""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

if sys.platform != "darwin":
    raise SystemExit("This native menu probe requires macOS")

root = Path(__file__).resolve().parents[1]
reader = (root / "App/Readers/EPUBSurface.swift").read_text()
start = reader.index("@MainActor final class ReaderMenuWebView: WKWebView {")
end = reader.index("\n#endif\n#if os(iOS)", start)
production = reader[start:end]
selection = next(line for line in (root / "App/Readers/ReaderView.swift").read_text().splitlines()
                 if line.startswith("struct EPUBSelection:"))
models = (root / "App/Core/Models.swift").read_text()
start_dictionary = models.index("enum ReaderDictionary {")
dictionary = models[start_dictionary:models.index("\n}", start_dictionary) + 2]
fixture = (Path(__file__).with_name("macos_reader_menu_fixture.swift")).read_text()
for marker, source in [("// PRODUCTION_CLASS", production),
                       ("// PRODUCTION_SELECTION", selection),
                       ("// PRODUCTION_DICTIONARY", dictionary)]:
    assert fixture.count(marker) == 1
    fixture = fixture.replace(marker, source)
with tempfile.TemporaryDirectory(prefix="libravia-native-menu-") as directory:
    directory = Path(directory)
    source = directory / "probe.swift"
    executable = directory / "probe"
    source.write_text(fixture)
    subprocess.run(["swiftc", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
print("Production ReaderMenuWebView SHA-256:", hashlib.sha256(production.encode()).hexdigest())
