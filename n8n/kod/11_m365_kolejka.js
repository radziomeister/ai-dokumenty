// Kolejka wysyłek do Microsoft 365. Zadania tworzy „Zapisz wynik” (workflow Faktury):
// BACKUP2/m365_kolejka/*.json → PDF do SharePointa + wiersz w tabeli Excela.
// Ponowienia z rosnącą przerwą: po n-tej nieudanej próbie zadanie czeka n minut (maks. 30).
const fs = require('fs');
const path = require('path');

const KOLEJKA = '/home/node/praca/m365_kolejka';
const M365 = {
  witryna: 'aifaktury.sharepoint.com:/sites/FakturyAI',   // host:/ścieżka witryny SharePoint
  plikExcela: 'Faktury AI.xlsx',                          // w bibliotece „Dokumenty” witryny
  tabela: 'Faktury',                                      // nazwa tabeli (wielkość liter bez znaczenia)
  folder: 'Faktury',                                      // oryginały: Faktury/RRRR/MM/
};
const MAKS_NA_RAZ = 10;

if (!fs.existsSync(KOLEJKA)) return [];
const teraz = Date.now();
const zadania = [];
for (const nazwa of fs.readdirSync(KOLEJKA).filter((n) => n.endsWith('.json')).sort()) {
  const plik = path.join(KOLEJKA, nazwa);
  let z;
  try { z = JSON.parse(fs.readFileSync(plik, 'utf8')); } catch (e) { continue; }
  if (z.proby && teraz - (z.ostatnia_proba_ms ?? 0) < Math.min(z.proby, 30) * 60000) continue;

  zadania.push({
    json: {
      ...z,
      plik_zadania: plik,
      m365: {
        ...M365,
        sciezkaUrl: [M365.folder, z.rok, z.miesiac, z.nazwa_pdf].map(encodeURIComponent).join('/'),
        excelUrl: encodeURIComponent(M365.plikExcela),
      },
    },
  });
  if (zadania.length >= MAKS_NA_RAZ) break;
}
return zadania;
