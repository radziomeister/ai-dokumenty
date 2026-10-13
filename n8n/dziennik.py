"""Dziennik serwera AI – co się działo między komputerami.

    python3 n8n/dziennik.py                       ostatnie 40 zdarzeń (dokumenty, rejestracje, odrzucenia)
    python3 n8n/dziennik.py -n 200                ostatnie 200
    python3 n8n/dziennik.py --dzis                tylko dzisiaj
    python3 n8n/dziennik.py --klient pc-ksiegowosc
    python3 n8n/dziennik.py --zdarzenie duplikat  (zapisano, do_sprawdzenia, duplikat, wysylka_odrzucona,
                                                   plik_przyjety, rejestracja, pominieto_nie_pdf)
    python3 n8n/dziennik.py --polaczenia          połączenia sieciowe (Caddy): IP, adres, kod HTTP

Źródła:
    logs/n8n/zdarzenia.jsonl   zdarzenia zapisywane przez workflowy n8n
    logs/caddy-dostep.log      każde połączenie HTTPS z serwerem (token klienta wycięty)
Pozostałe dzienniki: sekrety/n8n/klienci/prosby.log, odrzucone.log,
BACKUP2/do_sprawdzenia/_powiadomienia.log, u klienta %APPDATA%\\AI-Faktury\\agent.log
"""

import argparse
import json
from datetime import datetime
from pathlib import Path

PROJEKT = Path(__file__).resolve().parent.parent
ZDARZENIA = PROJEKT / "logs" / "n8n" / "zdarzenia.jsonl"
POLACZENIA = PROJEKT / "logs" / "caddy-dostep.log"

NAZWY = {
    "plik_przyjety": "przyjęto plik",
    "zapisano": "ZAPISANO",
    "do_sprawdzenia": "DO SPRAWDZENIA",
    "duplikat": "DUPLIKAT",
    "wysylka_odrzucona": "ODRZUCONO",
    "pominieto_nie_pdf": "pominięto",
    "rejestracja": "rejestracja",
    "m365_zapisano": "M365 OK",
    "m365_blad": "M365 błąd",
    "m365_porzucono": "M365 PORZUCONO",
    "aktualizacja_sprawdzenie": "aktualizacja",
    "aktualizacja_pobranie": "aktualizacja",
    "aktualizacja_odrzucona": "aktualizacja ✗",
}


def wczytaj_jsonl(plik: Path) -> list:
    if not plik.exists():
        return []
    wynik = []
    for linia in plik.read_text(encoding="utf-8").splitlines():
        try:
            wynik.append(json.loads(linia))
        except json.JSONDecodeError:
            continue
    return wynik


def szczegoly(z: dict) -> str:
    rodzaj = z.get("zdarzenie")
    plik = z.get("plik") or ""
    if rodzaj == "zapisano":
        kwota = z.get("kwota_brutto")
        kwota = f"{kwota:,.2f}".replace(",", " ").replace(".", ",") if isinstance(kwota, (int, float)) else "?"
        return f"{plik} → nr {z.get('numer_dokumentu')}, {z.get('kontrahent')}, {kwota} {z.get('waluta')}"
    if rodzaj == "do_sprawdzenia":
        bledy = z.get("bledy") or []
        return f"{plik} → {bledy[0] if bledy else '?'}" + (f" (+{len(bledy) - 1})" if len(bledy) > 1 else "")
    if rodzaj == "duplikat":
        w = z.get("wczesniej") or {}
        return f"{plik} → {z.get('rodzaj')}; wcześniej {w.get('przetworzono')} [{w.get('zrodlo')}]"
    if rodzaj == "wysylka_odrzucona":
        return f"{z.get('kod')}: {z.get('powod')}"
    if rodzaj == "plik_przyjety":
        return f"{plik}" + (f" ({z['rozmiar_kb']} KB)" if z.get("rozmiar_kb") is not None else "")
    if rodzaj == "m365_zapisano":
        return f"{plik} → SharePoint + Excel (próba {z.get('proba')}) {z.get('link') or ''}"
    if rodzaj in ("m365_blad", "m365_porzucono"):
        return f"{plik} → próba {z.get('proby')}, krok „{z.get('krok', '?')}”: {str(z.get('blad'))[:160]}"
    if rodzaj.startswith("aktualizacja"):
        return f"wersja {z.get('wersja') or '?'} {z.get('plik') or ''} {z.get('kod') or ''}".strip()
    if rodzaj == "rejestracja":
        return f"{z.get('komputer') or '?'} ({z.get('uzytkownik') or '?'}): {z.get('wynik')}"
    return plik


def pokaz_zdarzenia(arg) -> None:
    zdarzenia = wczytaj_jsonl(ZDARZENIA)
    if arg.dzis:
        dzis = datetime.now().strftime("%Y-%m-%d")
        zdarzenia = [z for z in zdarzenia if z.get("czas", "").startswith(dzis)]
    if arg.klient:
        zdarzenia = [z for z in zdarzenia if z.get("klient") == arg.klient]
    if arg.zdarzenie:
        zdarzenia = [z for z in zdarzenia if z.get("zdarzenie") == arg.zdarzenie]
    zdarzenia = zdarzenia[-arg.n:]
    if not zdarzenia:
        print("(brak zdarzeń)")
        return
    print(f"{'czas':<19}  {'komputer':<20} {'adres IP':<15} {'zdarzenie':<15} szczegóły")
    print("-" * 120)
    for z in zdarzenia:
        komputer = z.get("klient") or ("serwer (folder)" if z.get("zdarzenie") != "rejestracja" else "?")
        print(f"{z.get('czas', '?'):<19}  {komputer:<20} {z.get('ip') or '-':<15} "
              f"{NAZWY.get(z.get('zdarzenie'), z.get('zdarzenie')):<15} {szczegoly(z)}")


def pokaz_polaczenia(arg) -> None:
    wpisy = wczytaj_jsonl(POLACZENIA)
    if arg.dzis:
        dzis = datetime.now().date()
        wpisy = [w for w in wpisy if datetime.fromtimestamp(w.get("ts", 0)).date() == dzis]
    wpisy = wpisy[-arg.n:]
    if not wpisy:
        print("(brak połączeń)")
        return
    print(f"{'czas':<19}  {'adres IP':<15} {'metoda':<6} {'adres':<45} {'kod':<4} czas")
    print("-" * 100)
    for w in wpisy:
        r = w.get("request", {})
        adres = f"{r.get('host', '')}{r.get('uri', '')}"[:45]
        czas = datetime.fromtimestamp(w.get("ts", 0)).strftime("%Y-%m-%d %H:%M:%S")
        print(f"{czas:<19}  {r.get('client_ip') or r.get('remote_ip', '?'):<15} {r.get('method', ''):<6} "
              f"{adres:<45} {w.get('status', ''):<4} {w.get('duration', 0):.2f}s")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Dziennik serwera AI", formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-n", type=int, default=40, help="ile ostatnich wpisów (domyślnie 40)")
    p.add_argument("--dzis", action="store_true", help="tylko dzisiaj")
    p.add_argument("--klient", help="tylko ten komputer, np. pc-desktop-mi7n596")
    p.add_argument("--zdarzenie", help="tylko ten rodzaj zdarzenia, np. duplikat")
    p.add_argument("--polaczenia", action="store_true", help="połączenia sieciowe (Caddy) zamiast zdarzeń")
    arg = p.parse_args()
    pokaz_polaczenia(arg) if arg.polaczenia else pokaz_zdarzenia(arg)
