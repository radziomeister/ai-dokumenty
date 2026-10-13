// Wiersz do tabeli Excela – kolumny jak w wyniki/faktury.csv, w kolumnie „plik” klikalny link do PDF w SharePoincie.
const z = $('Kolejka M365').item.json;

// Tabela: nazwa z konfiguracji bez względu na wielkość liter, a gdy w pliku jest tylko jedna – ta jedna
const tabele = $('Excel: tabele w pliku').item.json.value ?? [];
const tabela = tabele.find((t) => t.name.toLowerCase() === z.m365.tabela.toLowerCase())
  ?? (tabele.length === 1 ? tabele[0] : null);
if (!tabela) {
  throw new Error(`W pliku ${z.m365.plikExcela} nie ma tabeli „${z.m365.tabela}”. `
    + `Tabele w pliku: ${tabele.map((t) => t.name).join(', ') || 'brak (wstaw tabelę: Wstaw → Tabela)'}`);
}
const link = $('SharePoint: wyślij PDF').item.json.webUrl ?? '';
// Klikalny link „PDF”. Formuła jest tu bezpieczna: adres pochodzi z odpowiedzi Microsoft Graph, nie z dokumentu.
// (Formuły przez Graph zapisuje się w składni angielskiej – HYPERLINK i przecinek.)
const linkPdf = /^https:\/\/[^"]+$/.test(link) ? `=HYPERLINK("${link}","PDF")` : '';
const w = z.wiersz;
// Tekst zaczynający się od = + - @ Excel potraktowałby jak formułę (Excel/CSV injection)
const tekst = (v) => {
  const s = v === null || v === undefined ? '' : String(v);
  return /^[=+\-@]/.test(s) ? "'" + s : s;
};

return {
  json: {
    tabelaUrl: encodeURIComponent(tabela.id),
    cialo: {
      values: [[
        w.przetworzono, linkPdf, tekst(w.numer_dokumentu), w.data_wystawienia, tekst(w.nip_sprzedawcy),
        tekst(w.kontrahent), w.kwota_netto, w.kwota_vat, w.kwota_brutto, w.waluta,
        tekst(w.ostrzezenia), tekst(w.zrodlo),
      ]],
    },
  },
};
