#!/usr/bin/env python3
"""Bounded, sanitized performance reports for bundled CC0 fixtures; stdlib only."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]


def summary(values):
    if not values or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('samples must be finite nonnegative durations')
    ordered = sorted(values)
    return {'n': len(values), 'first_ms': values[0], 'median_ms': statistics.median(values),
            'p95_ms': ordered[max(0, math.ceil(.95 * len(ordered)) - 1)], 'max_ms': max(values)}


def command(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=10, choices=range(1, 101))
    parser.add_argument('--epub', action='store_true', help='Requires available native WebKit session; bounded to 45 seconds per fixture.')
    options = parser.parse_args()
    report = {'schema': 1, 'captured_at_utc': datetime.now(timezone.utc).isoformat(),
              'harness_sha256': {name: hashlib.sha256((ROOT / 'scripts/performance' / name).read_bytes()).hexdigest() for name in ('run.py', 'probe.swift')},
              'build_configuration': 'swiftc -O; bundled source renderer; no app build',
              'candidate': command(['/usr/bin/git', 'rev-parse', 'HEAD']),
              'working_tree_dirty': bool(command(['/usr/bin/git', 'status', '--porcelain'])),
              'environment': {'os': platform.mac_ver()[0], 'architecture': platform.machine(),
                              'hardware_model': command(['/usr/sbin/sysctl', '-n', 'hw.model']),
                              'xcode': command(['xcodebuild', '-version']).splitlines()},
              'cache_policy': 'First sample in fresh process; OS filesystem cache not purged. Subsequent samples warm. No cold-device claim.',
              'iterations': options.iterations, 'fixtures': [], 'unmeasured': ['physical input-to-visible-frame latency', 'app download/extraction/open journey', 'native card/curl animation smoothness', 'large-library UI scrolling', 'comic navigation and archive preparation', 'touch/pointer selection interaction']}
    with tempfile.TemporaryDirectory(prefix='libravia-performance-') as directory:
        temp = Path(directory)
        binary = temp / 'probe'
        subprocess.run(['swiftc', '-O', str(ROOT / 'scripts/performance/probe.swift'), '-o', str(binary)], check=True)
        with ZipFile(ROOT / 'Fixtures/Harbor.cbz') as archive:
            image = temp / 'comic.png'; image.write_bytes(archive.read('1.png'))
        large_pdf = temp / 'Harbor-long.pdf'
        subprocess.run([str(binary), 'pdf-fixture', str(ROOT / 'Fixtures/Harbor.pdf'), str(large_pdf), str(options.iterations)], check=True)
        jobs = [('Harbor.pdf', 'pdf', ROOT / 'Fixtures/Harbor.pdf', {'pages': 3, 'kind': 'text_pdf'}),
                ('Harbor-long.pdf', 'pdf', large_pdf, {'pages': 180, 'kind': 'repeated_original_text_pdf'}),
                ('Harbor.cbz', 'image', image, {'pages': 3, 'dimensions': [800, 1100], 'kind': 'decoded_first_comic_image'})]
        if options.epub:
            for label, multiplier in [('Harbor.epub', 1), ('Harbor-long.epub', 20)]:
                book = temp / label
                with ZipFile(ROOT / 'Fixtures/Harbor.epub') as archive:
                    archive.extractall(book)  # Only the repository-owned original fixture is accepted.
                if multiplier > 1:
                    for chapter in (book / 'OPS').glob('*.xhtml'):
                        text = chapter.read_text()
                        start, end = text.find('<p>'), text.rfind('</p>') + 4
                        if start >= 0: chapter.write_text(text[:start] + text[start:end] * multiplier + text[end:])
                jobs.append((label, 'epub', book, {'chapters': 2, 'paragraphs': 60 * multiplier, 'kind': 'reflowable_text', 'viewport': [375, 700], 'font_size': 20}))
        for name, mode, fixture, characteristics in jobs:
            source = ROOT / 'Fixtures' / ('Harbor.epub' if mode == 'epub' else 'Harbor.pdf' if name == 'Harbor-long.pdf' else name)
            entry = {'name': name, 'characteristics': characteristics, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
            args = [str(binary), mode] + ([str(ROOT / 'App/Resources/Reader'), str(fixture)] if mode == 'epub' else [str(fixture)]) + [str(options.iterations)]
            try:
                run = subprocess.run(args, capture_output=True, text=True, timeout=45)
                result = json.loads(run.stdout.strip().splitlines()[-1])
                if run.returncode == 0 and result.get('status') == 'measured':
                    entry.update(result)
                    samples = entry['samples']
                    if 'open_renderer_ready_ms' in entry: samples['open_renderer_ready_ms'] = entry.pop('open_renderer_ready_ms')
                    entry['summary'] = {metric: summary(values) for metric, values in samples.items()}
                    entry['warm_summary'] = {metric: summary(values[1:]) for metric, values in samples.items() if len(values) > 1}
                else: entry.update(status='unavailable', reason=result.get('reason', 'probe_failed'))
            except (subprocess.TimeoutExpired, ValueError, IndexError):
                entry.update(status='unavailable', reason='timeout_or_invalid_probe_output')
            report['fixtures'].append(entry)
        if not options.epub: report['unmeasured'].append('EPUB renderer: rerun with --epub in an available native session')
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'measured': sum(x['status'] == 'measured' for x in report['fixtures']), 'unavailable': sum(x['status'] != 'measured' for x in report['fixtures'])}))
    return 1 if any(x['status'] != 'measured' for x in report['fixtures']) else 0


if __name__ == '__main__':
    raise SystemExit(main())
