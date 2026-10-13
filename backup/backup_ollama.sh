#!/bin/bash
# Backup folderu roboczego z historią wersji (macOS).
#
# Źródło:  ~/LLAMA SERVER/BACKUP2
# Cele:    ~/Desktop/BACKUP OLLAMA  i  ~/Documents/BACKUP OLLAMA
#   aktualne/                 – bieżąca kopia 1:1 ze źródłem
#   _wersje/RRRR-MM-DD_GGMM/  – pliki nadpisane lub usunięte w danym przebiegu
# Retencja: foldery w _wersje/ starsze niż RETENCJA_DNI (liczone z nazwy folderu).
#
# Uruchamiany przez launchd (backup/pl.ai-dokumenty.backup.plist), ręcznie:
#   bash ~/"LLAMA SERVER/ai-dokumenty/backup/backup_ollama.sh"

set -u

PROJEKT="$HOME/LLAMA SERVER/ai-dokumenty"
RCLONE="$PROJEKT/narzedzia/rclone"
ZRODLO="$HOME/LLAMA SERVER/BACKUP2"
CELE=("$HOME/Desktop/BACKUP OLLAMA" "$HOME/Documents/BACKUP OLLAMA")
RETENCJA_DNI=30
LOG="$PROJEKT/logs/backup.log"

ZNACZNIK=$(date +%Y-%m-%d_%H%M)
mkdir -p "$(dirname "$LOG")"

# Kopia lokalna nie potrzebuje zdalnych kont – pusty plik konfiguracji w projekcie
export RCLONE_CONFIG="$PROJEKT/narzedzia/rclone.conf"
touch "$RCLONE_CONFIG"

log() { echo "$(date '+%Y/%m/%d %H:%M:%S') [backup] $*" >> "$LOG"; }

# Bez źródła nie robimy nic – inaczej sync "usunąłby" całą kopię do _wersje/
if [ ! -d "$ZRODLO" ]; then
    log "BŁĄD: brak folderu źródłowego $ZRODLO – przerywam"
    exit 1
fi

log "=== start $ZNACZNIK ==="
BLEDY=0

for CEL in "${CELE[@]}"; do
    log "cel: $CEL"
    if ! "$RCLONE" sync "$ZRODLO" "$CEL/aktualne" \
            --backup-dir "$CEL/_wersje/$ZNACZNIK" \
            --create-empty-src-dirs \
            --log-file "$LOG" --log-level INFO; then
        log "BŁĄD: sync do $CEL nie powiódł się"
        BLEDY=$((BLEDY + 1))
        continue
    fi

    # Retencja po nazwie folderu (data przebiegu), nie po dacie modyfikacji pliku
    GRANICA=$(date -v-"${RETENCJA_DNI}"d +%Y-%m-%d_%H%M)
    for WERSJA in "$CEL/_wersje"/*/; do
        [ -d "$WERSJA" ] || continue
        NAZWA=$(basename "$WERSJA")
        [[ "$NAZWA" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$ ]] || continue
        if [[ "$NAZWA" < "$GRANICA" ]]; then
            "$RCLONE" purge "$WERSJA" --log-file "$LOG" --log-level INFO \
                && log "retencja: usunięto $NAZWA"
        fi
    done
done

log "=== koniec $ZNACZNIK (błędy: $BLEDY) ==="
exit $BLEDY
