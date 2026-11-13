#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
app_binary="${1:-$root/build/Build/Products/Release/Pisa.app/Contents/MacOS/Pisa}"
fixture_dir="$(mktemp -d -t pisa-vocabulary)"
trap 'rm -rf "$fixture_dir"' EXIT

# Synthetic speech only; no recordings from the user's library are needed.
say -v 'Milena (Russian (Russia))' -r 150 -o "$fixture_dir/speech.aiff" \
  'На следующей встрече обсудим бронегис и геопэй. Проверим бронегис в четверг.'
afconvert -f WAVE -d LEI16@16000 -c 1 "$fixture_dir/speech.aiff" "$fixture_dir/speech.wav"
python3 - "$fixture_dir" <<'PY'
import array
import json
import pathlib
import sys
import wave

root = pathlib.Path(sys.argv[1])
with wave.open(str(root / 'speech.wav'), 'rb') as audio:
    assert audio.getnchannels() == 1 and audio.getframerate() == 16000
    assert audio.getsampwidth() == 2
    samples = array.array('h', audio.readframes(audio.getnframes()))
    if sys.byteorder != 'little':
        samples.byteswap()
with (root / 'fixture.json').open('w') as output:
    json.dump({'speech': [0.0] * 8000 + [sample / 32768 for sample in samples] + [0.0] * 8000}, output)
PY
"$app_binary" --vocabulary-test < "$fixture_dir/fixture.json"
