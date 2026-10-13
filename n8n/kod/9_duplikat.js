// Duplikat (z poziomu 1 lub 2): nic nie zapisujemy drugi raz.
// PDF → duplikaty/ (z opisem, do czego jest podobny), wpis w _powiadomienia.log i w dzienniku,
// odpowiedź dla agenta: „odrzucono / DUPLIKAT” → plik trafia u klienta do „Nie wysłane” + okno z informacją.
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
const teraz = czasTeraz();

// Wejście z poziomu 1: { sciezka, nazwa, klient, ip, ... }; z poziomu 2: { zrodlo: {...}, dane, ... }
const zr = $json.zrodlo ?? $json;
const p = $json.duplikat;
const zrodlo = zr.klient ? `klient: ${zr.klient}` : 'folder serwera';

const folder = path.join(BAZA, 'duplikaty');
fs.mkdirSync(folder, { recursive: true });
const celPdf = wolnaNazwa(wFolderzeRoboczym(path.join(folder, zr.nazwa)));
fs.renameSync(wFolderzeRoboczym(zr.sciezka), celPdf);
fs.writeFileSync(celPdf.replace(/\.pdf$/i, '') + '.json', JSON.stringify({
  plik: path.relative(BAZA, celPdf), przetworzono: teraz, zrodlo, rodzaj: p.rodzaj, wczesniej_zapisany: p,
}, null, 2));

fs.appendFileSync(
  path.join(BAZA, 'do_sprawdzenia', '_powiadomienia.log'),
  `${teraz}  [${zrodlo}]  ${zr.nazwa}  DUPLIKAT (${p.rodzaj}) – zapisany już ${p.przetworzono} jako ${p.plik} [${p.zrodlo}]\n`,
);
zapiszZdarzenie('duplikat', {
  klient: zr.klient ?? null, ip: zr.ip ?? null, plik: zr.nazwa, rodzaj: p.rodzaj,
  wczesniej: { plik: p.plik, przetworzono: p.przetworzono, zrodlo: p.zrodlo },
});

const opis = [p.numer_dokumentu && `faktura nr ${p.numer_dokumentu}`, p.kontrahent && `od ${p.kontrahent}`]
  .filter(Boolean).join(' ') || 'dokument';
return {
  json: {
    status: 'odrzucono',
    kod: 'DUPLIKAT',
    powod: `Ten dokument został już wcześniej dodany: ${opis} (${p.rodzaj}), zapisany ${p.przetworzono}, `
      + `źródło: ${p.zrodlo}. Nie zapisano go drugi raz.`,
    ip: zr.ip ?? null,
    plik: zr.nazwa,
  },
};
