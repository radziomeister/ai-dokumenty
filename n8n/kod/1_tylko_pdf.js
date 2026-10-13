// Przepuszcza dalej tylko pliki PDF. Inne pliki odkłada do do_sprawdzenia/.
const fs = require('fs');
const path = require('path');

const BAZA = '/home/node/praca';
const wFolderzeRoboczym = (p) => {
  const r = path.resolve(p);
  if (!r.startsWith(BAZA + '/')) throw new Error('Ścieżka poza folderem roboczym: ' + r);
  return r;
};
const teraz = () => new Date().toLocaleString('sv-SE', { timeZone: 'Europe/Warsaw' });

const wynik = [];
for (const item of $input.all()) {
  const sciezka = wFolderzeRoboczym(item.json.path);
  const nazwa = path.basename(sciezka);

  if (/\.pdf$/i.test(nazwa)) {
    zapiszZdarzenie('plik_przyjety', { klient: null, ip: null, plik: nazwa, zrodlo: 'folder serwera' });
    wynik.push({ json: { sciezka, nazwa, klient: null, ip: null } }); // wrzucony na serwerze, bez agenta
    continue;
  }

  // Nie-PDF: odłóż do sprawdzenia, żeby nie zalegał w wejscie/
  const cel = wFolderzeRoboczym(path.join(BAZA, 'do_sprawdzenia', nazwa));
  if (fs.existsSync(sciezka) && !fs.existsSync(cel)) fs.renameSync(sciezka, cel);
  fs.appendFileSync(
    path.join(BAZA, 'do_sprawdzenia', '_powiadomienia.log'),
    `${teraz()}  ${nazwa}  pominięty – to nie jest PDF\n`,
  );
  zapiszZdarzenie('pominieto_nie_pdf', { klient: null, ip: null, plik: nazwa, zrodlo: 'folder serwera' });
}
return wynik;
