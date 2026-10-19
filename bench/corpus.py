"""Generates the benchmark corpus: text cells shaped like what a debugging
agent reads from an application database (transfer titles, notes, Oban
errors, inspected structs, JSON, logfmt, Postgres errors), in Polish and
English, with gold personal-data spans and `keep` spans that masking must not
touch because diagnosis depends on them.

    uv run python corpus.py            # writes data/corpus.jsonl
"""

import json
import random
import base64
import string
import uuid
from pathlib import Path

from faker import Faker

SEED = 20261019
PER_SHAPE = 25

rng = random.Random(SEED)
fake_pl = Faker("pl_PL")
fake_en = Faker("en_US")
fake_pl.seed_instance(SEED)
fake_en.seed_instance(SEED)

# nominative, genitive, dative, instrumental
MALE_GIVEN = [
    ("Jan", "Jana", "Janowi", "Janem"),
    ("Piotr", "Piotra", "Piotrowi", "Piotrem"),
    ("Tomasz", "Tomasza", "Tomaszowi", "Tomaszem"),
    ("Krzysztof", "Krzysztofa", "Krzysztofowi", "Krzysztofem"),
    ("Paweł", "Pawła", "Pawłowi", "Pawłem"),
    ("Michał", "Michała", "Michałowi", "Michałem"),
    ("Marcin", "Marcina", "Marcinowi", "Marcinem"),
    ("Łukasz", "Łukasza", "Łukaszowi", "Łukaszem"),
    ("Marek", "Marka", "Markowi", "Markiem"),
    ("Grzegorz", "Grzegorza", "Grzegorzowi", "Grzegorzem"),
    ("Jakub", "Jakuba", "Jakubowi", "Jakubem"),
    ("Andrzej", "Andrzeja", "Andrzejowi", "Andrzejem"),
    ("Wojciech", "Wojciecha", "Wojciechowi", "Wojciechem"),
    ("Rafał", "Rafała", "Rafałowi", "Rafałem"),
    ("Mateusz", "Mateusza", "Mateuszowi", "Mateuszem"),
    ("Szymon", "Szymona", "Szymonowi", "Szymonem"),
]
FEMALE_GIVEN = [
    ("Anna", "Anny", "Annie", "Anną"),
    ("Katarzyna", "Katarzyny", "Katarzynie", "Katarzyną"),
    ("Małgorzata", "Małgorzaty", "Małgorzacie", "Małgorzatą"),
    ("Agnieszka", "Agnieszki", "Agnieszce", "Agnieszką"),
    ("Ewa", "Ewy", "Ewie", "Ewą"),
    ("Zofia", "Zofii", "Zofii", "Zofią"),
    ("Joanna", "Joanny", "Joannie", "Joanną"),
    ("Magdalena", "Magdaleny", "Magdalenie", "Magdaleną"),
    ("Monika", "Moniki", "Monice", "Moniką"),
    ("Barbara", "Barbary", "Barbarze", "Barbarą"),
    ("Aleksandra", "Aleksandry", "Aleksandrze", "Aleksandrą"),
    ("Karolina", "Karoliny", "Karolinie", "Karoliną"),
    ("Dorota", "Doroty", "Dorocie", "Dorotą"),
]
DIMINUTIVES = [
    ("Basia", "Basi", "Basi", "Basią", "f"),
    ("Kasia", "Kasi", "Kasi", "Kasią", "f"),
    ("Gosia", "Gosi", "Gosi", "Gosią", "f"),
    ("Ola", "Oli", "Oli", "Olą", "f"),
    ("Tomek", "Tomka", "Tomkowi", "Tomkiem", "m"),
    ("Kuba", "Kuby", "Kubie", "Kubą", "m"),
    ("Bartek", "Bartka", "Bartkowi", "Bartkiem", "m"),
    ("Piotrek", "Piotrka", "Piotrkowi", "Piotrkiem", "m"),
]
# male forms (nom, gen, dat, inst), female forms (nom, gen, dat, inst)
SURNAMES = [
    (("Kowalski", "Kowalskiego", "Kowalskiemu", "Kowalskim"), ("Kowalska", "Kowalskiej", "Kowalskiej", "Kowalską")),
    (("Wiśniewski", "Wiśniewskiego", "Wiśniewskiemu", "Wiśniewskim"), ("Wiśniewska", "Wiśniewskiej", "Wiśniewskiej", "Wiśniewską")),
    (("Lewandowski", "Lewandowskiego", "Lewandowskiemu", "Lewandowskim"), ("Lewandowska", "Lewandowskiej", "Lewandowskiej", "Lewandowską")),
    (("Zieliński", "Zielińskiego", "Zielińskiemu", "Zielińskim"), ("Zielińska", "Zielińskiej", "Zielińskiej", "Zielińską")),
    (("Dąbrowski", "Dąbrowskiego", "Dąbrowskiemu", "Dąbrowskim"), ("Dąbrowska", "Dąbrowskiej", "Dąbrowskiej", "Dąbrowską")),
    (("Kwiatkowski", "Kwiatkowskiego", "Kwiatkowskiemu", "Kwiatkowskim"), ("Kwiatkowska", "Kwiatkowskiej", "Kwiatkowskiej", "Kwiatkowską")),
    (("Wysocki", "Wysockiego", "Wysockiemu", "Wysockim"), ("Wysocka", "Wysockiej", "Wysockiej", "Wysocką")),
    (("Nowak", "Nowaka", "Nowakowi", "Nowakiem"), ("Nowak", "Nowak", "Nowak", "Nowak")),
    (("Wójcik", "Wójcika", "Wójcikowi", "Wójcikiem"), ("Wójcik", "Wójcik", "Wójcik", "Wójcik")),
    (("Kaczmarek", "Kaczmarka", "Kaczmarkowi", "Kaczmarkiem"), ("Kaczmarek", "Kaczmarek", "Kaczmarek", "Kaczmarek")),
    (("Mazur", "Mazura", "Mazurowi", "Mazurem"), ("Mazur", "Mazur", "Mazur", "Mazur")),
    (("Krawczyk", "Krawczyka", "Krawczykowi", "Krawczykiem"), ("Krawczyk", "Krawczyk", "Krawczyk", "Krawczyk")),
    (("Wróbel", "Wróbla", "Wróblowi", "Wróblem"), ("Wróbel", "Wróbel", "Wróbel", "Wróbel")),
    (("Pawlak", "Pawlaka", "Pawlakowi", "Pawlakiem"), ("Pawlak", "Pawlak", "Pawlak", "Pawlak")),
    (("Sikora", "Sikory", "Sikorze", "Sikorą"), ("Sikora", "Sikory", "Sikorze", "Sikorą")),
    (("Mazurkiewicz", "Mazurkiewicza", "Mazurkiewiczowi", "Mazurkiewiczem"), ("Mazurkiewicz", "Mazurkiewicz", "Mazurkiewicz", "Mazurkiewicz")),
    # Surnames that are also common words.
    (("Wilk", "Wilka", "Wilkowi", "Wilkiem"), ("Wilk", "Wilk", "Wilk", "Wilk")),
    (("Lis", "Lisa", "Lisowi", "Lisem"), ("Lis", "Lis", "Lis", "Lis")),
    (("Zając", "Zająca", "Zającowi", "Zającem"), ("Zając", "Zając", "Zając", "Zając")),
    (("Mróz", "Mroza", "Mrozowi", "Mrozem"), ("Mróz", "Mróz", "Mróz", "Mróz")),
    (("Kowal", "Kowala", "Kowalowi", "Kowalem"), ("Kowal", "Kowal", "Kowal", "Kowal")),
]
CASES = {"nom": 0, "gen": 1, "dat": 2, "inst": 3}
TRADES_PL = ["Usługi Remontowe", "Doradztwo IT", "Transport", "Studio Graficzne", "Hydraulika", "Biuro Rachunkowe"]
BANKS_PL = ["mBank", "PKO BP", "ING Bank Śląski", "Santander", "Pekao"]
BANKS_EN = ["Barclays", "HSBC", "Chase", "Revolut", "Wise"]


class Cell:
    """Builds text from segments so gold offsets are exact."""

    def __init__(self, lang, shape):
        self.lang, self.shape = lang, shape
        self.parts, self.spans, self.keep = [], [], []
        self.length = 0

    def t(self, text):
        self.parts.append(text)
        self.length += len(text)
        return self

    def pii(self, text, kind):
        if text:
            self.spans.append({"start": self.length, "end": self.length + len(text), "type": kind})
        return self.t(text)

    def k(self, text):
        self.keep.append({"start": self.length, "end": self.length + len(text)})
        return self.t(text)

    def build(self, i):
        text = "".join(self.parts)
        for s in self.spans + self.keep:
            assert s["end"] <= len(text)
        return {"id": f"{self.lang}-{self.shape}-{i:03d}", "lang": self.lang, "shape": self.shape,
                "text": text, "spans": self.spans, "keep": self.keep}


# --- values ---------------------------------------------------------------

def pl_person(case="nom", diminutive_ok=False):
    female = rng.random() < 0.5
    if diminutive_ok and rng.random() < 0.25:
        d = rng.choice(DIMINUTIVES)
        female = d[4] == "f"
        given = d[CASES[case]]
    else:
        given = rng.choice(FEMALE_GIVEN if female else MALE_GIVEN)[CASES[case]]
    m, f = rng.choice(SURNAMES)
    surname = (f if female else m)[CASES[case]]
    return given, surname, female


def en_person():
    return fake_en.first_name(), fake_en.last_name()


def token_urlsafe(n):
    return base64.urlsafe_b64encode(rng.randbytes(n)).rstrip(b"=").decode()


def token_hex(n):
    return rng.randbytes(n).hex()


def digits(n):
    return "".join(rng.choice(string.digits) for _ in range(n))


def nip():
    while True:
        base = [rng.randrange(10) for _ in range(9)]
        check = sum(d * w for d, w in zip(base, [6, 5, 7, 2, 3, 4, 5, 6, 7])) % 11
        if check != 10:
            return "".join(map(str, base + [check]))


def pesel():
    y, mth, d = rng.randrange(1950, 2000), rng.randrange(1, 13), rng.randrange(1, 29)
    base = [int(c) for c in f"{y % 100:02d}{mth:02d}{d:02d}"] + [rng.randrange(10) for _ in range(4)]
    s = sum(a * b for a, b in zip(base, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]))
    return "".join(map(str, base + [(10 - s % 10) % 10]))


def regon():
    base = [rng.randrange(10) for _ in range(8)]
    c = sum(a * b for a, b in zip(base, [8, 9, 2, 3, 4, 5, 6, 7])) % 11
    return "".join(map(str, base + [0 if c == 10 else c]))


def nrb(spaced=False):
    bban = "1140" + digits(4) + digits(16)
    check = 98 - int(bban + "252100") % 97
    n = f"{check:02d}{bban}"
    return " ".join([n[:2]] + [n[i:i + 4] for i in range(2, 26, 4)]) if spaced else n


def pl_phone():
    return rng.choice([f"+48 {digits(3)} {digits(3)} {digits(3)}", f"{digits(3)}-{digits(3)}-{digits(3)}", f"+48{digits(9)}"])


def ascii_fold(s):
    table = str.maketrans("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", "acelnoszzACELNOSZZ")
    return s.translate(table)


def email_for(given, surname, lang):
    domains = ["gmail.com", "wp.pl", "onet.pl", "firma.pl", "o2.pl"] if lang == "pl" else ["gmail.com", "yahoo.com", "outlook.com", "acme.io"]
    local = rng.choice([f"{given}.{surname}", f"{given[0]}{surname}", f"{surname}{digits(2)}"]).lower()
    return f"{ascii_fold(local)}@{rng.choice(domains)}"


def pl_address():
    return f"ul. {fake_pl.street_name()} {rng.randrange(1, 150)}{rng.choice(['', '/' + str(rng.randrange(1, 40))])}, {fake_pl.postcode()} {fake_pl.city()}"


def en_address():
    return fake_en.address().replace("\n", ", ")


def pl_company():
    g, s, _ = pl_person()
    return rng.choice([f"{s} i Wspólnicy S.A.", f"{rng.choice(TRADES_PL)} {s} Sp. z o.o.", f"PHU {g} {s}",
                       f"{fake_pl.company()}"])


def en_company():
    return fake_en.company()


def secret():
    return rng.choice([
        "sk_live_" + "".join(rng.choice(string.ascii_letters + string.digits) for _ in range(24)),
        "ghp_" + "".join(rng.choice(string.ascii_letters + string.digits) for _ in range(36)),
        "ya29." + token_urlsafe(30),
        token_urlsafe(32),
        "eyJhbGciOiJIUzI1NiJ9." + token_urlsafe(40) + "." + token_urlsafe(32),
    ])


def ip():
    return rng.choice([fake_en.ipv4_public(), fake_en.ipv6()])


def uid():
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def invoice_no(lang):
    return f"FV/{rng.randrange(1, 300)}/10/2026" if lang == "pl" else f"INV-2026-{rng.randrange(1, 9999):04d}"


def amount(lang):
    v = rng.randrange(100, 50000) + rng.randrange(100) / 100
    return f"{v:,.2f} PLN".replace(",", " ").replace(".", ",") if lang == "pl" else f"${v:,.2f}"


def ts():
    return f"2026-10-{rng.randrange(1, 19):02d}T{rng.randrange(24):02d}:{rng.randrange(60):02d}:{rng.randrange(60):02d}Z"


# --- shapes ----------------------------------------------------------------

def transfer_title(c):
    if c.lang == "pl":
        g, s, _ = pl_person(rng.choice(["gen", "nom"]))
        form = rng.choice([
            lambda: c.t("Przelew od ").pii(f"{g} {s}", "PERSON").t(" za ").k(invoice_no("pl")),
            lambda: c.t("ZAPLATA ZA ").k(invoice_no("pl")).t(" ").pii(f"{g.upper()} {s.upper()}", "PERSON").t(" ").pii(pl_address().upper(), "ADDRESS"),
            lambda: c.t("Zwrot nadpłaty dla ").pii(" ".join(pl_person("gen")[:2]), "PERSON").t(", rachunek ").pii(nrb(True), "IBAN"),
            lambda: c.t("Opłata abonamentowa ").k("10/2026").t(" NIP ").pii(nip(), "ID"),
        ])
    else:
        g, s = en_person()
        form = rng.choice([
            lambda: c.t("Payment from ").pii(f"{g} {s}", "PERSON").t(" for ").k(invoice_no("en")),
            lambda: c.t("REFUND ").pii(f"{s.upper()} {g.upper()}", "PERSON").t(" REF ").k(invoice_no("en")),
            lambda: c.t("Transfer to ").pii(en_company(), "ORG").t(" acct ").pii(fake_en.iban(), "IBAN"),
            lambda: c.t("Monthly subscription ").k("10/2026").t(" card ending ").pii(digits(4), "ID"),
        ])
    form()


def internal_note(c):
    if c.lang == "pl":
        g, s, female = pl_person("inst", diminutive_ok=True)
        g2, s2, female2 = pl_person("nom", diminutive_ok=True)
        verb = "obiecała" if female else "obiecał"
        took = "przejęła" if female2 else "przejął"
        title = rng.choice(["", "pani " if female2 else "pan "])
        c.t("Rozmawiałem z ").pii(f"{g} {s}", "PERSON").t(f", {verb} zapłacić ").k(invoice_no("pl")).t(" do piątku. Sprawę ")
        c.t(f"{took} {title}").pii(g2 if rng.random() < 0.3 else f"{g2} {s2}", "PERSON").t(" z księgowości")
        if rng.random() < 0.5:
            c.t(", tel. ").pii(pl_phone(), "PHONE")
        c.t(".")
    else:
        g, s = en_person()
        g2, s2 = en_person()
        c.t("Called ").pii(f"{g} {s}", "PERSON").t(", promised to pay ").k(invoice_no("en")).t(" by Friday. ")
        c.pii(g2 if rng.random() < 0.3 else f"{g2} {s2}", "PERSON").t(" from accounting took over")
        if rng.random() < 0.5:
            c.t(", call back at ").pii(fake_en.phone_number(), "PHONE")
        c.t(".")


def oban_error(c):
    if c.lang == "pl":
        g, s, _ = pl_person()
        tax = nip() + rng.choice([" ", "", " "])
        name = f"{g} {s}"
        email = email_for(g, s, "pl")
        c.k("** (Ash.Error.Invalid)").t(" Invalid Error\n\n* Invalid value provided for ").k("buyer_tax_id").t(": does not match KSeF pattern.\n\nValue: \"")
        c.pii(tax, "ID").t("\"\n\n#Ash.Changeset<action: :submit, attributes: %{buyer_display_name: \"").pii(name, "PERSON")
        c.t("\", buyer_tax_id: \"").pii(tax, "ID").t("\", email: \"").pii(email, "EMAIL").t("\"}, invoice_id: \"").k(uid()).t("\">")
    else:
        g, s = en_person()
        c.k("** (Ecto.ConstraintError)").t(" constraint error when attempting to insert struct:\n\n    * ").k("users_email_index").t(" (unique_constraint)\n\n")
        c.t("%App.Accounts.User{id: \"").k(uid()).t("\", email: \"").pii(email_for(g, s, "en"), "EMAIL").t("\", name: \"").pii(f"{g} {s}", "PERSON")
        c.t("\", phone: \"").pii(fake_en.phone_number(), "PHONE").t("\", inserted_at: ").k(ts()).t("}")


def json_args(c):
    lang = c.lang
    if lang == "pl":
        g, s, _ = pl_person()
    else:
        g, s = en_person()
    c.t('{"organization_id": "').k(uid()).t('", "tenant": "').k(uid()).t('", "customer": {"name": "').pii(f"{g} {s}", "PERSON")
    c.t('", "email": "').pii(email_for(g, s, lang), "EMAIL").t('", "address": "').pii(pl_address() if lang == "pl" else en_address(), "ADDRESS").t('"}, ')
    if rng.random() < 0.5:
        c.t('"encryption_key": "').pii(secret(), "SECRET").t('", ')
    if lang == "pl" and rng.random() < 0.5:
        c.t('"pesel": "').pii(pesel(), "ID").t('", ')
    c.t('"invoice_number": "').k(invoice_no(lang)).t('", "attempt": ').k(str(rng.randrange(1, 9))).t("}")


def logfmt(c):
    lang = c.lang
    if lang == "pl":
        g, s, _ = pl_person()
    else:
        g, s = en_person()
    c.t(f"{ts()} level=error request_id=").k(token_hex(8)).t(" user_id=").k(uid())
    c.t(" email=").pii(email_for(g, s, lang), "EMAIL").t(" remote_ip=").pii(ip(), "IP")
    if rng.random() < 0.4:
        c.t(" authorization=\"Bearer ").pii(secret(), "SECRET").t('"')
    c.t(' msg="').k(rng.choice(["login failed: invalid password", "token refresh failed", "rate limited", "upload rejected: file too large"])).t('"')


def postgres_error(c):
    lang = c.lang
    if lang == "pl":
        g, s, _ = pl_person()
    else:
        g, s = en_person()
    kind = rng.choice(["email", "tax_id", "phone"])
    value = {"email": lambda: email_for(g, s, lang), "tax_id": lambda: nip() if lang == "pl" else f"{digits(2)}-{digits(7)}",
             "phone": lambda: pl_phone() if lang == "pl" else fake_en.phone_number()}[kind]()
    typ = {"email": "EMAIL", "tax_id": "ID", "phone": "PHONE"}[kind]
    c.t("ERROR:  ").k("duplicate key value violates unique constraint").t(f' "{kind}_index"\nDETAIL:  Key ({kind})=(').pii(value, typ).t(") already exists.")


def support_ticket(c):
    if c.lang == "pl":
        g, s, female = pl_person()
        c.t("Od: ").pii(f"{g} {s}", "PERSON").t(" <").pii(email_for(g, s, "pl"), "EMAIL").t(">\nTemat: Nie mogę wystawić faktury ").k(invoice_no("pl")).t("\n\n")
        c.t("Dzień dobry, od wczoraj wyskakuje błąd ").k("HTTP 422").t(" przy wysyłce do KSeF. Mój NIP to ").pii(nip(), "ID").t(". Proszę o pilny kontakt: ").pii(pl_phone(), "PHONE").t(".\n")
        c.t("Pozdrawiam, ").pii(g, "PERSON")
    else:
        g, s = en_person()
        c.t("From: ").pii(f"{g} {s}", "PERSON").t(" <").pii(email_for(g, s, "en"), "EMAIL").t(">\nSubject: Cannot issue invoice ").k(invoice_no("en")).t("\n\n")
        c.t("Hi, since yesterday I get ").k("HTTP 422").t(" when sending the invoice. Our company is ").pii(en_company(), "ORG").t(". Please call me at ").pii(fake_en.phone_number(), "PHONE").t(".\n")
        c.t("Thanks, ").pii(g, "PERSON")


def delivery_note(c):
    if c.lang == "pl":
        c.t("Wysłać paczkę na adres ").pii(pl_address(), "ADDRESS").t(", odbiór osobisty u ").pii(" ".join(pl_person("gen")[:2]), "PERSON")
        if rng.random() < 0.5:
            c.t(", ur. ").pii(f"{rng.randrange(1, 29):02d}.{rng.randrange(1, 13):02d}.{rng.randrange(1950, 2000)}", "DOB")
        c.t(". Kurier: ").k(rng.choice(["DPD", "InPost", "DHL"])).t(", status ").k(rng.choice(["in_transit", "delivered", "returned"])).t(".")
    else:
        g, s = en_person()
        c.t("Ship to ").pii(en_address(), "ADDRESS").t(", attention ").pii(f"{g} {s}", "PERSON")
        if rng.random() < 0.5:
            c.t(", DOB ").pii(fake_en.date_of_birth().isoformat(), "DOB")
        c.t(". Carrier: ").k(rng.choice(["UPS", "FedEx", "DHL"])).t(", status ").k(rng.choice(["in_transit", "delivered", "returned"])).t(".")


def inspected_struct(c):
    lang = c.lang
    if lang == "pl":
        g, s, _ = pl_person()
    else:
        g, s = en_person()
    c.t("%App.Accounts.User{__meta__: #Ecto.Schema.Metadata<:loaded, \"users\">, id: \"").k(uid()).t("\", email: \"").pii(email_for(g, s, lang), "EMAIL")
    c.t("\", name: \"").pii(f"{g} {s}", "PERSON").t("\", hashed_password: \"").pii("$argon2id$v=19$m=65536,t=3,p=4$" + token_urlsafe(22), "SECRET")
    c.t("\", confirmed_at: ").k("nil").t(", organization_id: \"").k(uid()).t("\"}")


def company_row(c):
    if c.lang == "pl":
        c.t("Kontrahent: ").pii(pl_company(), "ORG").t(", NIP ").pii(nip(), "ID").t(", REGON ").pii(regon(), "ID").t(", konto ").pii("PL" + nrb(), "IBAN")
        c.t(", bank ").k(rng.choice(BANKS_PL)).t(", termin płatności ").k(f"{rng.choice([7, 14, 30])} dni")
    else:
        c.t("Vendor: ").pii(en_company(), "ORG").t(", EIN ").pii(f"{digits(2)}-{digits(7)}", "ID").t(", IBAN ").pii(fake_en.iban(), "IBAN")
        c.t(", bank ").k(rng.choice(BANKS_EN)).t(", terms ").k(f"net {rng.choice([7, 14, 30])}")


def ambiguous_words(c):
    # Surnames that are ordinary words, next to the same words used normally.
    if c.lang == "pl":
        m, f = rng.choice(SURNAMES[-5:])
        female = rng.random() < 0.5
        given = rng.choice(FEMALE_GIVEN if female else MALE_GIVEN)
        word = {"Wilk": "wilk", "Lis": "lis", "Zając": "zając", "Mróz": "mróz", "Kowal": "kowal"}[m[0]]
        c.t("Klient ").pii(f"{given[0]} {(f if female else m)[0]}", "PERSON").t(f" zgłosił, że eksport CSV zawiesza się na kolumnie „{word}”. ")
        c.t("Potwierdzone z ").pii(f"{given[3]} {(f if female else m)[3]}", "PERSON").t(", błąd ").k(":timeout").t(" w ").k("App.Export.CsvWorker").t(".")
    else:
        first = rng.choice(["Rose", "Hunter", "Faith", "Grace", "Will", "Mark", "Bill"])
        last = rng.choice(["Baker", "Cook", "Smith", "Fox", "Brown", "Young", "King"])
        c.t("Customer ").pii(f"{first} {last}", "PERSON").t(f" reports the export hangs; {first.lower()} and {last.lower()} are also product tags. ")
        c.t("Error ").k(":timeout").t(" in ").k("App.Export.CsvWorker").t(".")


def negative(c):
    lang = c.lang
    form = rng.choice([
        lambda: c.k("** (DBConnection.ConnectionError)").t(" tcp recv (idle): closed after ").k(f"{rng.randrange(1000, 60000)}ms"),
        lambda: c.t("Oban job ").k(str(rng.randrange(10000, 99999))).t(" worker=").k("AshOban.Workers.BankAccountSyncTransactions").t(" attempt=").k(str(rng.randrange(1, 9))).t(" error=").k(":requisition_expired"),
        lambda: c.t("Invoice ").k(invoice_no(lang)).t(" state changed ").k("issued").t(" -> ").k("sent_to_ksef").t(" at ").k(ts()).t(", gross ").k(amount(lang)),
        lambda: c.t("GET /api/organizations/").k(uid()).t("/invoices?page=").k(str(rng.randrange(1, 9))).t(" -> ").k(rng.choice(["200", "404", "500"])).t(" in ").k(f"{rng.randrange(3, 900)}ms"),
        lambda: c.t("Sync of account ").k(uid()).t(" at ").k(rng.choice(BANKS_PL + BANKS_EN)).t(" finished: ").k(f"{rng.randrange(0, 300)} transactions").t(", next run ").k(ts()),
        lambda: c.t("** (FunctionClauseError) no function clause matching in ").k("App.Ksef.Client.parse_response/1").t("\n    (app 0.1.0) lib/app/ksef/client.ex:").k(str(rng.randrange(10, 400))),
        lambda: c.t("Migracja ").k("20261015093000_add_ksef_number").t(" zakończona w ").k(f"{rng.randrange(1, 90)}s") if lang == "pl" else c.t("Migration ").k("20261015093000_add_ksef_number").t(" finished in ").k(f"{rng.randrange(1, 90)}s"),
        lambda: c.t("Faktura ").k(invoice_no("pl")).t(" odrzucona przez KSeF: ").k("kod 21405").t(", termin ").k("2026-10-20") if lang == "pl" else c.t("Webhook ").k("invoice.paid").t(" retried ").k(f"{rng.randrange(1, 5)} times").t(", signature ").k("valid"),
    ])
    form()


SHAPES = [transfer_title, internal_note, oban_error, json_args, logfmt, postgres_error, support_ticket,
          delivery_note, inspected_struct, company_row, ambiguous_words, negative]


def main():
    out = Path(__file__).parent / "data" / "corpus.jsonl"
    out.parent.mkdir(exist_ok=True)
    rows = []
    for lang in ["pl", "en"]:
        for shape in SHAPES:
            for i in range(PER_SHAPE * (2 if shape is negative else 1)):
                c = Cell(lang, shape.__name__)
                shape(c)
                rows.append(c.build(i))
    with out.open("w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"{len(rows)} cells, {sum(len(r['spans']) for r in rows)} gold spans -> {out}")


if __name__ == "__main__":
    main()
