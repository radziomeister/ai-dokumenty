"""Zaufane komputery klienckie (agent „AI Faktury”) – zarządzanie przez administratora serwera.

Jak to działa:
  1. Instalator agenta na kliencie prosi serwer o token (n8n: /webhook/rejestracja).
  2. Jeśli adres IP komputera jest na liście zaufanych, serwer SAM wydaje token – jeden raz.
     Jeśli nie, prośba trafia do dziennika i czeka na decyzję administratora.
  3. Token działa tylko z adresu IP, dla którego go wydano.

Polecenia:
    python3 n8n/klienci.py prosby                      – kto prosił o dostęp (nieznane komputery)
    python3 n8n/klienci.py zaufaj 192.168.1.50 pc-ksiegowosc
    python3 n8n/klienci.py lista                       – zaufane komputery i stan tokenów
    python3 n8n/klienci.py resetuj pc-ksiegowosc       – unieważnia token, komputer może pobrać nowy
    python3 n8n/klienci.py usun pc-ksiegowosc          – usuwa z zaufanych i unieważnia token

Pliki (montowane do kontenera n8n):
    sekrety/n8n/zaufane/zaufane.json   IP → nazwa      (n8n tylko czyta)
    sekrety/n8n/klienci/klienci.json   nazwa → skrót SHA-256 tokenu, IP, data (zapisuje n8n)
    sekrety/n8n/klienci/prosby.log     dziennik próśb o token (zapisuje n8n)
Sam token nigdy nie jest zapisywany na serwerze – tylko jego skrót.
"""

import ipaddress
import json
import os
import re
import sys
from pathlib import Path

SEKRETY = Path(__file__).resolve().parent.parent / "sekrety"
ZAUFANE = SEKRETY / "n8n" / "zaufane" / "zaufane.json"
KLIENCI = SEKRETY / "n8n" / "klienci" / "klienci.json"
PROSBY = SEKRETY / "n8n" / "klienci" / "prosby.log"


def wczytaj(plik: Path) -> dict:
    return json.loads(plik.read_text(encoding="utf-8")) if plik.exists() and plik.stat().st_size else {}


def zapisz(plik: Path, dane: dict) -> None:
    plik.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(SEKRETY, 0o700)
    # Zapis atomowy (plik tymczasowy + podmiana nazwy): kontener n8n widzi zawsze cały plik.
    # Nadpisywanie w miejscu powodowało odczyt uciętej treści (OrbStack pamiętał stary rozmiar).
    tymczasowy = plik.with_suffix(".tmp")
    with open(tymczasowy, "w", encoding="utf-8") as f:
        json.dump(dane, f, indent=2, ensure_ascii=False)
    os.replace(tymczasowy, plik)


def adres_dockera(ip: str) -> bool:
    """Adresy wewnętrzne Dockera/OrbStack: za nimi mogą się kryć WSZYSTKIE komputery w sieci."""
    try:
        adres = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(adres in ipaddress.ip_network(n) for n in ("192.168.97.0/24", "172.16.0.0/12", "198.19.0.0/16"))


def zaufaj(ip: str, nazwa: str) -> None:
    try:
        adres = ipaddress.ip_address(ip)
    except ValueError:
        sys.exit(f"To nie jest adres IP: {ip}")
    if not adres.is_private:
        sys.exit("Zaufane mogą być tylko adresy z sieci lokalnej")
    if adres_dockera(ip):
        sys.exit(f"{ip} to adres wewnętrzny Dockera, a nie konkretnego komputera – nie można mu ufać")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,40}", nazwa):
        sys.exit("Nazwa: małe litery, cyfry i myślniki, np. pc-ksiegowosc")
    zaufane = wczytaj(ZAUFANE)
    if nazwa in zaufane.values() and zaufane.get(ip) != nazwa:
        sys.exit(f"Nazwa {nazwa} jest już używana przez inny adres")
    zaufane[ip] = nazwa
    zapisz(ZAUFANE, zaufane)
    print(f"Zaufano: {ip} → {nazwa}. Instalator na tym komputerze dostanie token przy najbliższej próbie.")
    print("Ustaw w routerze stały adres (rezerwację DHCP) dla tego komputera – token działa tylko z tego IP.")


def resetuj(nazwa: str, cicho=False) -> None:
    klienci = wczytaj(KLIENCI)
    if klienci.pop(nazwa, None) is None:
        if not cicho:
            print(f"{nazwa}: nie miał wydanego tokenu")
        return
    zapisz(KLIENCI, klienci)
    if not cicho:
        print(f"{nazwa}: token unieważniony – agent przestanie działać, instalator może pobrać nowy")


def usun(nazwa: str) -> None:
    zaufane = wczytaj(ZAUFANE)
    ip = next((k for k, v in zaufane.items() if v == nazwa), None)
    if ip is None:
        sys.exit(f"Nie ma zaufanego komputera {nazwa}")
    del zaufane[ip]
    zapisz(ZAUFANE, zaufane)
    resetuj(nazwa, cicho=True)
    print(f"Usunięto {nazwa} ({ip}) z zaufanych, token unieważniony")


def lista() -> None:
    zaufane, klienci = wczytaj(ZAUFANE), wczytaj(KLIENCI)
    if not zaufane:
        print("(brak zaufanych komputerów)")
    for ip, nazwa in sorted(zaufane.items(), key=lambda x: x[1]):
        k = klienci.get(nazwa)
        stan = f"token wydany {k['wydano']} dla {k.get('komputer', '?')}" if k else "token jeszcze nie pobrany"
        print(f"{nazwa:<20} {ip:<16} {stan}")


def prosby() -> None:
    if not PROSBY.exists():
        print("(brak próśb)")
        return
    zaufane = wczytaj(ZAUFANE)
    ostatnie = {}
    for linia in PROSBY.read_text(encoding="utf-8").splitlines():
        try:
            w = json.loads(linia)
        except json.JSONDecodeError:
            continue
        ostatnie[(w["ip"], w.get("komputer"))] = w
    pokazane = 0
    for (ip, komputer), w in ostatnie.items():
        if ip in zaufane or w.get("wynik") != "oczekuje":
            continue
        pokazane += 1
        print(f"{w['czas']}  IP {ip:<16} komputer {komputer or '?':<20} użytkownik {w.get('uzytkownik') or '?'}")
        if adres_dockera(ip):
            print("    UWAGA: to adres wewnętrzny Dockera, nie konkretnego komputera – serwer nie widzi prawdziwego IP,")
            print("    zatwierdzenie jest zablokowane (Caddy musi działać poza Dockerem)")
            continue
        print(f"    zatwierdź:  python3 ~/\"LLAMA SERVER/ai-dokumenty/n8n/klienci.py\" zaufaj {ip} pc-{re.sub(r'[^a-z0-9-]', '-', (komputer or 'nowy').lower())[:30]}")

    # Zaufane komputery, które proszą o NOWY token (np. po odinstalowaniu agenta) – token już wydany
    klienci = wczytaj(KLIENCI)
    for (ip, komputer), w in ostatnie.items():
        nazwa = zaufane.get(ip)
        if not nazwa or not w.get("wynik", "").startswith("odrzucono: token"):
            continue
        if nazwa not in klienci:
            continue  # token już zresetowany – komputer dostanie nowy przy następnej próbie
        if w["czas"] < klienci[nazwa]["wydano"]:
            continue  # prośba sprzed wydania aktualnego tokenu
        pokazane += 1
        print(f"{w['czas']}  IP {ip:<16} komputer {komputer or '?':<20} prosi o NOWY token (ma już wydany)")
        print(f"    jeśli to zamierzone (reinstalacja agenta):  python3 ~/\"LLAMA SERVER/ai-dokumenty/n8n/klienci.py\" resetuj {nazwa}")
    if not pokazane:
        print("(brak oczekujących próśb)")


if __name__ == "__main__":
    polecenie, *arg = sys.argv[1:] or ["lista"]
    if polecenie == "zaufaj" and len(arg) == 2:
        zaufaj(*arg)
    elif polecenie == "resetuj" and arg:
        resetuj(arg[0])
    elif polecenie == "usun" and arg:
        usun(arg[0])
    elif polecenie == "lista":
        lista()
    elif polecenie == "prosby":
        prosby()
    else:
        sys.exit(__doc__)
