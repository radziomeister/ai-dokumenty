// Zadanie wykonane: PDF w SharePoincie, wiersz w Excelu → zadanie do m365_kolejka/wyslane/.
const fs = require('fs');
const path = require('path');

const z = $('Kolejka M365').item.json;
const link = $('SharePoint: wyślij PDF').item.json.webUrl ?? null;
const { m365, plik_zadania, ...dane } = z;

const cel = path.join(path.dirname(plik_zadania), 'wyslane');
fs.mkdirSync(cel, { recursive: true });
fs.writeFileSync(path.join(cel, path.basename(plik_zadania)),
  JSON.stringify({ ...dane, wyslano: czasTeraz(), link_sharepoint: link }, null, 2));
fs.unlinkSync(plik_zadania);

zapiszZdarzenie('m365_zapisano', {
  klient: z.klient, ip: z.ip, plik: z.nazwa_pdf, numer_dokumentu: z.wiersz.numer_dokumentu,
  link, proba: (z.proby ?? 0) + 1,
});
return { json: { status: 'ok', plik: z.nazwa_pdf, link } };
