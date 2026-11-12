#!/usr/bin/env python3
"""Build Pisya word-form lists from a pinned OpenCorpora snapshot."""

import argparse
from collections import defaultdict
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZipFile
import zlib


DICTIONARY_URL = "https://files.pythonhosted.org/packages/b0/67/469e9e52d046863f5959928794d3067d455a77f580bf4a662630a43eb426/pymorphy3_dicts_ru-2.4.417150.4580142-py2.py3-none-any.whl"
DICTIONARY_SHA256 = "718bac64c73c10c16073a199402657283d9b64c04188b694f6d3e9b0d85440f4"
READER_URL = "https://files.pythonhosted.org/packages/6a/84/ff1ce2071d4c650ec85745766c0047ccc3b5036f1d03559fd46bb38b5eeb/DAWG_Python-0.7.2-py2.py3-none-any.whl"
READER_SHA256 = "4941d5df081b8d6fcb4597e073a9f60d5c1ccc9d17cd733e8744d7ecfec94ef3"
DATA_PATH = "pymorphy3_dicts_ru/data/"
EXCLUDED_TAGS = {"Name", "Surn", "Patr", "Geox", "Orgn", "Trad", "Abbr", "Erro", "Dist"}
# OpenCorpora lacks an ordinary е spelling for these held-out keys. «мед.»
# can abbreviate «медицинский», so the bare token alone cannot select «мёд».
HELD_OUT = {"берем", "мед"}


def download(url, expected_sha256):
    with urlopen(url, timeout=30) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != expected_sha256:
        raise ValueError(f"Unexpected SHA-256: {url}")
    return content


def load_paradigms(content):
    with io.BytesIO(content) as stream:
        count, = struct.unpack("<H", stream.read(2))
        paradigms = []
        for _ in range(count):
            length, = struct.unpack("<H", stream.read(2))
            paradigms.append(struct.unpack(f"<{length}H", stream.read(length * 2)))
    return paradigms


def select_forms(words, paradigms, tags):
    spellings = defaultdict(set)
    eligible = set()
    allowed_tags = [not EXCLUDED_TAGS.intersection(re.split(r"[, ]+", tag)) for tag in tags]
    for word, (paradigm_id, index) in words.iteritems():
        if "ё" not in word:
            continue
        spellings[word.replace("ё", "е")].add(word)
        paradigm = paradigms[paradigm_id]
        if allowed_tags[paradigm[len(paradigm) // 3 + index]]:
            eligible.add(word)

    result = []
    for folded, variants in spellings.items():
        if len(variants) != 1 or folded in HELD_OUT or words.get(folded):
            continue
        word, = variants
        if word in eligible and re.fullmatch(r"[а-яё]+", word):
            result.append(word)
    return sorted(result)


def select_entity_forms(words, paradigms, tags):
    personal = {"Name", "Surn", "Patr"}
    commercial = {"Orgn", "Trad"}
    tag_sets = [set(re.split(r"[, ]+", tag)) for tag in tags]
    entity = ["Geox" in tag or ("sing" in tag and bool(personal & tag)) for tag in tag_sets]
    brand = [bool(commercial & tag) for tag in tag_sets]
    forms, competing = set(), set()
    russian_word = re.compile(r"[а-яё]+(?:-[а-яё]+)*")
    for word, (paradigm_id, index) in words.iteritems():
        if len(word) < 3 or not russian_word.fullmatch(word):
            continue
        paradigm = paradigms[paradigm_id]
        tag = paradigm[len(paradigm) // 3 + index]
        if entity[tag]:
            forms.add(word.replace("ё", "е"))
        if brand[tag]:
            competing.add(word.replace("ё", "е"))
    return sorted(forms - competing)


def write_forms(forms, output):
    # Foundation NSData.decompressed(using: .zlib) reads raw DEFLATE.
    compressor = zlib.compressobj(level=9, wbits=-15)
    compressed = compressor.compress(("\n".join(forms) + "\n").encode("utf-8")) + compressor.flush()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(compressed)
    print(f"{output.name}: {len(forms)} forms, {len(compressed)} bytes, SHA-256 {hashlib.sha256(compressed).hexdigest()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_output = Path(__file__).resolve().parents[1] / "Sources/PisyaCore/Resources/PisyaYoWords.deflate"
    parser.add_argument("--output", type=Path, default=default_output)
    parser.add_argument("--entity-output", type=Path, help="also write the list of names and places")
    args = parser.parse_args()

    with TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        reader = temporary / "dawg_python.whl"
        reader.write_bytes(download(READER_URL, READER_SHA256))
        sys.path.insert(0, str(reader))
        from dawg_python import RecordDAWG

        with ZipFile(io.BytesIO(download(DICTIONARY_URL, DICTIONARY_SHA256))) as archive:
            path = temporary / "words.dawg"
            path.write_bytes(archive.read(DATA_PATH + "words.dawg"))
            words = RecordDAWG(">HH").load(str(path))
            paradigms = load_paradigms(archive.read(DATA_PATH + "paradigms.array"))
            tags = json.loads(archive.read(DATA_PATH + "gramtab-opencorpora-int.json"))
        write_forms(select_forms(words, paradigms, tags), args.output)
        if args.entity_output:
            write_forms(select_entity_forms(words, paradigms, tags), args.entity_output)


if __name__ == "__main__":
    main()
