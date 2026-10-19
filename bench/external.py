"""Converts public evaluation sets to the corpus format, so the same scorer
checks models outside our own synthetic shapes. Labels we do not mask
(cities, dates, occupations, ...) become `ignore` spans: neither leaks nor
over-masking.

    uv run python external.py nemotron    # data/nemotron.jsonl (English)
    uv run python external.py plbench     # data/plbench.jsonl (Polish)
"""

import json
import random
import sys
from pathlib import Path

DATA = Path(__file__).parent / "data"
HUB = Path.home() / ".cache/huggingface/hub"

NEMOTRON = {
    "first_name": "PERSON", "last_name": "PERSON", "company_name": "ORG", "email": "EMAIL",
    "phone_number": "PHONE", "fax_number": "PHONE", "street_address": "ADDRESS", "postcode": "ADDRESS",
    "date_of_birth": "DOB", "ssn": "ID", "tax_id": "ID", "certificate_license_number": "ID",
    "medical_record_number": "ID", "health_plan_beneficiary_number": "ID", "account_number": "IBAN",
    "bank_routing_number": "IBAN", "swift_bic": "IBAN", "credit_debit_card": "ID", "cvv": "ID",
    "password": "SECRET", "api_key": "SECRET", "http_cookie": "SECRET", "pin": "SECRET",
    "ipv4": "IP", "ipv6": "IP", "user_name": "ID", "license_plate": "ID", "vehicle_identifier": "ID",
    "biometric_identifier": "ID",
}

PLBENCH = {
    "PERSON": "PERSON", "ORG": "ORG", "PESEL": "ID", "NIP": "ID", "REGON": "ID", "DOWOD": "ID", "IBAN": "IBAN",
    "POSTAL": "ADDRESS", "LOC": "ADDRESS", "DOB": "DOB", "PHONE": "PHONE", "EMAIL": "EMAIL", "PASSPORT": "ID",
    "DRIVING_LICENSE": "ID", "PAYMENT_CARD": "ID", "VIN": "ID", "VEHICLE_PLATE": "ID",
}


def cell(id_, lang, shape, text, spans, mapping):
    if isinstance(spans, str):
        import ast

        spans = ast.literal_eval(spans)
    gold, ignore = [], []
    for s in spans:
        kind = mapping.get(s["label"])
        (gold if kind else ignore).append({"start": s["start"], "end": s["end"], "type": kind or s["label"]})
    return {"id": id_, "lang": lang, "shape": shape, "text": text, "spans": gold, "keep": [], "ignore": ignore}


def nemotron(n=300):
    import pyarrow.parquet as pq

    path = next(HUB.glob("datasets--nvidia--Nemotron-PII/snapshots/*/data/test-*.parquet"))
    rows = [r for r in pq.read_table(path).to_pylist() if len(r["text"]) <= 1500]
    random.Random(7).shuffle(rows)
    return [cell(f"nemotron-{r['uid']}", "en", f"nemotron-{r['document_format']}", r["text"], r["spans"], NEMOTRON)
            for r in rows[:n]]


def plbench(robustness=30):
    root = next(HUB.glob("datasets--pl-pii-bench--pl-pii-bench/snapshots/*")) / "data"
    docs = []
    for split in ["core", "address", "identifiers", "negative", "pdf", "robustness"]:
        files = sorted((root / split).glob("*.json"))
        if split == "robustness":
            random.Random(7).shuffle(files)
            files = files[:robustness]
        docs += [(split, f.stem, json.load(f.open())) for f in files]
    for i, line in enumerate((root / "inflection").glob("*.jsonl").__next__().open()):
        e = json.loads(line)
        docs.append(("inflection", f"{i:04d}", {"text": e["text"], "entities": [e]}))
    out = []
    for split, name, d in docs:
        entities = d.get("entities", [])
        protect = [e for e in entities if e.get("protection", "protect") == "protect"]
        c = cell(f"plbench-{split}-{name}", "pl", f"plbench-{split}", d["text"], protect, PLBENCH)
        c["keep"] = [{"start": e["start"], "end": e["end"]} for e in entities if e.get("protection") == "keep"]
        out.append(c)
    return out


def main():
    which = sys.argv[1]
    rows = {"nemotron": nemotron, "plbench": plbench}[which]()
    with (DATA / f"{which}.jsonl").open("w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"{len(rows)} cells, {sum(len(r['spans']) for r in rows)} gold spans")


if __name__ == "__main__":
    main()
