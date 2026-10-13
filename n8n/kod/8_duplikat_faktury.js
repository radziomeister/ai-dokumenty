// Duplikat, poziom 2: ta sama faktura w INNYM pliku (np. ponowny skan albo eksport z systemu).
// Porównanie po danych odczytanych przez AI: NIP sprzedawcy + numer faktury.
const klucz = kluczFaktury($json.dane.nip_sprzedawcy, $json.dane.numer_dokumentu);
const poprzedni = wczytajRejestr().find((r) => kluczFaktury(r.nip_sprzedawcy, r.numer_dokumentu) === klucz);

return {
  json: {
    ...$json,
    nowy: !poprzedni,
    duplikat: poprzedni ? { rodzaj: 'ta sama faktura w innym pliku', ...poprzedni } : null,
  },
};
