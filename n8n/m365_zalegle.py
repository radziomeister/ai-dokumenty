"""Wysyła do Microsoft 365 zapisane faktury, których tam jeszcze nie ma.

    python3 n8n/m365_zalegle.py          pokaż, co zostałoby wysłane
    python3 n8n/m365_zalegle.py --wyslij dodaj je do kolejki (workflow „Synchronizacja M365” wyśle je w ciągu minuty)

Przydatne po dłuższej awarii, przy podłączaniu nowego tenanta albo dla faktur sprzed integracji.
Źródło: BACKUP2/wyniki/*.json (pełne dane zapisanych faktur). Pomijane są faktury już wysłane
(m365_kolejka/wyslane/) i czekające w kolejce. Skrypt nie wypisuje danych z faktur – tylko nazwy plików.
"""

import json
import os
import sys
import time
from pathlib import Path

BACKUP2 = Path.home() / "LLAMA SERVER" / "BACKUP2"
WYNIKI = BACKUP2 / "wyniki"
KOLEJKA = BACKUP2 / "m365_kolejka"
W_KONTENERZE = "/home/node/praca"   # tak folder roboczy widzi n8n


def klucz_faktury(nip, numer) -> str:
    """Ten sam klucz co w n8n (_wspolne.js): NIP – same cyfry, numer – bez spacji, wielkie litery."""
    return "".join(c for c in str(nip or "") if c.isdigit()) + "|" + "".join(str(numer or "").upper().split())


def w_obiegu() -> tuple:
    """PDF-y (ścieżki względne) i klucze faktur już wysłanych albo czekających w kolejce."""
    pliki, klucze = set(), set()
    for plik in list(KOLEJKA.glob("*.json")) + list((KOLEJKA / "wyslane").glob("*.json")):
        try:
            z = json.loads(plik.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        pliki.add(os.path.relpath(z["pdf"], W_KONTENERZE))
        klucze.add(klucz_faktury(z["wiersz"].get("nip_sprzedawcy"), z["wiersz"].get("numer_dokumentu")))
    return pliki, klucze


def main(wyslij: bool) -> None:
    pliki, klucze = w_obiegu()
    zalegle, powtorki = [], []
    for wynik in sorted(WYNIKI.glob("*.json")):
        d = json.loads(wynik.read_text(encoding="utf-8"))
        plik = d.get("plik")
        if not plik or plik in pliki or not (BACKUP2 / plik).is_file():
            continue
        klucz = klucz_faktury(d.get("nip_sprzedawcy"), d.get("numer_dokumentu"))
        if klucz in klucze:   # ta sama faktura zapisana dwa razy (np. sprzed wykrywania duplikatów)
            powtorki.append(d)
            continue
        klucze.add(klucz)
        zalegle.append(d)
    for d in powtorki:
        print("   pomijam powtórkę tej samej faktury:", Path(d["plik"]).name)

    if not zalegle:
        print("Wszystkie zapisane faktury są już w Microsoft 365 albo w kolejce.")
        return
    print(f"Zaległe faktury: {len(zalegle)}")
    for d in zalegle:
        print("  ", Path(d["plik"]).name)
    if not wyslij:
        print("\nAby je wysłać: python3 n8n/m365_zalegle.py --wyslij")
        return

    KOLEJKA.mkdir(exist_ok=True)
    for d in zalegle:
        rok, miesiac = d["data_wystawienia"].split("-")[:2]
        zrodlo = d.get("zrodlo", "folder serwera")
        zadanie = {
            "utworzono": time.strftime("%Y-%m-%d %H:%M:%S"),
            "pdf": f"{W_KONTENERZE}/{d['plik']}",
            "nazwa_pdf": Path(d["plik"]).name,
            "rok": rok, "miesiac": miesiac,
            "klient": zrodlo.removeprefix("klient: ") if zrodlo.startswith("klient: ") else None,
            "ip": None, "proby": 0, "zalegle": True,
            "wiersz": {
                "przetworzono": d.get("przetworzono"), "numer_dokumentu": d.get("numer_dokumentu"),
                "data_wystawienia": d.get("data_wystawienia"), "nip_sprzedawcy": d.get("nip_sprzedawcy"),
                "kontrahent": d.get("kontrahent"), "kwota_netto": d.get("kwota_netto"),
                "kwota_vat": d.get("kwota_vat"), "kwota_brutto": d.get("kwota_brutto"), "waluta": d.get("waluta"),
                "ostrzezenia": " | ".join(d.get("ostrzezenia") or []), "zrodlo": zrodlo,
            },
        }
        cel = KOLEJKA / f"{int(time.time() * 1000)}_{Path(d['plik']).stem}.json"
        tymczasowy = cel.with_suffix(".json.tmp")
        tymczasowy.write_text(json.dumps(zadanie, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tymczasowy, cel)   # zapis atomowy – n8n nie odczyta połowy pliku
        time.sleep(0.002)
    print(f"\nDodano do kolejki: {len(zalegle)}. Postęp: python3 n8n/dziennik.py --zdarzenie m365_zapisano")


if __name__ == "__main__":
    main("--wyslij" in sys.argv[1:])
