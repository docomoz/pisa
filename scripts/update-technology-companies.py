#!/usr/bin/env python3
"""Refresh the bundled CC0 company names; the application never needs network access."""
import argparse
import concurrent.futures
import datetime
import json
import pathlib
import re
import urllib.parse
import urllib.request
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
QUERIES = {
    "technology": "?company wdt:P31/wdt:P279* wd:Q18388277 .",
    "software": "?company wdt:P31/wdt:P279* wd:Q1058914 .",
    "industry": "VALUES ?industry { wd:Q56611700 wd:Q880371 wd:Q75 wd:Q17078324 wd:Q11660 wd:Q11661 wd:Q7397 } ?company wdt:P452 ?industry . FILTER NOT EXISTS { ?company wdt:P31 wd:Q5 }",
    "infrastructure": "VALUES ?industry { wd:Q638608 wd:Q1540863 wd:Q5358497 wd:Q914359 wd:Q2986369 wd:Q189900 wd:Q193424 wd:Q484847 wd:Q5892272 } ?company wdt:P452 ?industry . FILTER NOT EXISTS { ?company wdt:P31 wd:Q5 }",
}
GENERIC = set("apple orange nothing true false next now first second monday tuesday wednesday thursday friday saturday sunday january february march april may june july august september october november december meta notion linear block square box bolt wise zoom amplitude miro matrix pattern language together character frontier strategy frontier frontier systems technology technologies software company international world global group network networks digital data cloud ai it go rust swift kotlin java python one two three yes no мир контур точка астра система системы технологии цифра сеть облако группа компания".split())


def sparql(query):
    url = "https://query.wikidata.org/sparql?" + urllib.parse.urlencode({"query": query, "format": "json"})
    request = urllib.request.Request(url, headers={
        "User-Agent": "PisaVocabulary/1.0 (https://github.com/docomoz/pisa)",
        "Accept": "application/sparql-results+json",
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["results"]["bindings"]


def cached_rows(path, from_cache, fetch):
    if from_cache:
        return json.loads(path.read_text())["results"]["bindings"]
    rows = fetch()
    path.write_text(json.dumps({"results": {"bindings": rows}}, ensure_ascii=False))
    return rows


def entity_id(row, field):
    value = row[field]["value"].rsplit("/", 1)[-1]
    return value if re.fullmatch(r"Q\d+", value) else None


def select_organization_instances(ids):
    # Bind the candidates before querying P31. A join across the whole Wikidata
    # organization hierarchy and every industry record times out on WDQS.
    batch_size = 400
    batches = [ids[start:start + batch_size] for start in range(0, len(ids), batch_size)]

    def instance_types(batch):
        values = " ".join("wd:" + qid for qid in batch)
        query = ("SELECT DISTINCT ?company ?type WHERE { VALUES ?company { " + values
                 + " } ?company wdt:P31 ?type . FILTER NOT EXISTS { ?company wdt:P279 [] } }")
        return sparql(query)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        return [row for batch in pool.map(instance_types, batches) for row in batch]


def spelling(value):
    value = re.sub(r"\s+", " ", value).strip()
    value = re.sub(r",?\s+(?:Inc\.?|LLC|Ltd\.?|Corp\.?|Corporation|Limited|GmbH|PLC)$", "", value, flags=re.I)
    # Labels are data, never decoder instructions or glossary separators.
    if not (3 <= len(value) <= 64) or not re.fullmatch(r"[\w\s.&+'’/()‐‑-]+", value, re.UNICODE):
        return None
    if any(c in value for c in "_/()") or not any(c.isalpha() for c in value):
        return None
    if not re.fullmatch(r"[A-Za-zА-Яа-яЁё0-9\s.&+'’‐‑-]+", value):
        return None
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-directory", type=pathlib.Path, required=True)
    parser.add_argument("--from-cache", action="store_true")
    parser.add_argument("--snapshot-date", default=datetime.date.today().isoformat())
    args = parser.parse_args()
    args.cache_directory.mkdir(parents=True, exist_ok=True)
    entities = {}
    typed = set()
    for name, pattern in QUERIES.items():
        query = ('SELECT DISTINCT ?company ?en ?ru WHERE { ' + pattern
                 + ' OPTIONAL { ?company rdfs:label ?en FILTER(LANG(?en)="en") }'
                 + ' OPTIONAL { ?company rdfs:label ?ru FILTER(LANG(?ru)="ru") } }')
        rows = cached_rows(args.cache_directory / (name + ".json"), args.from_cache, lambda: sparql(query))
        for binding in rows:
            qid = entity_id(binding, "company")
            if not qid:
                continue
            if name in ("technology", "software"):
                typed.add(qid)
            item = entities.setdefault(qid, {})
            for language in ("en", "ru"):
                if language in binding:
                    item[language] = binding[language]["value"]
    organization_query = "SELECT DISTINCT ?type WHERE { wd:Q43229 (^wdt:P279)* ?type . }"
    organization_rows = cached_rows(args.cache_directory / "organization-types.json", args.from_cache,
                                    lambda: sparql(organization_query))
    organization_types = {entity_id(row, "type") for row in organization_rows}
    if "Q43229" not in organization_types:
        raise SystemExit("The Wikidata organization hierarchy is missing or incomplete")
    candidates = sorted(entities.keys() - typed)
    candidate_rows = cached_rows(args.cache_directory / "industry-entity-types.json", args.from_cache,
                                 lambda: select_organization_instances(candidates))
    typed.update(entity_id(row, "company") for row in candidate_rows if entity_id(row, "type") in organization_types)

    def word_forms(name):
        path = ROOT / "Sources/PisaCore/Resources" / (name + ".deflate")
        return set(zlib.decompress(path.read_bytes(), -15).decode().splitlines())

    english = pathlib.Path("/usr/share/dict/words")
    if not english.exists():
        raise SystemExit("Refreshing the catalog requires /usr/share/dict/words to flag ambiguous English names")
    common_words = GENERIC | word_forms("PisaCommonForms") | set(english.read_text().lower().splitlines())
    ambiguous_words = common_words | word_forms("PisaEntityForms")
    entries = []
    for qid, labels in sorted(entities.items()):
        if qid not in typed:
            continue
        names = list(dict.fromkeys(filter(None, (spelling(labels.get(k, "")) for k in ("en", "ru")))))
        if not names:
            continue
        aliases = []
        for name in names:
            key = name.lower().replace("ё", "е")
            tokens = re.findall(r"[\w]+", key)
            single_word = len(tokens) == 1 and (key in ambiguous_words or len(key) <= 3)
            common_phrase = (len(tokens) > 1 and " " in key and name[1:].islower()
                             and all(token in common_words for token in tokens))
            aliases.append({"text": name, "contextRequired": single_word or common_phrase})
        entries.append({"id": qid, "term": names[0], "aliases": aliases})
    payload = {"schemaVersion": 1, "snapshotDate": args.snapshot_date, "license": "CC0-1.0", "entries": entries}
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    target = ROOT / "Sources/PisaCore/Resources/PisaTechnologyCompanies.deflate"
    compressor = zlib.compressobj(level=9, wbits=-15)
    target.write_bytes(compressor.compress(data) + compressor.flush())
    print(f"Saved {len(entries)} companies / {sum(len(e['aliases']) for e in entries)} spellings ({target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
