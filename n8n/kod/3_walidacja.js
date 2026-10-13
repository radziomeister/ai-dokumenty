// Walidacja odpowiedzi modelu – nic nie jest zapisywane, dopóki ten krok nie przejdzie.
// Komunikaty błędów celowo nie zawierają wartości z dokumentu (trafiają do logu powiadomień).
const wej = $('Przygotuj zapytanie').item.json;
const tekst = wej.tekst || '';
const bledy = [];
const ostrzezenia = [];

// Pola, które zwraca model (schemat w "Przygotuj zapytanie")
const POLA_MODELU = Object.keys(wej.zapytanie.format.properties);
// Pola wyniku z briefu – tylko one trafiają do CSV/Excela
const POLA = [
  'numer_dokumentu', 'data_wystawienia', 'nip_sprzedawcy', 'kontrahent',
  'kwota_netto', 'kwota_vat', 'kwota_brutto', 'waluta',
];
const WALUTY = ['PLN', 'EUR', 'USD', 'GBP', 'CHF', 'CZK', 'SEK', 'NOK', 'DKK', 'HUF'];

// --- 1. Czy model w ogóle odpowiedział poprawnym JSON-em -------------------------------
let odp = null;
if ($json.error) {
  bledy.push('Brak odpowiedzi z Ollamy (serwer wyłączony lub przekroczony czas)');
} else {
  try {
    odp = JSON.parse($json.message?.content ?? '');
  } catch (e) {
    bledy.push('Odpowiedź modelu nie jest poprawnym JSON');
  }
  if (odp !== null && (typeof odp !== 'object' || Array.isArray(odp))) {
    bledy.push('Odpowiedź modelu nie jest obiektem JSON');
    odp = null;
  }
}

let dane = null;
if (odp) {
  const nadmiarowe = Object.keys(odp).filter((k) => !POLA_MODELU.includes(k));
  if (nadmiarowe.length) bledy.push('Nieoczekiwane pola w odpowiedzi: ' + nadmiarowe.join(', '));

  // Strony faktury: sprzedawca i nabywca nie mogą być tym samym podmiotem
  const norm = (s) => String(s ?? '').toLowerCase().replace(/[^a-z0-9ąćęłńóśźż]/g, '');
  if (odp.sprzedawca_nip && odp.sprzedawca_nip === odp.nabywca_nip) {
    bledy.push('NIP sprzedawcy i nabywcy są takie same – model mógł pomylić strony faktury');
  }
  if (odp.sprzedawca_nazwa && norm(odp.sprzedawca_nazwa) === norm(odp.nabywca_nazwa)) {
    bledy.push('Nazwa sprzedawcy i nabywcy są takie same – model mógł pomylić strony faktury');
  }

  // Typowe pomyłki OCR / zapisu w formie prawnej: „Sp. z 0.0.”, „Sp.z o.o”, „Sp z oo” → „Sp. z o.o.”
  const formaPrawna = (s) => (typeof s === 'string'
    ? s.replace(/\bsp\.?\s*z\s*[o0]\s*\.?\s*[o0]\b\.?/gi, 'Sp. z o.o.').replace(/\s{2,}/g, ' ').trim()
    : s);

  dane = {
    numer_dokumentu: odp.numer_dokumentu,
    data_wystawienia: odp.data_wystawienia,
    nip_sprzedawcy: odp.sprzedawca_nip,
    kontrahent: formaPrawna(odp.sprzedawca_nazwa),
    kwota_netto: odp.kwota_netto,
    kwota_vat: odp.kwota_vat,
    kwota_brutto: odp.kwota_brutto,
    waluta: odp.waluta,
  };
}

if (tekst.trim().length < 50) {
  bledy.push(wej.ocr ? 'Skan nieczytelny – OCR nie odczytał tekstu (słaba jakość, zdjęcie zamiast skanu?)'
    : 'PDF bez tekstu, a OCR był niedostępny – spróbuj ponownie później');
}
if (wej.ocr) ostrzezenia.push('Dane odczytane ze skanu (OCR) – porównaj z oryginałem');
if (wej.przyciety) ostrzezenia.push('Długi dokument – do modelu trafił tylko początek tekstu');

// --- 2. Tekst wyglądający na instrukcję dla AI (prompt injection) -----------------------
const PODEJRZANE = [
  /zignoruj\s+(wszystkie\s+)?(wcze[sś]niejsze|poprzednie|powy[zż]sze)/i,
  /ignore\s+(all\s+)?(previous|prior|above)/i,
  /instrukcj\w*\s+dla\s+(systemu|modelu|ai|asystenta|sztucznej)/i,
  /system\s*prompt/i,
  /jeste[sś]\s+teraz/i,
  /you\s+are\s+now/i,
];
if (PODEJRZANE.some((r) => r.test(tekst))) {
  bledy.push('Dokument zawiera tekst wyglądający na instrukcję dla AI (możliwy prompt injection) – sprawdź ręcznie');
}

// --- Pomocnicze: co faktycznie jest w tekście dokumentu ---------------------------------
// Wszystkie kwoty z tekstu w groszach: "1 234,56", "1.234,56", "1234.56", "1234"
const kwotyWTekscie = new Set();
for (const m of tekst.matchAll(/\d{1,3}(?:[  .]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?/g)) {
  const s = m[0].replace(/[  ]/g, '');
  const dziesietne = s.match(/[.,](\d{1,2})$/);
  const calosc = (dziesietne ? s.slice(0, -dziesietne[0].length) : s).replace(/[.,]/g, '');
  const grosze = Number(calosc) * 100 + (dziesietne ? Number(dziesietne[1].padEnd(2, '0')) : 0);
  if (Number.isFinite(grosze)) kwotyWTekscie.add(grosze);
}
// NIP-y z tekstu: 123-456-78-90, 123-45-67-890, 1234567890, z prefiksem PL lub bez
const nipyWTekscie = new Set(
  [...tekst.matchAll(/(?<!\d)(\d{3}[-\s]?\d{3}[-\s]?\d{2}[-\s]?\d{2}|\d{3}[-\s]?\d{2}[-\s]?\d{2}[-\s]?\d{3})(?!\d)/g)]
    .map((m) => m[1].replace(/\D/g, '')),
);
const bezSpacji = (s) => String(s).replace(/\s+/g, '').toLowerCase();
const tekstBezSpacji = bezSpacji(tekst);

const nipPoprawny = (nip) => {
  const w = [6, 5, 7, 2, 3, 4, 5, 6, 7];
  const suma = w.reduce((acc, waga, i) => acc + waga * Number(nip[i]), 0);
  return suma % 11 === Number(nip[9]);
};

// --- 3. Pola, typy, formaty, zgodność z dokumentem --------------------------------------
if (dane) {
  for (const p of POLA) {
    if (dane[p] === null || dane[p] === undefined || dane[p] === '') bledy.push('Brak pola: ' + p);
  }

  // numer dokumentu
  const numer = dane.numer_dokumentu;
  if (typeof numer === 'string' && numer) {
    if (numer.length > 60) bledy.push('Numer dokumentu podejrzanie długi');
    else if (!tekstBezSpacji.includes(bezSpacji(numer))) bledy.push('Numer dokumentu nie występuje w treści PDF');
  }

  // data wystawienia
  const data = dane.data_wystawienia;
  if (typeof data === 'string' && data) {
    const d = new Date(data + 'T00:00:00Z');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(data) || isNaN(d) || d.toISOString().slice(0, 10) !== data) {
      bledy.push('Data wystawienia w złym formacie (wymagane RRRR-MM-DD)');
    } else {
      if (d > new Date(Date.now() + 86400000)) bledy.push('Data wystawienia z przyszłości');
      if (d.getUTCFullYear() < 2000) bledy.push('Data wystawienia sprzed 2000 r.');
      const [r, m, dz] = data.split('-');
      const warianty = [data, `${dz}.${m}.${r}`, `${dz}-${m}-${r}`, `${dz}/${m}/${r}`, `${r}.${m}.${dz}`, `${r}/${m}/${dz}`];
      if (!warianty.some((w) => tekst.includes(w))) ostrzezenia.push('Nie znaleziono daty w typowym zapisie w treści PDF');
    }
  }

  // NIP sprzedawcy
  const nip = dane.nip_sprzedawcy;
  if (typeof nip === 'string' && nip) {
    if (!/^\d{10}$/.test(nip)) bledy.push('NIP sprzedawcy musi mieć dokładnie 10 cyfr');
    else if (!nipPoprawny(nip)) bledy.push('NIP sprzedawcy ma błędną sumę kontrolną');
    else if (!nipyWTekscie.has(nip)) bledy.push('NIP sprzedawcy nie występuje w treści PDF');
  }

  // kontrahent
  const kontrahent = dane.kontrahent;
  if (typeof kontrahent === 'string' && kontrahent) {
    if (kontrahent.length < 2 || kontrahent.length > 200) bledy.push('Nazwa kontrahenta ma nietypową długość');
    const poczatek = bezSpacji(kontrahent).slice(0, 8);
    if (!tekstBezSpacji.includes(poczatek)) ostrzezenia.push('Nazwa kontrahenta nie występuje dosłownie w treści PDF');
  }

  // kwoty
  const kwoty = { kwota_netto: dane.kwota_netto, kwota_vat: dane.kwota_vat, kwota_brutto: dane.kwota_brutto };
  let kwotyOk = true;
  for (const [pole, x] of Object.entries(kwoty)) {
    if (x === null || x === undefined) { kwotyOk = false; continue; }
    if (typeof x !== 'number' || !Number.isFinite(x)) { bledy.push(`${pole}: to nie jest liczba`); kwotyOk = false; continue; }
    if (x < 0) ostrzezenia.push(`${pole}: wartość ujemna (korekta?)`);
    if (Math.abs(x * 100 - Math.round(x * 100)) > 1e-6) bledy.push(`${pole}: więcej niż 2 miejsca po przecinku`);
    const wTekscie = kwotyWTekscie.has(Math.round(Math.abs(x) * 100));
    if (!wTekscie) {
      if (pole === 'kwota_vat' && x === 0) ostrzezenia.push('VAT = 0 (zwolnienie lub odwrotne obciążenie?)');
      else bledy.push(`${pole}: kwota nie występuje w treści PDF`);
    }
  }
  if (kwotyOk && Math.abs(kwoty.kwota_netto + kwoty.kwota_vat - kwoty.kwota_brutto) > 0.05) {
    bledy.push('Netto + VAT nie równa się brutto');
  }
  if (kwotyOk && kwoty.kwota_brutto > 10000000) ostrzezenia.push('Bardzo wysoka kwota brutto');

  // waluta
  const waluta = dane.waluta;
  if (typeof waluta === 'string' && waluta) {
    if (!WALUTY.includes(waluta)) bledy.push('Nieobsługiwany kod waluty');
    else if (!(tekst.includes(waluta) || (waluta === 'PLN' && /zł/i.test(tekst)))) {
      ostrzezenia.push('Kod waluty nie występuje w treści PDF');
    }
  }
}

return {
  json: {
    poprawne: bledy.length === 0,
    bledy,
    ostrzezenia,
    dane,
    nabywca: odp ? { nazwa: odp.nabywca_nazwa, nip: odp.nabywca_nip } : null,
    zrodlo: wej.zrodlo,
    model: wej.zapytanie.model,
    czas_modelu_s: $json.total_duration ? Math.round($json.total_duration / 1e8) / 10 : null,
    odpowiedz_surowa: String($json.message?.content ?? '').slice(0, 5000),
  },
};
