// Plik od agenta na komputerze klienta (webhook):
// 1. token klienta ważny I wysłany z adresu IP, dla którego go wydano,
// 2. czy to naprawdę PDF (sygnatura pliku, nie rozszerzenie),
// 3. zapis do wejscie/_klienci/<klient>/ i dalej ta sama ścieżka co pliki z folderu.
// Odrzucone żądania nie idą dalej: agent dostaje powód, próba trafia do dziennika bezpieczeństwa.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const BAZA = '/home/node/praca';
const KLIENCI = '/home/node/klienci/klienci.json';
// Odczyt z ponowieniem: plik zmieniany po stronie macOS bywa przez chwilę widoczny niekompletnie
const czytajKlientow = () => {
  for (let proba = 1; ; proba++) {
    try {
      return fs.existsSync(KLIENCI) && fs.statSync(KLIENCI).size ? JSON.parse(fs.readFileSync(KLIENCI, 'utf8')) : {};
    } catch (e) {
      if (proba >= 5) throw e;
      const koniec = Date.now() + 200; while (Date.now() < koniec) { /* krótka pauza */ }
    }
  }
};
const klienci = czytajKlientow();

const znajdzKlienta = (token) => {
  if (!token) return null;
  const skrot = crypto.createHash('sha256').update(token).digest();
  // porównanie w stałym czasie – nie zdradza, ile znaków tokenu się zgadza
  return Object.keys(klienci).find((k) => crypto.timingSafeEqual(Buffer.from(klienci[k].skrot, 'hex'), skrot)) ?? null;
};

const teraz = new Date().toLocaleString('sv-SE', { timeZone: 'Europe/Warsaw' });
// kod – krótki identyfikator dla administratora, powod – tekst dla użytkownika (agent pokazuje go w oknie błędu)
const odrzuc = (ip, klient, kod, powod) => {
  fs.appendFileSync('/home/node/klienci/odrzucone.log', JSON.stringify({ czas: teraz, ip, klient, kod, powod }) + '\n');
  zapiszZdarzenie('wysylka_odrzucona', { klient, ip, kod, powod });
  return { json: { przyjety: false, status: 'odrzucono', kod, powod, ip } };
};

const wynik = [];
const elementy = $input.all();
for (let i = 0; i < elementy.length; i++) {
  const { json, binary } = elementy[i];
  const naglowki = json.headers ?? {};
  const ip = String(naglowki['x-forwarded-for'] ?? '').split(',')[0].trim().replace(/^::ffff:/, '');

  const klient = znajdzKlienta(String(naglowki['x-klient-token'] ?? ''));
  if (!klient) {
    wynik.push(odrzuc(ip, null, 'NIEZAUFANY',
      'Ten komputer nie jest na liście zaufanych komputerów serwera AI albo jego dostęp został cofnięty.'));
    continue;
  }
  if (klienci[klient].ip !== ip) {
    wynik.push(odrzuc(ip, klient, 'INNY_ADRES_IP',
      'Ten komputer ma teraz inny adres IP niż ten, dla którego serwer AI wydał mu dostęp.'));
    continue;
  }

  const klucz = Object.keys(binary ?? {})[0];
  const dane = klucz ? await this.helpers.getBinaryDataBuffer(i, klucz) : Buffer.alloc(0);
  if (dane.subarray(0, 5).toString('latin1') !== '%PDF-') {
    wynik.push(odrzuc(ip, klient, 'NIE_PDF', 'Plik nie jest dokumentem PDF (sama zmiana rozszerzenia nie wystarczy).'));
    continue;
  }

  let nazwa = 'dokument.pdf';
  try { nazwa = decodeURIComponent(String(naglowki['x-nazwa-pliku'] ?? nazwa)); } catch (e) { /* zostaje domyślna */ }
  nazwa = path.basename(nazwa).replace(/[^\p{L}\p{N} ._()-]/gu, '_').slice(0, 120) || 'dokument.pdf';
  if (!/\.pdf$/i.test(nazwa)) nazwa += '.pdf';

  const folder = path.join(BAZA, 'wejscie', '_klienci', klient);
  fs.mkdirSync(folder, { recursive: true });
  let cel = path.join(folder, nazwa);
  if (fs.existsSync(cel)) {
    const { name, ext } = path.parse(nazwa);
    cel = path.join(folder, `${name}_${Date.now()}${ext}`);
  }
  fs.writeFileSync(cel, dane);

  zapiszZdarzenie('plik_przyjety', { klient, ip, plik: path.basename(cel), rozmiar_kb: Math.round(dane.length / 1024) });
  wynik.push({ json: { przyjety: true, sciezka: cel, nazwa: path.basename(cel), klient, ip } });
}
return wynik;
