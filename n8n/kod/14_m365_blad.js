// Nieudana wysyłka do Microsoft 365 (brak internetu, wygasłe logowanie, zły adres…):
// zadanie zostaje w kolejce z licznikiem prób; po 20 próbach → m365_kolejka/bledy/ + powiadomienie.
const fs = require('fs');
const path = require('path');

const MAKS_PROB = 20;
const z = $('Kolejka M365').item.json;
const blad = [$json.error?.message, $json.error?.description].filter(Boolean).join(' – ').slice(0, 500)
  || JSON.stringify($json).slice(0, 300);
const krok = $prevNode?.name ?? '?';   // który krok się nie udał (witryna, PDF, wysyłka, Excel)
const proby = (z.proby ?? 0) + 1;
const { m365, plik_zadania, ...dane } = z;
const nowe = { ...dane, proby, ostatni_krok: krok, ostatni_blad: blad, ostatnia_proba: czasTeraz(), ostatnia_proba_ms: Date.now() };

if (proby >= MAKS_PROB) {
  const cel = path.join(path.dirname(plik_zadania), 'bledy');
  fs.mkdirSync(cel, { recursive: true });
  fs.writeFileSync(path.join(cel, path.basename(plik_zadania)), JSON.stringify(nowe, null, 2));
  fs.unlinkSync(plik_zadania);
  fs.appendFileSync('/home/node/praca/do_sprawdzenia/_powiadomienia.log',
    `${czasTeraz()}  ${z.nazwa_pdf}  M365: nie udało się wysłać po ${proby} próbach – ${blad}\n`);
  zapiszZdarzenie('m365_porzucono', { klient: z.klient, ip: z.ip, plik: z.nazwa_pdf, proby, krok, blad });
} else {
  fs.writeFileSync(plik_zadania + '.tmp', JSON.stringify(nowe, null, 2));
  fs.renameSync(plik_zadania + '.tmp', plik_zadania);
  zapiszZdarzenie('m365_blad', { klient: z.klient, ip: z.ip, plik: z.nazwa_pdf, proby, krok, blad });
}
return { json: { status: 'blad', plik: z.nazwa_pdf, proby, blad } };
