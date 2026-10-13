// Poprawna faktura: wiersz w wyniki/faktury.csv, JSON w wyniki/, PDF do przetworzone/RRRR/MM/.
// Później: zamiast CSV węzeł Microsoft Excel 365 (OneDrive), PDF dodatkowo do SharePointa.
const fs = require('fs');
const path = require('path');

const BAZA = '/home/node/praca';
const wFolderzeRoboczym = (p) => {
  const r = path.resolve(p);
  if (!r.startsWith(BAZA + '/')) throw new Error('Ścieżka poza folderem roboczym: ' + r);
  return r;
};
const wolnaNazwa = (p) => {
  if (!fs.existsSync(p)) return p;
  const { dir, name, ext } = path.parse(p);
  return path.join(dir, `${name}_${Date.now()}${ext}`);
};
const teraz = new Date().toLocaleString('sv-SE', { timeZone: 'Europe/Warsaw' });

const d = $json.dane;
const { sciezka, nazwa, klient, ip, sha256 } = $json.zrodlo;
const zrodlo = klient ? `klient: ${klient}` : 'folder serwera';

// 1. PDF → przetworzone/RRRR/MM/
const [rok, miesiac] = d.data_wystawienia.split('-');
const celPdf = wolnaNazwa(wFolderzeRoboczym(path.join(BAZA, 'przetworzone', rok, miesiac, nazwa)));
fs.mkdirSync(path.dirname(celPdf), { recursive: true });
fs.renameSync(wFolderzeRoboczym(sciezka), celPdf);

// 2. Pełny wynik jako JSON
const celJson = wolnaNazwa(wFolderzeRoboczym(path.join(BAZA, 'wyniki', path.parse(nazwa).name + '.json')));
fs.writeFileSync(celJson, JSON.stringify({
  ...d,
  plik: path.relative(BAZA, celPdf),
  przetworzono: teraz,
  zrodlo,
  model: $json.model,
  ostrzezenia: $json.ostrzezenia,
}, null, 2));

// 3. Wiersz w CSV (separator ";", przecinek dziesiętny i BOM – tak, jak oczekuje polski Excel)
const csv = path.join(BAZA, 'wyniki', 'faktury.csv');
const NAGLOWEK = ['przetworzono', 'plik', 'numer_dokumentu', 'data_wystawienia', 'nip_sprzedawcy',
  'kontrahent', 'kwota_netto', 'kwota_vat', 'kwota_brutto', 'waluta', 'ostrzezenia', 'zrodlo'];
const pole = (v) => {
  let s = v === null || v === undefined ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;            // ochrona przed formułami w Excelu (CSV injection)
  if (/[;"\r\n]/.test(s)) s = '"' + s.replace(/"/g, '""') + '"';
  return s;
};
const kwota = (x) => x.toFixed(2).replace('.', ',');
if (!fs.existsSync(csv)) fs.writeFileSync(csv, '﻿' + NAGLOWEK.join(';') + '\r\n');
fs.appendFileSync(csv, [
  teraz, path.relative(BAZA, celPdf), d.numer_dokumentu, d.data_wystawienia, d.nip_sprzedawcy,
  d.kontrahent, kwota(d.kwota_netto), kwota(d.kwota_vat), kwota(d.kwota_brutto), d.waluta,
  $json.ostrzezenia.join(' | '), zrodlo,
].map(pole).join(';') + '\r\n');

// 4. Rejestr zapisanych dokumentów – podstawa wykrywania duplikatów (plik i faktura)
fs.appendFileSync(REJESTR, JSON.stringify({
  sha256, numer_dokumentu: d.numer_dokumentu, nip_sprzedawcy: d.nip_sprzedawcy, kontrahent: d.kontrahent,
  plik: path.relative(BAZA, celPdf), przetworzono: teraz, zrodlo,
}) + '\n');
zapiszZdarzenie('zapisano', {
  klient, ip, plik: nazwa, numer_dokumentu: d.numer_dokumentu, kontrahent: d.kontrahent,
  kwota_brutto: d.kwota_brutto, waluta: d.waluta, ostrzezenia: $json.ostrzezenia,
});

// 5. Zadanie dla Microsoft 365 – wysyła je workflow „Synchronizacja M365” (co minutę, z ponowieniami).
//    Agent nie czeka na Microsoft, a brak internetu nie blokuje zapisu lokalnego.
const KOLEJKA = path.join(BAZA, 'm365_kolejka');
fs.mkdirSync(KOLEJKA, { recursive: true });
const zadanie = {
  utworzono: teraz, pdf: celPdf, nazwa_pdf: path.basename(celPdf), rok, miesiac, klient, ip, proby: 0,
  wiersz: {
    przetworzono: teraz, numer_dokumentu: d.numer_dokumentu, data_wystawienia: d.data_wystawienia,
    nip_sprzedawcy: d.nip_sprzedawcy, kontrahent: d.kontrahent, kwota_netto: d.kwota_netto, kwota_vat: d.kwota_vat,
    kwota_brutto: d.kwota_brutto, waluta: d.waluta, ostrzezenia: $json.ostrzezenia.join(' | '), zrodlo,
  },
};
const plikZadania = path.join(KOLEJKA, `${Date.now()}_${path.parse(celPdf).name}.json`);
fs.writeFileSync(plikZadania + '.tmp', JSON.stringify(zadanie, null, 2));
fs.renameSync(plikZadania + '.tmp', plikZadania);

// Odpowiedź dla agenta klienta (webhook) – treść powiadomienia
return {
  json: {
    status: 'zapisano',
    plik: nazwa,
    numer_dokumentu: d.numer_dokumentu,
    kontrahent: d.kontrahent,
    kwota_brutto: d.kwota_brutto,
    waluta: d.waluta,
    ostrzezenia: $json.ostrzezenia,
  },
};
