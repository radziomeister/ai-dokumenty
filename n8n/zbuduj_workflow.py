"""Składa workflowy n8n z plików n8n/kod/*.js do plików importu.

    .venv/bin/python n8n/zbuduj_workflow.py
    → n8n/workflow_faktury.json      Workflow 1: faktury (folder serwera + agenci klientów)
    → n8n/workflow_rejestracja.json  rejestracja agentów: token dla zaufanych komputerów
    → n8n/workflow_aktualizacja.json aktualizacje agenta: podpisane wersje (klient/publikuj.py)
    → n8n/workflow_m365.json         synchronizacja z Microsoft 365: PDF → SharePoint, wiersz → Excel

Import, publikacja i restart n8n: bash n8n/wdroz.sh
"""

import json
from datetime import datetime
from pathlib import Path

KATALOG = Path(__file__).parent
KOD = KATALOG / "kod"
ID_WORKFLOW = "wf1Faktury000001"
ID_REJESTRACJA = "wf2Rejestracja01"
ID_AKTUALIZACJA = "wf3Aktualizacja1"
ID_M365 = "wf4Microsoft3651"
# Poświadczenie OAuth2 do Microsoft 365 (konto techniczne ai-faktury@), utworzone w n8n przez administratora
M365_POSWIADCZENIE = {"oAuth2Api": {"id": "2tJpqCOLFQqBQNPv", "name": "Microsoft 365 – AI Faktury"}}


WERSJA = datetime.now().strftime("%Y%m%d-%H%M%S")


def kod(plik: str) -> str:
    return (KOD / plik).read_text(encoding="utf-8").replace("__WERSJA__", WERSJA)


def wezel(nr, nazwa, typ, wersja, pozycja, parametry, **dodatkowe):
    return {
        "id": f"00000000-0000-4000-8000-{nr:012d}",
        "name": nazwa,
        "type": typ,
        "typeVersion": wersja,
        "position": pozycja,
        "parameters": parametry,
        **dodatkowe,
    }


WSPOLNE = (KOD / "_wspolne.js").read_text(encoding="utf-8")


def code(nr, nazwa, pozycja, plik, na_kazdy_element=True):
    parametry = {"jsCode": WSPOLNE + kod(plik)}
    if na_kazdy_element:
        parametry["mode"] = "runOnceForEachItem"
    return wezel(nr, nazwa, "n8n-nodes-base.code", 2, pozycja, parametry)


def jesli(nr, nazwa, pozycja, pole=None, wyrazenie=None):
    """Węzeł IF: wyjście 1 (true), gdy $json.<pole> (albo wyrażenie) jest true; wyjście 2 (false) w przeciwnym razie."""
    return wezel(nr, nazwa, "n8n-nodes-base.if", 2.2, pozycja, {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
            "conditions": [{
                "id": f"00000000-0000-4000-8000-{nr + 100:012d}",
                "leftValue": f"={{{{ {wyrazenie or '$json.' + pole} }}}}",
                "rightValue": "",
                "operator": {"type": "boolean", "operation": "true", "singleValue": True},
            }],
            "combinator": "and",
        },
        "options": {},
    })


wezly = [
    # Wejście A: plik wrzucony bezpośrednio na serwerze do BACKUP2/wejscie
    wezel(1, "Nowy plik w wejscie", "n8n-nodes-base.localFileTrigger", 1, [0, 200], {
        "triggerOn": "folder",
        "path": "/home/node/praca/wejscie",
        "events": ["add"],
        "options": {
            "awaitWriteFinish": True,   # czekaj, aż kopiowanie pliku się skończy
            "ignoreInitial": False,     # przy starcie przetwórz pliki wrzucone, gdy n8n był wyłączony
            "usePolling": True,         # działa też na folderach z Windows/Docker Desktop
            "depth": 0,                 # tylko wejscie/, bez podfolderów
            "ignored": "**/.*",         # pomijaj ukryte pliki (.DS_Store itp.)
        },
    }),
    code(2, "Tylko PDF", [220, 200], "1_tylko_pdf.js", na_kazdy_element=False),
    # Wejście B: plik od agenta na komputerze klienta (HTTPS przez Caddy, token klienta).
    # Odpowiedź HTTP = wynik ostatniego węzła przebiegu → powiadomienie / okno u klienta.
    wezel(11, "Od klienta (agent)", "n8n-nodes-base.webhook", 2, [0, 420], {
        "httpMethod": "POST",
        "path": "faktury",
        "responseMode": "lastNode",
        "responseData": "firstEntryJson",
        "options": {},
    }, webhookId="00000000-0000-4000-8000-0000000000aa"),
    code(12, "Klient: token i zapis", [220, 420], "0_klient_autoryzacja.js", na_kazdy_element=False),
    jesli(14, "Przyjęty?", [440, 420], "przyjety"),
    wezel(15, "Odrzucono", "n8n-nodes-base.noOp", 1, [660, 560], {}),
    wezel(13, "Plik do przetworzenia", "n8n-nodes-base.noOp", 1, [660, 300], {}),
    # Duplikat, poziom 1: ten sam plik – przed AI
    code(16, "Duplikat pliku?", [880, 300], "7_duplikat_pliku.js"),
    jesli(17, "Nowy plik?", [1100, 300], "nowy"),
    wezel(3, "Wczytaj PDF", "n8n-nodes-base.readWriteFile", 1.1, [1320, 300], {
        "operation": "read",
        "fileSelector": "={{ $json.sciezka }}",
        "options": {},
    }),
    wezel(4, "Tekst z PDF", "n8n-nodes-base.extractFromFile", 1.1, [1540, 300], {
        "operation": "pdf",
        "binaryPropertyName": "data",
        "options": {"joinPages": True, "keepSource": "both"},   # PDF zostaje – przyda się do OCR
    }, onError="continueRegularOutput"),
    # Skan (brak warstwy tekstowej) → lokalny OCR w kontenerze bez internetu
    jesli(21, "Jest tekst?", [1760, 300], wyrazenie="String($json.text ?? '').trim().length >= 50"),
    wezel(22, "OCR (skan)", "n8n-nodes-base.httpRequest", 4.2, [1980, 460], {
        "method": "POST",
        "url": "http://ocr:8080/ocr",
        "sendBody": True,
        "contentType": "binaryData",
        "inputDataFieldName": "data",
        "options": {"timeout": 300000},
    }, onError="continueRegularOutput"),
    code(5, "Przygotuj zapytanie", [2200, 300], "2_przygotuj_zapytanie.js"),
    wezel(6, "Ollama (lokalnie)", "n8n-nodes-base.httpRequest", 4.2, [2420, 300], {
        "method": "POST",
        "url": "http://host.docker.internal:11434/api/chat",
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify($json.zapytanie) }}",
        "options": {"timeout": 300000},
    }, onError="continueRegularOutput"),
    code(7, "Walidacja", [2640, 300], "3_walidacja.js"),
    jesli(8, "Poprawne?", [2860, 300], "poprawne"),
    # Duplikat, poziom 2: ta sama faktura (NIP + numer z AI) w innym pliku
    code(18, "Duplikat faktury?", [3080, 200], "8_duplikat_faktury.js"),
    jesli(19, "Nowa faktura?", [3300, 200], "nowy"),
    code(9, "Zapisz wynik", [3520, 100], "4_zapisz_wynik.js"),
    code(20, "Duplikat", [3520, 560], "9_duplikat.js"),
    code(10, "Do sprawdzenia", [3080, 420], "5_do_sprawdzenia.js"),
]


def polacz(z, *do):
    return {z: {"main": [[{"node": d, "type": "main", "index": 0} for d in grupa] for grupa in do]}}


polaczenia = {}
for z, do in [
    ("Nowy plik w wejscie", "Tylko PDF"),
    ("Tylko PDF", "Plik do przetworzenia"),
    ("Od klienta (agent)", "Klient: token i zapis"),
    ("Klient: token i zapis", "Przyjęty?"),
    ("Plik do przetworzenia", "Duplikat pliku?"),
    ("Duplikat pliku?", "Nowy plik?"),
    ("Wczytaj PDF", "Tekst z PDF"),
    ("Tekst z PDF", "Jest tekst?"),
    ("OCR (skan)", "Przygotuj zapytanie"),
    ("Przygotuj zapytanie", "Ollama (lokalnie)"),
    ("Ollama (lokalnie)", "Walidacja"),
    ("Walidacja", "Poprawne?"),
    ("Duplikat faktury?", "Nowa faktura?"),
]:
    polaczenia.update(polacz(z, [do]))
# węzły IF: wyjście true / false
polaczenia.update(polacz("Przyjęty?", ["Plik do przetworzenia"], ["Odrzucono"]))
polaczenia.update(polacz("Nowy plik?", ["Wczytaj PDF"], ["Duplikat"]))
polaczenia.update(polacz("Jest tekst?", ["Przygotuj zapytanie"], ["OCR (skan)"]))
polaczenia.update(polacz("Poprawne?", ["Duplikat faktury?"], ["Do sprawdzenia"]))
polaczenia.update(polacz("Nowa faktura?", ["Zapisz wynik"], ["Duplikat"]))

workflow = {
    "id": ID_WORKFLOW,
    "name": "Faktury: PDF → Ollama → walidacja → wyniki",
    "nodes": wezly,
    "connections": polaczenia,
    "settings": {"executionOrder": "v1"},
    "active": False,
    "pinData": {},
    "meta": {"opis": "Workflow 1 z briefu v2. Generowany przez n8n/zbuduj_workflow.py – edytuj pliki w n8n/kod/."},
}

rejestracja = {
    "id": ID_REJESTRACJA,
    "name": "Rejestracja agentów: token dla zaufanych komputerów",
    "nodes": [
        wezel(1, "Prośba o token", "n8n-nodes-base.webhook", 2, [0, 300], {
            "httpMethod": "POST",
            "path": "rejestracja",
            "responseMode": "lastNode",
            "responseData": "firstEntryJson",
            "options": {},
        }, webhookId="00000000-0000-4000-8000-0000000000bb"),
        code(2, "Zaufany? Wydaj token", [220, 300], "6_rejestracja.js"),
    ],
    "connections": polacz("Prośba o token", ["Zaufany? Wydaj token"]),
    # bez zapisu danych udanych przebiegów – odpowiedź zawiera token, nie chcemy go w bazie n8n
    "settings": {"executionOrder": "v1", "saveDataSuccessExecution": "none"},
    "active": False,
    "pinData": {},
    "meta": {"opis": "Generowany przez n8n/zbuduj_workflow.py – edytuj n8n/kod/6_rejestracja.js."},
}

aktualizacja = {
    "id": ID_AKTUALIZACJA,
    "name": "Aktualizacje agenta: podpisane wersje dla zaufanych komputerów",
    "nodes": [
        wezel(1, "Prośba o aktualizację", "n8n-nodes-base.webhook", 2, [0, 300], {
            "httpMethod": "POST",
            "path": "aktualizacja",
            "responseMode": "lastNode",
            "responseData": "firstEntryJson",
            "options": {},
        }, webhookId="00000000-0000-4000-8000-0000000000cc"),
        code(2, "Token? Manifest lub plik", [220, 300], "10_aktualizacja.js"),
    ],
    "connections": polacz("Prośba o aktualizację", ["Token? Manifest lub plik"]),
    # bez zapisu danych udanych przebiegów – w nagłówkach jest token, w odpowiedziach treść plików
    "settings": {"executionOrder": "v1", "saveDataSuccessExecution": "none"},
    "active": False,
    "pinData": {},
    "meta": {"opis": "Generowany przez n8n/zbuduj_workflow.py – edytuj n8n/kod/10_aktualizacja.js."},
}



def graph(nr, nazwa, pozycja, metoda, url, **cialo):
    """Zapytanie do Microsoft Graph z poświadczeniem OAuth2; błąd → drugie wyjście (ponowienie z kolejki)."""
    return wezel(nr, nazwa, "n8n-nodes-base.httpRequest", 4.2, pozycja, {
        "method": metoda,
        "url": url,
        "authentication": "genericCredentialType",
        "genericAuthType": "oAuth2Api",
        **cialo,
        "options": {"timeout": 120000},
    }, credentials=M365_POSWIADCZENIE, onError="continueErrorOutput")


SITE = "'https://graph.microsoft.com/v1.0/sites/' + $('Witryna SharePoint').item.json.id"
ZAD = "$('Kolejka M365').item.json"
m365 = {
    "id": ID_M365,
    "name": "Synchronizacja M365: PDF do SharePointa, wiersz do Excela",
    "nodes": [
        wezel(1, "Co minutę", "n8n-nodes-base.scheduleTrigger", 1.2, [0, 300], {
            "rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]},
        }),
        code(2, "Kolejka M365", [220, 300], "11_m365_kolejka.js", na_kazdy_element=False),
        graph(3, "Witryna SharePoint", [440, 300], "GET",
              "={{ 'https://graph.microsoft.com/v1.0/sites/' + $json.m365.witryna }}"),
        wezel(4, "Wczytaj PDF", "n8n-nodes-base.readWriteFile", 1.1, [660, 300], {
            "operation": "read",
            "fileSelector": f"={{{{ {ZAD}.pdf }}}}",
            "options": {},
        }, onError="continueErrorOutput"),
        graph(5, "SharePoint: wyślij PDF", [880, 300], "PUT",
              f"={{{{ {SITE} + '/drive/root:/' + {ZAD}.m365.sciezkaUrl + ':/content' }}}}",
              sendBody=True, contentType="binaryData", inputDataFieldName="data"),
        graph(10, "Excel: tabele w pliku", [1100, 300], "GET",
              f"={{{{ {SITE} + '/drive/root:/' + {ZAD}.m365.excelUrl + ':/workbook/tables' }}}}"),
        dict(code(6, "Wiersz do Excela", [1320, 300], "12_m365_wiersz.js"), onError="continueErrorOutput"),
        graph(7, "Excel: dodaj wiersz", [1540, 300], "POST",
              f"={{{{ {SITE} + '/drive/root:/' + {ZAD}.m365.excelUrl + ':/workbook/tables/' + $json.tabelaUrl + '/rows/add' }}}}",
              sendBody=True, specifyBody="json", jsonBody="={{ JSON.stringify($json.cialo) }}"),
        code(8, "Wysłano", [1760, 300], "13_m365_wyslano.js"),
        code(9, "Błąd – ponowię później", [1320, 560], "14_m365_blad.js"),
    ],
    "connections": {},
    # bez zapisu udanych przebiegów (co minutę, zwykle pusta kolejka); błędy są zapisywane
    "settings": {"executionOrder": "v1", "saveDataSuccessExecution": "none", "saveManualExecutions": False},
    "active": False,
    "pinData": {},
    "meta": {"opis": "Generowany przez n8n/zbuduj_workflow.py – edytuj n8n/kod/11–14_m365_*.js."},
}
BLAD = "Błąd – ponowię później"
m365["connections"].update(polacz("Co minutę", ["Kolejka M365"]))
m365["connections"].update(polacz("Kolejka M365", ["Witryna SharePoint"]))
m365["connections"].update(polacz("Witryna SharePoint", ["Wczytaj PDF"], [BLAD]))
m365["connections"].update(polacz("Wczytaj PDF", ["SharePoint: wyślij PDF"], [BLAD]))
m365["connections"].update(polacz("SharePoint: wyślij PDF", ["Excel: tabele w pliku"], [BLAD]))
m365["connections"].update(polacz("Excel: tabele w pliku", ["Wiersz do Excela"], [BLAD]))
m365["connections"].update(polacz("Wiersz do Excela", ["Excel: dodaj wiersz"], [BLAD]))
m365["connections"].update(polacz("Excel: dodaj wiersz", ["Wysłano"], [BLAD]))

for plik, wf in (("workflow_faktury.json", workflow), ("workflow_rejestracja.json", rejestracja),
                 ("workflow_aktualizacja.json", aktualizacja), ("workflow_m365.json", m365)):
    wyjscie = KATALOG / plik
    wyjscie.write_text(json.dumps(wf, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"zapisano {wyjscie} ({len(wf['nodes'])} węzłów)")
(KATALOG / "wersja.txt").write_text(WERSJA, encoding="utf-8")
print(f"wersja: {WERSJA}")
