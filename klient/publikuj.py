"""Publikuje nową wersję agenta dla komputerów klienckich (pobiera ją aktualizacja.ps1).

    1. podnieś numer w klient/WERSJA (np. 1.0.0 → 1.1.0),
    2. python3 klient/publikuj.py "co się zmieniło" "kolejna zmiana"

Co robi:
  - kopiuje pliki agenta do dystrybucja/pliki/<wersja>/,
  - tworzy manifest (wersja, data, zmiany, nazwy plików + SHA-256 + rozmiar),
  - podpisuje manifest kluczem prywatnym sekrety/podpis/aktualizacje.key (RSA, SHA-256),
  - sprawdza podpis kluczem publicznym i to, że ten sam klucz jest wbudowany w aktualizacja.ps1,
  - na końcu atomowo podmienia dystrybucja/aktualizacja.json (manifest + podpis) – klienci
    widzą nową wersję dopiero, gdy wszystkie jej pliki są już na miejscu.
Serwer (n8n) wydaje te pliki tylko zaufanym komputerom z ważnym tokenem.
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

KLIENT = Path(__file__).resolve().parent
PROJEKT = KLIENT.parent
DYSTRYBUCJA = PROJEKT / "dystrybucja"
KLUCZ = PROJEKT / "sekrety" / "podpis" / "aktualizacje.key"
KLUCZ_PUB = PROJEKT / "sekrety" / "podpis" / "aktualizacje.pub"
KLUCZ_XML = PROJEKT / "sekrety" / "podpis" / "aktualizacje_publiczny.xml"

PLIKI = ["agent.ps1", "token.ps1", "aktualizacja.ps1", "aktualizacja.cmd", "instaluj.ps1", "CZYTAJ.txt", "WERSJA"]


def wersja_krotka(w: str) -> tuple:
    return tuple(int(x) for x in w.split("."))


def main(zmiany: list) -> None:
    wersja = (KLIENT / "WERSJA").read_text(encoding="utf-8").strip()
    wersja_krotka(wersja)  # format X.Y.Z

    aktualny = DYSTRYBUCJA / "aktualizacja.json"
    if aktualny.exists():
        stary = json.loads(base64.b64decode(json.loads(aktualny.read_text())["manifest_b64"]))
        if wersja_krotka(wersja) <= wersja_krotka(stary["wersja"]):
            sys.exit(f"Opublikowana jest już wersja {stary['wersja']} – podnieś numer w klient/WERSJA.")

    if KLUCZ_XML.read_text().strip() not in (KLIENT / "aktualizacja.ps1").read_text(encoding="utf-8-sig"):
        sys.exit("aktualizacja.ps1 ma wbudowany INNY klucz publiczny niż sekrety/podpis – klienci odrzuciliby podpis.")

    # 1. pliki wersji
    katalog = DYSTRYBUCJA / "pliki" / wersja
    katalog.mkdir(parents=True, exist_ok=True)
    opis_plikow = []
    for nazwa in PLIKI:
        tresc = (KLIENT / nazwa).read_bytes()
        (katalog / nazwa).write_bytes(tresc)
        opis_plikow.append({"nazwa": nazwa, "sha256": hashlib.sha256(tresc).hexdigest(), "rozmiar": len(tresc)})

    # 2. manifest + podpis
    manifest = json.dumps({
        "produkt": "AI Faktury – agent",
        "wersja": wersja,
        "opublikowano": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "zmiany": zmiany or ["Poprawki i ulepszenia"],
        "pliki": opis_plikow,
    }, ensure_ascii=False, indent=2).encode("utf-8")

    with tempfile.TemporaryDirectory() as tmp:
        m, sig = Path(tmp) / "manifest.json", Path(tmp) / "manifest.sig"
        m.write_bytes(manifest)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(KLUCZ), "-out", str(sig), str(m)], check=True)
        sprawdzenie = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(KLUCZ_PUB), "-signature", str(sig), str(m)],
                                     capture_output=True, text=True)
        if "Verified OK" not in sprawdzenie.stdout:
            sys.exit("Podpis nie przeszedł weryfikacji – nic nie opublikowano.")
        podpis = base64.b64encode(sig.read_bytes()).decode()

    # 3. atomowa publikacja
    nowy = DYSTRYBUCJA / "aktualizacja.json.tmp"
    nowy.write_text(json.dumps({"manifest_b64": base64.b64encode(manifest).decode(), "podpis": podpis}), encoding="utf-8")
    os.replace(nowy, aktualny)

    print(f"Opublikowano wersję {wersja} ({len(PLIKI)} plików, podpis RSA-SHA256 zweryfikowany).")
    for p in opis_plikow:
        print(f"   {p['nazwa']:<18} {p['rozmiar']:>7} B  sha256 {p['sha256'][:16]}…")


if __name__ == "__main__":
    main(sys.argv[1:])
