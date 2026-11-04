from pathlib import Path

root = Path(__file__).resolve().parents[2]
reader = (root / "App/Readers/EPUBSurface.swift").read_text()
fixture = (Path(__file__).parent / "Fixture.swift").read_text()
start = "@MainActor final class ReaderCurlCatchUpPan:"
end = "\n}"

def recognizer(source):
    first = source.index(start)
    return source[first:source.index(end, first) + len(end)]

if recognizer(reader) != recognizer(fixture):
    raise SystemExit("Curl fixture recognizer differs from production")
print("Curl fixture uses the exact production recognizer")
