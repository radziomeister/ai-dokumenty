// Rejestracja agenta: serwer sam wydaje token zaufanym komputerom z sieci lokalnej.
// Instalator zawsze pyta serwer i dołącza zapisany token (nagłówek X-Klient-Token), jeśli go ma:
//  - token ważny dla tego IP                          → „aktualny” (instalator tylko aktualizuje agenta)
//  - { "tylko_sprawdz": true }                         → sam stan, bez wydawania tokenu i bez prośby do admina
//  - IP na liście zaufanych i token jeszcze nie wydany → nowy token (zwracany tylko raz)
//  - IP zaufane, token już wydany                     → odmowa (admin musi zresetować: klienci.py resetuj)
//  - IP nieznane                                      → prośba w dzienniku, „oczekuje”
// Adres IP pochodzi z nagłówka X-Forwarded-For ustawianego przez Caddy
// (Caddy ignoruje ten nagłówek, jeśli przysyła go sam klient).
const fs = require('fs');
const crypto = require('crypto');

const ZAUFANE = '/home/node/zaufane/zaufane.json';
const KLIENCI = '/home/node/klienci/klienci.json';
const PROSBY = '/home/node/klienci/prosby.log';

// Odczyt z ponowieniem: plik zmieniany po stronie macOS bywa przez chwilę widoczny niekompletnie
const czytaj = (p) => {
  for (let proba = 1; ; proba++) {
    try {
      return fs.existsSync(p) && fs.statSync(p).size ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
    } catch (e) {
      if (proba >= 5) throw e;
      const koniec = Date.now() + 200; while (Date.now() < koniec) { /* krótka pauza */ }
    }
  }
};
// Zapis atomowy: plik tymczasowy + podmiana nazwy
const zapiszAtomowo = (p, dane) => {
  fs.writeFileSync(p + '.tmp', JSON.stringify(dane, null, 2));
  fs.renameSync(p + '.tmp', p);
};
const teraz = new Date().toLocaleString('sv-SE', { timeZone: 'Europe/Warsaw' });
const tekst = (v, max) => String(v ?? '').replace(/[^\p{L}\p{N} ._-]/gu, '').slice(0, max);

const WERSJA = '__WERSJA__'; // wstawiana przez zbuduj_workflow.py
const naglowki = $json.headers ?? {};

// Test po wdrożeniu (n8n/wdroz.sh): którą wersję workflow obsługuje serwer – bez zapisu w dziennikach
if (naglowki['x-sprawdzenie-wdrozenia']) return { json: { wersja: WERSJA } };
const ip = String(naglowki['x-forwarded-for'] ?? '').split(',')[0].trim().replace(/^::ffff:/, '');
const komputer = tekst($json.body?.komputer, 40);
const uzytkownik = tekst($json.body?.uzytkownik, 40);

const zaufane = czytaj(ZAUFANE);
const klienci = czytaj(KLIENCI);
const nazwa = zaufane[ip];

// Czy komputer ma już ważny token? (porównanie skrótów w stałym czasie)
const tokenKlienta = String(naglowki['x-klient-token'] ?? '');
const tokenWazny = Boolean(tokenKlienta && nazwa && klienci[nazwa] && klienci[nazwa].ip === ip
  && crypto.timingSafeEqual(Buffer.from(klienci[nazwa].skrot, 'hex'),
    crypto.createHash('sha256').update(tokenKlienta).digest()));

const zapiszProsbe = (wynik) => {
  fs.appendFileSync(PROSBY, JSON.stringify({ czas: teraz, ip, komputer, uzytkownik, wynik }) + '\n');
  zapiszZdarzenie('rejestracja', { klient: nazwa ?? null, ip, komputer, uzytkownik, wynik });
};

if (tokenWazny) {
  zapiszProsbe(`token aktualny: ${nazwa}`);
  return { json: { status: 'aktualny', kod: 'TOKEN_WAZNY', ip, klient: nazwa } };
}

// Tryb „tylko sprawdź” (token.ps1 -TylkoSprawdz): niczego nie zmienia
if ($json.body?.tylko_sprawdz === true) {
  const kod = !ip ? 'BRAK_IP' : !nazwa ? 'NIEZAUFANY' : klienci[nazwa] ? 'TOKEN_JUZ_WYDANY' : 'MOZNA_POBRAC';
  const opis = {
    BRAK_IP: 'Serwer nie rozpoznał adresu IP komputera.',
    NIEZAUFANY: 'Ten komputer nie jest na liście zaufanych serwera AI – poproś administratora o zatwierdzenie.',
    TOKEN_JUZ_WYDANY: 'Zapamiętany token jest nieważny, a serwer ma wydany inny – administrator musi go zresetować.',
    MOZNA_POBRAC: 'Komputer jest zaufany i nie ma tokenu – uruchom token.ps1 (bez -TylkoSprawdz), aby go pobrać.',
  }[kod];
  zapiszProsbe(`sprawdzenie: ${kod}`);
  return { json: { status: 'sprawdzono', kod, ip, klient: nazwa ?? null, komunikat: opis } };
}

if (!ip) {
  zapiszProsbe('odrzucono: brak adresu IP');
  return { json: { status: 'odrzucono', kod: 'BRAK_IP', komunikat: 'Serwer nie rozpoznał adresu IP komputera' } };
}

if (!nazwa) {
  zapiszProsbe('oczekuje');
  return {
    json: {
      status: 'oczekuje', kod: 'OCZEKUJE', ip, komputer,
      komunikat: `Komputer ${komputer || '?'} (${ip}) nie jest jeszcze zaufany. Administrator musi go zatwierdzić.`,
    },
  };
}

if (klienci[nazwa]) {
  zapiszProsbe(`odrzucono: token dla ${nazwa} już wydano`);
  return {
    json: {
      status: 'odrzucono', kod: 'TOKEN_JUZ_WYDANY', ip, klient: nazwa,
      komunikat: `Ten komputer (${nazwa}) ma już wydany token. Jeśli agent został odinstalowany `
        + 'albo token zginął, administrator musi go zresetować.',
    },
  };
}

const token = crypto.randomBytes(32).toString('base64url');
klienci[nazwa] = {
  skrot: crypto.createHash('sha256').update(token).digest('hex'),
  ip, komputer, uzytkownik, wydano: teraz,
};
zapiszAtomowo(KLIENCI, klienci);
zapiszProsbe(`wydano token: ${nazwa}`);

return { json: { status: 'wydano', klient: nazwa, ip, token } };
