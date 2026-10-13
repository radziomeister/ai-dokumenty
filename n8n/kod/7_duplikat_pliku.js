// Duplikat, poziom 1: identyczny plik (ta sama zawartość) był już zapisany?
// Sprawdzane PRZED odczytem przez AI – duplikat nie zajmuje modelu.
const fs = require('fs');
const crypto = require('crypto');

const sha256 = crypto.createHash('sha256').update(fs.readFileSync($json.sciezka)).digest('hex');
const poprzedni = wczytajRejestr().find((r) => r.sha256 === sha256);

return {
  json: {
    ...$json,
    sha256,
    nowy: !poprzedni,
    duplikat: poprzedni ? { rodzaj: 'ten sam plik', ...poprzedni } : null,
  },
};
