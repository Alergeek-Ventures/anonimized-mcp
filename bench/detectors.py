"""Adapters with one interface: `detect(text) -> [(start, end, label)]`.
Labels are the model's own; `MASKED` says which of them the gateway would
replace, the rest (amounts, invoice references, cities alone) stay visible
because diagnosis depends on them.
"""

import json
import os
import re
from pathlib import Path

import requests

HUB = Path.home() / ".cache/huggingface/hub"


def snapshot(repo):
    return str(next((HUB / f"models--{repo.replace('/', '--')}" / "snapshots").iterdir()))


# --- deterministic baseline (mirrors lib/anonimized_mcp/masking/detectors.ex) ---

EMAIL = re.compile(r"(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}(?![\w-])")
JWT = re.compile(r"\beyJ[\w-]+\.[\w-]+\.[\w-]+")
LONG_TOKEN = re.compile(r"(?<![\w$/.+=-])(?=[\w+=-]*\d)(?=[\w+=-]*[a-z])(?=[\w+=-]*[A-Z])[\w+=-]{24,}(?![\w$/.+=-])")
HASH = re.compile(r"\$(?:argon2(?:id|i|d)|2[aby])\$[^\s\"'}]+")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
IPV6 = re.compile(r"(?<![\w:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![\w:])")
IBAN = re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b|\b\d{2}(?: ?\d{4}){6}\b")
DIGITS = re.compile(r"(?<![\w-])\d{9,14}(?![\w-])")
PHONE = re.compile(r"(?<![\w])(?:\+\d{2} ?)?(?:\(?\d{3}\)?[ -]?\d{3}[ -]?\d{3,4})(?:x\d+)?(?![\w])")


def nip_ok(d):
    return len(d) == 10 and sum(int(a) * w for a, w in zip(d, [6, 5, 7, 2, 3, 4, 5, 6, 7])) % 11 == int(d[9])


def pesel_ok(d):
    return len(d) == 11 and (10 - sum(int(a) * w for a, w in zip(d, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3])) % 10) % 10 == int(d[10])


def regon_ok(d):
    return len(d) == 9 and sum(int(a) * w for a, w in zip(d, [8, 9, 2, 3, 4, 5, 6, 7])) % 11 % 10 == int(d[8])


def iban_ok(s):
    s = s.replace(" ", "")
    if s.isdigit() and len(s) == 26:
        s = "PL" + s
    if not re.fullmatch(r"[A-Z]{2}\d{2}[A-Z0-9]{10,30}", s):
        return False
    n = "".join(str(int(c, 36)) for c in s[4:] + s[:4])
    return int(n) % 97 == 1


class Regex:
    name = "regex"
    MASKED = None

    def detect(self, text):
        spans = []

        def add(m, label):
            if not any(m.start() < e and s < m.end() for s, e, _ in spans):
                spans.append((m.start(), m.end(), label))

        for m in EMAIL.finditer(text):
            add(m, "EMAIL")
        for m in JWT.finditer(text):
            add(m, "SECRET")
        for m in HASH.finditer(text):
            add(m, "SECRET")
        for m in IBAN.finditer(text):
            if iban_ok(m.group()):
                add(m, "IBAN")
        for m in DIGITS.finditer(text):
            d = m.group()
            if nip_ok(d) or pesel_ok(d) or regon_ok(d):
                add(m, "ID")
        for m in IPV4.finditer(text):
            if all(int(p) < 256 for p in m.group().split(".")):
                add(m, "IP")
        for m in IPV6.finditer(text):
            add(m, "IP")
        for m in PHONE.finditer(text):
            add(m, "PHONE")
        for m in LONG_TOKEN.finditer(text):
            if not UUID.fullmatch(m.group()):
                add(m, "SECRET")
        return spans


# --- bardsai/eu-pii-anonimization-multilang-v2 ---

class Bardsai:
    name = "bardsai"
    MASKED = {
        "PERSON_NAME", "PERSON_ALIAS", "PERSON_IDENTIFIER", "DATE_OF_BIRTH", "EMAIL_ADDRESS", "PHONE_NUMBER",
        "CONTACT_HANDLE", "POSTAL_ADDRESS", "GEO_LOCATION", "IP_ADDRESS", "DEVICE_IDENTIFIER", "IDENTIFYING_LINK",
        "ACCOUNT_IDENTIFIER", "AUTH_SECRET", "BANK_ACCOUNT_IDENTIFIER", "PAYMENT_CARD", "PAYMENT_CARD_SECURITY",
        "DOCUMENT_IDENTIFIER", "VEHICLE_IDENTIFIER", "ORGANIZATION_NAME", "ORGANIZATION_IDENTIFIER", "PROPER_NAME",
        "HEALTH_DATA", "BIOMETRIC_DATA", "ETHNIC_ORIGIN", "POLITICAL_OPINION", "RELIGION_OR_BELIEF",
        "SEXUAL_ORIENTATION", "TRADE_UNION_MEMBERSHIP", "CRIMINAL_OFFENCE_DATA",
    }

    def __init__(self, onnx=None):
        import sys

        path = snapshot("bardsai/eu-pii-anonimization-multilang-v2")
        sys.path.insert(0, path)
        from pii_detector import PIIDetector

        self.det = PIIDetector(path, onnx=onnx)
        if onnx:
            self.name = "bardsai-onnx-int8"

    def detect(self, text):
        return [(p["start"], p["end"], p["label"]) for p in self.det.predict(text)]


# --- piotrmaciejbednarski/gliner2-polish-pii ---

class Gliner2Polish:
    name = "gliner2-pl"
    LABELS = ["person", "organization", "date_of_birth", "email", "phone_number", "address", "street_address",
              "postal_code", "city", "pesel", "nip", "regon", "iban", "bank_account", "payment_card", "account_id",
              "ip_address", "username", "id_card_number"]
    MASKED = set(LABELS) - {"city"}

    def __init__(self, profile=None, threshold=0.3):
        import contextlib
        import io

        from gliner2 import GLiNER2

        path = snapshot("piotrmaciejbednarski/gliner2-polish-pii")
        with contextlib.redirect_stdout(io.StringIO()):
            self.model = GLiNER2.from_pretrained(path)
        taxonomy = json.load(open(f"{path}/taxonomy.json"))
        self.schema = {label: describe(taxonomy[label]) for label in self.LABELS}
        if profile:
            self.thresholds = json.load(open(f"{path}/thresholds-{profile}.json"))["thresholds"]
            self.name = f"gliner2-pl-{profile}"
        else:
            self.thresholds = {label: threshold for label in self.LABELS}
            self.name = f"gliner2-pl-t{threshold}"

    def detect(self, text):
        result = self.model.extract_entities(text, self.schema, threshold=0.05, include_confidence=True,
                                             include_spans=True)
        spans = []
        for label, found in result.get("entities", result).items():
            for f in found or []:
                if f["confidence"] >= self.thresholds.get(label, 0.5):
                    spans.append((f["start"], f["end"], label))
        return spans


def describe(entry):
    if isinstance(entry, str):
        return entry
    return entry.get("description") or entry.get("pl") or next(iter(entry.values()))


# --- Wismut/nym-pii-multilingual ---

class Nym:
    name = "nym"
    # Dates, ages and internal record ids are what debugging needs to see.
    MASKED = {
        "ACCOUNT_NUMBER", "API_KEY", "BUILDING_NUMBER", "COMPANY_NAME", "CREDIT_DEBIT_CARD", "CVV",
        "DATE_OF_BIRTH", "DRIVERS_LICENSE", "EMAIL", "FAX_NUMBER", "GIVEN_NAME", "GOVERNMENT_ID", "IBAN",
        "LICENSE_PLATE", "MAC_ADDRESS", "MEDICAL_RECORD_NUMBER", "PASSPORT", "PASSWORD", "PHONE", "PIN",
        "ROUTING_NUMBER", "SECONDARY_ADDRESS", "SSN", "STREET_ADDRESS", "STREET_NAME", "SURNAME", "SWIFT_BIC",
        "TAX_ID", "USERNAME", "ZIP_CODE",
    }

    def __init__(self):
        import torch
        from transformers import AutoModelForTokenClassification, AutoTokenizer

        path = snapshot("Wismut/nym-pii-multilingual")
        self.torch = torch
        self.tok = AutoTokenizer.from_pretrained(path)
        self.model = AutoModelForTokenClassification.from_pretrained(path).eval()
        self.id2label = self.model.config.id2label

    def detect(self, text):
        enc = self.tok(text, return_offsets_mapping=True, truncation=True, max_length=2048, return_tensors="pt")
        offsets = enc.pop("offset_mapping")[0].tolist()
        with self.torch.inference_mode():
            labels = self.model(**enc).logits[0].argmax(-1).tolist()
        spans = []
        for (s, e), li in zip(offsets, labels):
            if e <= s:
                continue
            while s < e and text[s].isspace():
                s += 1
            tag = self.id2label[li]
            if tag == "O":
                continue
            prefix, kind = tag.split("-", 1)
            if spans and spans[-1][2] == kind and (prefix == "I" or text[spans[-1][1]:s].strip() == ""):
                spans[-1] = (spans[-1][0], e, kind)
            else:
                spans.append((s, e, kind))
        return spans


# --- Bonsai 2 2B through llama-server ---

BONSAI_TYPES = ["PERSON", "ORG", "ADDRESS", "EMAIL", "PHONE", "ID", "IBAN", "SECRET", "IP", "DOB"]

BONSAI_PROMPT = """You find personal data in text taken from an application database (bank transfer titles, notes, error messages, logs, JSON). The text is Polish or English.

List every substring that is personal data, copied exactly as it appears (same case, same inflected form):
- PERSON: names of people, including first names alone, diminutives (Basia, Tomek), declined Polish forms (Jana Kowalskiego, z Anną Nowak) and names in capitals
- ORG: names of client or vendor companies (e.g. "Nowak i Wspólnicy S.A.", "Acme Logistics LLC")
- ADDRESS: street addresses, postal codes with city
- EMAIL, PHONE, IP
- ID: PESEL, NIP, REGON, SSN, EIN, tax or document numbers, card digits
- IBAN: bank account numbers
- SECRET: passwords, password hashes, API keys, access tokens, encryption keys
- DOB: dates of birth

Do NOT list: UUIDs, invoice or order numbers, error names, module or function names, status values, amounts, timestamps, HTTP codes, bank names, carriers, cities mentioned without an address, ordinary words.

Return JSON {"pii": [{"text": ..., "type": ...}]}; an empty list if there is none."""

BONSAI_SCHEMA = {
    "type": "object",
    "properties": {
        "pii": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "type": {"enum": BONSAI_TYPES}},
                "required": ["text", "type"],
            },
        }
    },
    "required": ["pii"],
}


# Examples use values that never occur in the corpus.
FEW_SHOT = [
    ("Rozmawiałem z Tadeuszem Pietrzakiem, obiecał zapłacić FV/7/09/2026 do piątku. Sprawę przejęła Hania z "
     "księgowości, tel. 601 222 333. Przelew od Haliny Gołębiowskiej, konto 61 1090 1014 0000 0712 1981 2874.",
     [("Tadeuszem Pietrzakiem", "PERSON"), ("Hania", "PERSON"), ("601 222 333", "PHONE"),
      ("Haliny Gołębiowskiej", "PERSON"), ("61 1090 1014 0000 0712 1981 2874", "IBAN")]),
    ('2026-09-01T10:00:00Z level=warn user_id=0b6f1c3e-2a4d-4b8e-9f00-1c2d3e4f5a6b email=ogrant@example.org '
     'remote_ip=203.0.113.7 authorization="Bearer sk_live_Ab12Cd34Ef56Gh78Ij90Kl12" msg="token refresh failed" '
     'name: "Oliver Grant", hashed_password: "$2b$12$Qm9vYmFyYmF6cXV4cXV1eA", company: "Grant & Hale Ltd"',
     [("ogrant@example.org", "EMAIL"), ("203.0.113.7", "IP"), ("sk_live_Ab12Cd34Ef56Gh78Ij90Kl12", "SECRET"),
      ("Oliver Grant", "PERSON"), ("$2b$12$Qm9vYmFyYmF6cXV4cXV1eA", "SECRET"), ("Grant & Hale Ltd", "ORG")]),
    ("** (DBConnection.ConnectionError) tcp recv: closed after 15000ms; job 4412 worker=App.Mailer attempt=2, "
     "invoice INV-2026-0042 state issued, gross $1,230.00", []),
]

REWRITE_PROMPT = """You redact personal data in text taken from an application database (bank transfer titles, notes, error messages, logs, JSON). The text is Polish or English.

Copy the text exactly, character for character, but replace every piece of personal data with its type in brackets: [PERSON] (names, also first names alone, diminutives, declined Polish forms, names in capitals), [ORG] (client or vendor company names), [ADDRESS], [EMAIL], [PHONE], [IP], [ID] (PESEL, NIP, REGON, SSN, tax or document numbers), [IBAN], [SECRET] (passwords, hashes, API keys, tokens, encryption keys), [DOB].

Keep everything else unchanged: UUIDs, invoice numbers, error and module names, statuses, amounts, timestamps, bank names. Output only the rewritten text."""


class Bonsai:
    MASKED = None

    def __init__(self, url=os.environ.get("BONSAI_URL", "http://127.0.0.1:8080"), thinking=False,
                 variant=os.environ.get("BONSAI_VARIANT", "PQ2_0"), mode=os.environ.get("BONSAI_MODE", "spans")):
        self.url, self.thinking, self.mode = url, thinking, mode
        suffix = "" if mode == "spans" else f"-{mode}"
        self.name = f"bonsai-2b-{variant}{suffix}" + ("-thinking" if thinking else "")
        self.not_found = 0

    def chat(self, messages, **extra):
        body = {
            "messages": messages,
            "temperature": 0.0 if not self.thinking else 0.6,
            "chat_template_kwargs": {"enable_thinking": self.thinking},
            **extra,
        }
        # A remote server behind an SSH tunnel can drop a request; retry before giving up.
        for attempt in range(4):
            try:
                r = requests.post(f"{self.url}/v1/chat/completions", json=body, timeout=180)
                r.raise_for_status()
                return r.json()["choices"][0]["message"]["content"]
            except requests.RequestException:
                if attempt == 3:
                    raise
                import time

                time.sleep(10 * (attempt + 1))

    def detect(self, text):
        if self.mode == "rewrite":
            return self.rewrite(text)
        messages = [{"role": "system", "content": BONSAI_PROMPT}]
        if self.mode == "fewshot":
            for example, found in FEW_SHOT:
                answer = {"pii": [{"text": t, "type": k} for t, k in found]}
                messages += [{"role": "user", "content": example},
                             {"role": "assistant", "content": json.dumps(answer, ensure_ascii=False)}]
        messages.append({"role": "user", "content": text})
        content = self.chat(
            messages,
            max_tokens=1024 if not self.thinking else 6144,
            response_format={"type": "json_schema", "json_schema": {"name": "pii", "schema": BONSAI_SCHEMA}},
        )
        try:
            items = json.loads(content)["pii"]
        except (json.JSONDecodeError, KeyError, TypeError):
            return []
        return locate(text, [(i["text"], i["type"]) for i in items], self)

    def rewrite(self, text):
        """Every region the model changed counts as masked, placeholder or not."""
        import difflib

        out = self.chat([{"role": "system", "content": REWRITE_PROMPT}, {"role": "user", "content": text}],
                        max_tokens=len(text) + 256)
        # Diff by token, so a placeholder never aligns with single letters of a name.
        src = [m for m in re.finditer(r"\w+|\s+|[^\w\s]", text)]
        dst = [m.group() for m in re.finditer(r"\w+|\s+|[^\w\s]", out)]
        ops = difflib.SequenceMatcher(None, [m.group() for m in src], dst, autojunk=False).get_opcodes()
        spans = []
        for tag, i1, i2, j1, j2 in ops:
            if tag in ("replace", "delete"):
                start, end = src[i1].start(), src[i2 - 1].end()
                if text[start:end].strip():
                    label = re.search(r"\[([A-Z]+)\]", "".join(dst[j1:j2]))
                    spans.append((start, end, label.group(1) if label else "CHANGED"))
        return spans


def locate(text, items, counter):
    """Maps returned strings back to every place they occur in the text."""
    spans = []
    for value, label in items:
        value = value.strip()
        if not value:
            continue
        found = [m.start() for m in re.finditer(re.escape(value), text)]
        if not found:
            found = [m.start() for m in re.finditer(re.escape(value), text, re.I)]
        if not found:
            counter.not_found += 1
        spans += [(s, s + len(value), label) for s in found]
    return spans


def build(name):
    if name == "regex":
        return Regex()
    if name == "bardsai":
        return Bardsai()
    if name == "bardsai-onnx":
        return Bardsai(onnx="onnx/model_quantized.onnx")
    if name.startswith("gliner2-pl-t"):
        return Gliner2Polish(threshold=float(name.removeprefix("gliner2-pl-t")))
    if name.startswith("gliner2-pl-"):
        return Gliner2Polish(profile=name.removeprefix("gliner2-pl-"))
    if name == "nym":
        return Nym()
    if name == "bonsai":
        return Bonsai()
    if name == "bonsai-thinking":
        return Bonsai(thinking=True)
    raise ValueError(name)
