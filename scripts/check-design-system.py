#!/usr/bin/env python3
"""Reject screen-local font construction and spacing outside the shared scale."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
paths = [Path(value) for value in sys.argv[1:]] or sorted((root / 'Sources/Pisya').glob('*.swift'))
failures = []
for path in paths:
    # Definitions live here. Tests and diagnostics contain no product screens.
    if path.name in {'AppTypography.swift', 'Appearance.swift'} or path.stem.endswith(('Tests', 'Diagnostics')):
        continue
    source = path.read_text()
    # Preserve newlines for diagnostics while ignoring strings and comments.
    source = re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                    lambda match: '\n' * match[0].count('\n'), source)
    rules = [
        (r'\b(?:NSFont|Font)\s*(?:\(|\.\w+\s*\()|\.appFont\s*\(', 'Use PisyaDesign.Typography'),
        (r'\.font\(\s*\.', 'Use a named typography role'),
        (r'\.(?:padding|lineSpacing)\((?![^)]*PisyaDesign\.Spacing)[^)]*\)', 'Use PisyaDesign.Spacing'),
        (r'\bspacing:\s*(?!PisyaDesign\b|subtitle\b)[0-9.-]+', 'Use PisyaDesign.Spacing'),
        (r'\.tracking\((?!PisyaDesign\.Typography)[^)]*\)', 'Use a typography tracking token'),
        (r'SectionHeading\([^\n]*\bsize:', 'Choose a SectionHeading.Style'),
    ]
    for pattern, message in rules:
        for match in re.finditer(pattern, source):
            line = source.count('\n', 0, match.start()) + 1
            failures.append(f'{path}:{line}: error: {message}')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('Design system check passed: shared typography and spacing')
