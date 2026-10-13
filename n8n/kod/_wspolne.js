// ===== Wspólne funkcje – zbuduj_workflow.py dołącza ten plik na początek każdego węzła Code =====
// Dziennik zdarzeń (dla administratora): logs/n8n/zdarzenia.jsonl – przegląd: python3 n8n/dziennik.py
// Rejestr zapisanych dokumentów (wykrywanie duplikatów): BACKUP2/wyniki/_rejestr.jsonl
const __fs = require('fs');
const DZIENNIK = '/home/node/logi/zdarzenia.jsonl';
const REJESTR = '/home/node/praca/wyniki/_rejestr.jsonl';

const czasTeraz = () => new Date().toLocaleString('sv-SE', { timeZone: 'Europe/Warsaw' });

// Zapis zdarzenia nigdy nie zatrzymuje przetwarzania dokumentu
const zapiszZdarzenie = (zdarzenie, dane = {}) => {
  try {
    __fs.appendFileSync(DZIENNIK, JSON.stringify({ czas: czasTeraz(), zdarzenie, ...dane }) + '\n');
  } catch (e) { /* brak dziennika nie blokuje obiegu */ }
};

const wczytajRejestr = () => {
  if (!__fs.existsSync(REJESTR)) return [];
  return __fs.readFileSync(REJESTR, 'utf8').split('\n').filter(Boolean)
    .map((linia) => { try { return JSON.parse(linia); } catch (e) { return null; } })
    .filter(Boolean);
};

// Klucz faktury do porównań: NIP (same cyfry) + numer (bez spacji, wielkie litery)
const kluczFaktury = (nip, numer) =>
  `${String(nip ?? '').replace(/\D/g, '')}|${String(numer ?? '').toUpperCase().replace(/\s+/g, '')}`;
// ===== koniec części wspólnej =====

