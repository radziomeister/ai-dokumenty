// Niepoprawna faktura: PDF i opis błędów do do_sprawdzenia/, wpis w _powiadomienia.log.
// Później: dodatkowo mail/Teams do osoby odpowiedzialnej.
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

const { sciezka, nazwa, klient, ip } = $json.zrodlo;
const zrodlo = klient ? `klient: ${klient}` : 'folder serwera';
const folder = path.join(BAZA, 'do_sprawdzenia');

const celPdf = wolnaNazwa(wFolderzeRoboczym(path.join(folder, nazwa)));
fs.renameSync(wFolderzeRoboczym(sciezka), celPdf);

const celJson = wolnaNazwa(wFolderzeRoboczym(path.join(folder, path.parse(nazwa).name + '.json')));
fs.writeFileSync(celJson, JSON.stringify({
  plik: path.relative(BAZA, celPdf),
  przetworzono: teraz,
  zrodlo,
  bledy: $json.bledy,
  ostrzezenia: $json.ostrzezenia,
  dane_od_modelu: $json.dane,
  odpowiedz_surowa: $json.odpowiedz_surowa,
  model: $json.model,
}, null, 2));

fs.appendFileSync(
  path.join(folder, '_powiadomienia.log'),
  `${teraz}  [${zrodlo}]  ${path.basename(celPdf)}  DO SPRAWDZENIA: ${$json.bledy.join(' | ')}\n`,
);

zapiszZdarzenie('do_sprawdzenia', { klient, ip, plik: nazwa, bledy: $json.bledy });

// Odpowiedź dla agenta klienta (webhook) – agent pokaże powiadomienie z powodami
return {
  json: {
    status: 'do_sprawdzenia',
    plik: nazwa,
    bledy: $json.bledy,
    ostrzezenia: $json.ostrzezenia,
  },
};
