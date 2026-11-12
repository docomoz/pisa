#!/usr/bin/env python3
"""Keep font, leading and tracking together in the shared text styles."""
from pathlib import Path
import re
import sys

def compact_actions_in_form_rows(source):
    markers = re.compile(
        r'(?P<row>\bHStack\s*(?:\([^{}]*\))?\s*(?=\{))'
        r'|(?P<field>\.textFieldStyle\(\s*PisyaTextFieldStyle\b'
        r'|\bSearchField\s*\((?![^()]*\bcompact:\s*true))'
        r'|(?P<button>\.actionButton\([^()]*\bsize:\s*\.small\b)'
        r'|(?P<brace>[{}])'
    )
    scopes = []
    next_is_row = False
    for match in markers.finditer(source):
        if match.lastgroup == 'row':
            next_is_row = True
        elif match[0] == '{':
            scopes.append({'field': False, 'buttons': []} if next_is_row else None)
            next_is_row = False
        elif match[0] == '}':
            if scopes:
                row = scopes.pop()
                if row is not None and row['field']:
                    yield from row['buttons']
        elif scopes and scopes[-1] is not None:
            row = scopes[-1]
            if match.lastgroup == 'field':
                row['field'] = True
            else:
                row['buttons'].append(match)


root = Path(__file__).resolve().parents[1]
paths = [Path(value) for value in sys.argv[1:]] or sorted((root / 'Sources/Pisya').glob('*.swift'))
failures = []
for path in paths:
    # Definitions live here. Tests and diagnostics contain no product screens.
    if path.name == 'AppTypography.swift' or path.stem.endswith(('Tests', 'Diagnostics')):
        continue
    source = path.read_text()
    # Preserve newlines for diagnostics while ignoring strings and comments.
    source = re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                    lambda match: '\n' * match[0].count('\n'), source)
    rules = [
        (r'\b(?:NSFont|Font)\s*(?:\(|\.\w+\s*\()|\.appFont\s*\(', 'Use PisyaDesign.Typography'),
        (r'\.font\(\s*\.', 'Use a named typography role'),
        (r'\.padding\((?![^)]*PisyaDesign\.Spacing)[^)]*\)', 'Use PisyaDesign.Spacing'),
        (r'\bfont\((?!\s*PisyaDesign\.Typography\.Icon\.)[^)]*\)', 'Use textStyle so font and leading cannot diverge'),
        (r'\.(?:lineSpacing|tracking)\(', 'Leading and tracking belong to the shared text style'),
        (r'\bspacing:\s*(?!PisyaDesign\b|subtitle\b)[0-9.-]+', 'Use PisyaDesign.Spacing'),
        (r'SectionHeading\([^\n]*\bsize:', 'Choose a SectionHeading.Style'),
    ]
    if path.name != 'Appearance.swift':
        rules.append((r'\bPisyaDesign\.Typography\.smallButton\b', 'Let the action button choose its label size'))
    for match in compact_actions_in_form_rows(source):
        line = source.count('\n', 0, match.start()) + 1
        failures.append(f'{path}:{line}: error: Use a regular action button next to a form field')
    for pattern, message in rules:
        for match in re.finditer(pattern, source):
            line = source.count('\n', 0, match.start()) + 1
            failures.append(f'{path}:{line}: error: {message}')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('Design system check passed: shared typography and spacing')
