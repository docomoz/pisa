#!/usr/bin/env python3
"""Run speaker extraction on an explicitly supplied private corpus; no library writes.

Manifest schema follows VoiceQualityProbe.Manifest. `references` identify voice
picker segments; only their first eight seconds are presumed user-confirmed.
`unconfirmed` entries are diagnostic and never count as ground truth. Profiles
are read from <root>/<profiles>, audio examples from <root>/VoiceSamples.
Use --source-ref to build the exact same probe against older production code.
No corpus, names, recordings, or results should be committed to the repository.
"""
import argparse
import json
import hashlib
import math
import os
from pathlib import Path
import subprocess
import tempfile


def cosine(a, b):
    if not a or not b or len(a) != len(b):
        return -1
    norm = math.sqrt(sum(x*x for x in a) * sum(x*x for x in b))
    return sum(x*y for x, y in zip(a, b)) / norm if norm else -1


def summarize(result):
    rows = []
    for turn in result['turns']:
        ref = turn['reference']
        ranking = {}
        for profile in result['profiles']:
            # Cross-meeting recognition must not score its own enrollment clip.
            if profile['meetingID'].upper() == ref['meetingID'].upper():
                continue
            score = cosine(turn.get('preview'), profile.get('extracted'))
            ranking[profile['name']] = max(ranking.get(profile['name'], -1), score)
        best = sorted(ranking.items(), key=lambda x: x[1], reverse=True)
        accepted = turn.get('extractedMatch')
        rows.append(dict(segmentID=ref['segmentID'], confidence=ref['confidence'], expected=ref['expected'],
                         accepted=accepted, rankings=best, regions=[dict(start=r['start'], end=r['end'], speaker=r['speaker'], identified=r.get('identified')) for r in turn['regions']]))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--evidence', type=Path, help='Re-run production matcher on a prior extraction without audio inference')
    parser.add_argument('--models', type=Path)
    parser.add_argument('--purity', action='store_true', help='Assess the corpus purity-files.json with production enrollment/migration code')
    parser.add_argument('--replay', action='store_true', help='Replay full-meeting clustering at candidate thresholds on --evidence')
    parser.add_argument('--runtime', type=Path, required=True, help='Folder with Sherpa/ONNX dylibs')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-ref', help='Git revision of production sources for before/after comparison')
    args = parser.parse_args()
    if not args.evidence and (not args.manifest or not args.models):
        parser.error('--manifest and --models are required for extraction')
    repo = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='pisya-voice-probe-') as temp:
        scratch = Path(temp)
        sources = sorted((repo / 'Sources/PisyaCore').glob('*.swift'))
        sources += [repo / 'Sources/Pisya/SpeakerEngine.swift']
        if args.purity:
            sources += [repo / 'Sources/Pisya/SavedVoiceAudio.swift', repo / 'Sources/Pisya/PCMRead.swift']
        if args.source_ref:
            baseline = []
            for path in sources:
                content = subprocess.run(['git', 'show', f'{args.source_ref}:{path.relative_to(repo)}'], cwd=repo, capture_output=True)
                if content.returncode:
                    # New helpers did not exist in the baseline tree.
                    continue
                dest = scratch / path.name
                dest.write_bytes(content.stdout)
                baseline.append(dest)
            sources = baseline
        if not args.source_ref:
            frozen = []
            for path in sources:
                dest = scratch / path.name
                dest.write_bytes(path.read_bytes())
                frozen.append(dest)
            sources = frozen
        executable = scratch / 'probe'
        env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
        probe = scratch / 'VoiceQualityProbe.swift'
        probe_source = 'SavedVoiceQualityProbe.swift' if args.purity else 'VoiceQualityProbe.swift'
        probe.write_bytes((repo/'Tests/Native'/probe_source).read_bytes())
        fingerprints = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [probe]}
        args.output.with_suffix('.sources.json').write_text(json.dumps(dict(source_ref=args.source_ref, files=fingerprints), indent=2))
        command = ['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-parse-as-library', '-import-objc-header', str(repo/'Vendor/Sherpa/include/c-api.h'),
                   '-L', str(args.runtime.resolve()), '-lsherpa-onnx-c-api', '-Xlinker', '-rpath', '-Xlinker', str(args.runtime.resolve())]
        if args.source_ref:
            command += ['-DVOICE_QUALITY_LEGACY']
        subprocess.run(command + [str(p) for p in sources] + [str(probe), '-o', str(executable)], check=True, env=env)
        inputs = ['--replay' if args.replay else '--match', str(args.evidence.resolve())] if args.evidence else [str(args.manifest.resolve()), str(args.models.resolve())]
        if args.purity:
            inputs = [str(args.manifest.resolve().parent), str(args.models.resolve() / 'titanet.onnx')]
        subprocess.run([str(executable)] + inputs + [str(args.output.resolve())], check=True)
    if args.purity:
        print('Wrote production purity results in corpus folder')
        return
    if args.evidence:
        print(f'Wrote production matching diagnostics: {args.output}')
        return
    result = json.loads(args.output.read_text())
    summary = args.output.with_suffix('.summary.json')
    summary.write_text(json.dumps(summarize(result), ensure_ascii=False, indent=2))
    print(f'Wrote extraction and cross-meeting diagnostics: {args.output}, {summary}')


if __name__ == '__main__':
    main()
