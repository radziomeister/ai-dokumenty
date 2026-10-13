"""Lokalny serwis OCR dla n8n: PDF bez warstwy tekstowej (skan) → tekst.

    POST /ocr       treść żądania: plik PDF  →  {"text": "...", "ocr": true, "strony": n, "czas_s": x}
    GET  /zdrowie   →  {"ok": true}

Działa tylko w wewnętrznej sieci Dockera: bez portów na zewnątrz i bez dostępu do internetu
(docker-compose.yml, sieć „wewnetrzna”). Tesseract (polski + angielski), strony renderowane przez poppler.
Sama biblioteka standardowa Pythona – żadnych dodatkowych pakietów.
"""

import json
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAKS_ROZMIAR = 30 * 1024 * 1024   # 30 MB
MAKS_STRON = 20                   # faktura to zwykle 1–3 strony
DPI = 300                         # rozdzielczość renderowania stron do OCR
JEZYKI = "pol+eng"


def rozpoznaj(pdf: bytes) -> dict:
    start = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        katalog = Path(tmp)
        (katalog / "dokument.pdf").write_bytes(pdf)
        subprocess.run(
            ["pdftoppm", "-r", str(DPI), "-gray", "-png", "-l", str(MAKS_STRON),
             str(katalog / "dokument.pdf"), str(katalog / "strona")],
            check=True, capture_output=True, timeout=180,
        )
        strony = sorted(katalog.glob("strona-*.png"))
        teksty = []
        for strona in strony:
            wynik = subprocess.run(["tesseract", str(strona), "stdout", "-l", JEZYKI],
                                   check=True, capture_output=True, text=True, timeout=180)
            teksty.append(wynik.stdout.strip())
    return {"text": "\n\n".join(teksty).strip(), "ocr": True, "strony": len(strony),
            "czas_s": round(time.time() - start, 1)}


class Obsluga(BaseHTTPRequestHandler):
    server_version = "AI-Faktury-OCR"

    def _odpowiedz(self, kod: int, dane: dict) -> None:
        tresc = json.dumps(dane, ensure_ascii=False).encode("utf-8")
        self.send_response(kod)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(tresc)))
        self.end_headers()
        self.wfile.write(tresc)

    def do_GET(self) -> None:
        if self.path == "/zdrowie":
            return self._odpowiedz(200, {"ok": True})
        self._odpowiedz(404, {"blad": "nieznany adres"})

    def do_POST(self) -> None:
        if self.path != "/ocr":
            return self._odpowiedz(404, {"blad": "nieznany adres"})
        dlugosc = int(self.headers.get("Content-Length") or 0)
        if not 0 < dlugosc <= MAKS_ROZMIAR:
            return self._odpowiedz(413, {"blad": f"plik pusty albo większy niż {MAKS_ROZMIAR // 1024 // 1024} MB"})
        pdf = self.rfile.read(dlugosc)
        if not pdf.startswith(b"%PDF-"):
            return self._odpowiedz(400, {"blad": "to nie jest plik PDF"})
        try:
            self._odpowiedz(200, rozpoznaj(pdf))
        except subprocess.TimeoutExpired:
            self._odpowiedz(504, {"blad": "przekroczony czas OCR"})
        except subprocess.CalledProcessError as e:
            self._odpowiedz(500, {"blad": f"OCR nie powiódł się: {(e.stderr or b'')[:300]!r}"})


if __name__ == "__main__":
    print("Serwis OCR nasłuchuje na :8080 (tylko sieć wewnętrzna Dockera)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Obsluga).serve_forever()
