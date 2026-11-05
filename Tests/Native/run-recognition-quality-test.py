#!/usr/bin/env python3
"""Compare local ASR outputs against fixed references; never reads the meeting library.

The default corpus uses macOS speech synthesis. --corpus accepts a JSON list of
{name, reference, samples: [16 kHz mono floats], context?, track?} for a separately
licensed or user-supplied corpus. WER ignores punctuation, case and ё/е only.
"""
import argparse
import array
import json
import pathlib
import random
import re
import subprocess
import sys
import tempfile
import wave


def words(text):
    return re.findall(r"[^\W_]+", text.lower().replace("ё", "е"))


def distance(reference, actual):
    previous = list(range(len(actual) + 1))
    for i, word in enumerate(reference, 1):
        current = [i]
        for j, candidate in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (word != candidate)))
        previous = current
    return previous[-1]


def synthetic_corpus(root):
    phrases = [
        ("short-yes", "Да.", 170, ""),
        ("short-no", "Нет, не надо.", 170, ""),
        ("repetitions", "Да, да, да, всё верно. Мы проверили поиск, проверили карточки, проверили маршруты. Нет, нет, переносить встречу не надо.", 185, ""),
        ("vocabulary", "На следующей встрече обсудим бронегис и геопэй. Проверим бронегис в четверг.", 150, "Бронегис, Геопэй"),
        ("fast-speech", "Коллеги, давайте сначала договоримся о критериях качества. Если пользователь не находит нужную организацию, он просто уходит в другое приложение. Поэтому мы проверяем не только скорость ответа, но и полноту результатов, правильность адресов и актуальность времени работы.", 220, ""),
        ("long-turn", "Я предлагаю сначала проверить результаты эксперимента и только после этого принимать решение о запуске. Нам важно понять, почему пользователи закрывают карточку организации и возвращаются к поиску. Возможно, им не хватает фотографий, а возможно, они просто не видят нужную кнопку. Давайте отдельно посмотрим новые города, сравним мобильное приложение с сайтом и обсудим выводы на следующей встрече. Если данных окажется недостаточно, продлим эксперимент ещё на неделю.", 180, ""),
    ]
    fixtures = []
    for name, reference, rate, context in phrases:
        aiff, wav = root / (name + ".aiff"), root / (name + ".wav")
        subprocess.run(["say", "-v", "Milena (Russian (Russia))", "-r", str(rate), "-o", str(aiff), reference], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
        with wave.open(str(wav), "rb") as audio:
            assert audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2
            pcm = array.array("h", audio.readframes(audio.getnframes()))
        if sys.byteorder != "little":
            pcm.byteswap()
        samples = [0.] * 4000 + [value / 32768 for value in pcm] + [0.] * 4000
        fixtures.append(dict(name=name, reference=reference, samples=samples, context=context,
                             maximum_errors=1 if name == "long-turn" else 0))
    generator = random.Random(741)
    fixtures += [dict(name="silence", reference="", samples=[0.] * 48000, context="Бронегис, Геопэй", maximum_errors=0),
                 dict(name="noise", reference="", samples=[generator.uniform(-.03, .03) for _ in range(48000)],
                      context="Бронегис, Геопэй", maximum_errors=0)]
    return fixtures + [dict(fixture, name=fixture["name"] + "-remote", track="remote") for fixture in fixtures]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=pathlib.Path("build/Build/Products/Release/Pisya.app/Contents/MacOS/Pisya"))
    parser.add_argument("--corpus", type=pathlib.Path)
    parser.add_argument("--save-corpus", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--modes", nargs="+", default=["pipeline"])
    parser.add_argument("--maximum-wer", type=float, help="Fail when corpus WER exceeds this fraction")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pisya-recognition-") as directory:
        fixtures = json.loads(args.corpus.read_text()) if args.corpus else synthetic_corpus(pathlib.Path(directory))
        if args.save_corpus:
            args.save_corpus.write_text(json.dumps(fixtures, ensure_ascii=False))
        payload = dict(fixtures=[{k: v for k, v in fixture.items() if k != "reference"} for fixture in fixtures], modes=args.modes)
        # A file keeps long fixture input away from the command line and avoids pipe deadlocks.
        request = pathlib.Path(directory) / "request.json"
        request.write_text(json.dumps(payload, ensure_ascii=False))
        with request.open("rb") as source, args.output.open("w") as output:
            result = subprocess.run([str(args.app.resolve()), "--recognition-quality-test"], stdin=source, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print(args.output.read_text())
            raise SystemExit(result.returncode)
        references = {fixture["name"]: words(fixture["reference"]) for fixture in fixtures}
        limits = {fixture["name"]: fixture.get("maximum_errors") for fixture in fixtures}
        totals = {}
        seen = set()
        failed = False
        for line in args.output.read_text().splitlines():
            if not line.startswith("{"):
                continue
            row = json.loads(line)
            key = (row["name"], row["mode"])
            if key in seen:
                raise SystemExit("Duplicate benchmark result")
            seen.add(key)
            reference = references[row["name"]]
            errors = distance(reference, words(row["text"]))
            total = totals.setdefault(row["mode"], [0, 0, 0.])
            total[0] += errors; total[1] += len(reference); total[2] += row["seconds"]
            print(f'{row["name"]:20} {row["mode"]:22} {errors}/{len(reference)} {row["text"]}')
            limit = limits[row["name"]]
            if row["mode"] == "pipeline" and limit is not None and errors > limit:
                print(f'FAILED {row["name"]}: expected at most {limit} word errors')
                failed = True
        expected = {(fixture["name"], mode) for fixture in fixtures for mode in args.modes}
        if seen != expected:
            raise SystemExit("Missing benchmark results")
        for mode, (errors, count, seconds) in totals.items():
            wer = errors / max(1, count)
            print(f"TOTAL {mode}: WER={wer:.2%} ({errors}/{count}), inference={seconds:.1f}s")
            failed |= args.maximum_wer is not None and wer > args.maximum_wer
        if failed:
            raise SystemExit("Recognition word error threshold exceeded")


if __name__ == "__main__":
    main()
