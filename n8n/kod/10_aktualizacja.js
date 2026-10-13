// Aktualizacje agenta (klient/aktualizacja.ps1). Tylko zaufany komputer z ważnym tokenem
// wysłanym z adresu IP, dla którego token wydano.
//   body {}                 → podpisany manifest (wersja, zmiany, pliki + SHA-256)
//   body { plik: "nazwa" }  → treść pliku z OPUBLIKOWANEJ wersji (base64); nazwa musi być w manifeście
// Publikacja nowej wersji: python3 klient/publikuj.py (podpis kluczem z sekrety/podpis/).
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DYSTRYBUCJA = '/home/node/dystrybucja';
const KLIENCI = '/home/node/klienci/klienci.json';

const czytajJson = (p) => {
  for (let proba = 1; ; proba++) {
    try {
      return fs.existsSync(p) && fs.statSync(p).size ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
    } catch (e) {
      if (proba >= 5) throw e;
      const koniec = Date.now() + 200; while (Date.now() < koniec) { /* krótka pauza */ }
    }
  }
};

const naglowki = $json.headers ?? {};
const ip = String(naglowki['x-forwarded-for'] ?? '').split(',')[0].trim().replace(/^::ffff:/, '');
const token = String(naglowki['x-klient-token'] ?? '');
const klienci = czytajJson(KLIENCI);
const skrot = crypto.createHash('sha256').update(token).digest();
const klient = token
  ? Object.keys(klienci).find((k) => crypto.timingSafeEqual(Buffer.from(klienci[k].skrot, 'hex'), skrot)) ?? null
  : null;

const odmowa = (kod, powod) => {
  zapiszZdarzenie('aktualizacja_odrzucona', { klient, ip, kod, powod });
  return { json: { status: 'odrzucono', kod, powod } };
};
if (!klient) return odmowa('NIEZAUFANY', 'Ten komputer nie ma ważnego tokenu – uruchom token.ps1 albo zgłoś się do administratora.');
if (klienci[klient].ip !== ip) return odmowa('INNY_ADRES_IP', 'Token tego komputera wydano dla innego adresu IP.');

const publikacja = czytajJson(path.join(DYSTRYBUCJA, 'aktualizacja.json'));
if (!publikacja.manifest_b64) return odmowa('BRAK_WERSJI', 'Na serwerze nie opublikowano jeszcze żadnej wersji agenta.');
const manifest = JSON.parse(Buffer.from(publikacja.manifest_b64, 'base64').toString('utf8'));

const zadanyPlik = $json.body?.plik;
if (!zadanyPlik) {
  zapiszZdarzenie('aktualizacja_sprawdzenie', { klient, ip, wersja: manifest.wersja });
  return { json: { status: 'ok', wersja: manifest.wersja, manifest_b64: publikacja.manifest_b64, podpis: publikacja.podpis } };
}

// Tylko pliki wymienione w podpisanym manifeście – nazwa z manifestu, nie od klienta (brak ścieżek typu ../)
const wpis = manifest.pliki.find((p) => p.nazwa === zadanyPlik);
if (!wpis) return odmowa('NIEZNANY_PLIK', 'Tego pliku nie ma w opublikowanej wersji.');
const tresc = fs.readFileSync(path.join(DYSTRYBUCJA, 'pliki', manifest.wersja, path.basename(wpis.nazwa)));
zapiszZdarzenie('aktualizacja_pobranie', { klient, ip, plik: wpis.nazwa, wersja: manifest.wersja });
return { json: { status: 'ok', plik: wpis.nazwa, sha256: wpis.sha256, tresc_b64: tresc.toString('base64') } };
