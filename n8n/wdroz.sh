#!/bin/bash
# Buduje workflowy z n8n/kod/*.js, importuje je do n8n (Docker) i publikuje.
#   bash ~/"LLAMA SERVER/ai-dokumenty/n8n/wdroz.sh"
#
# Import robimy przy ZATRZYMANYM n8n (jednorazowy kontener z tą samą bazą i kluczem):
# import do działającej instancji potrafił przez chwilę po restarcie obsługiwać starą wersję.
# Przerwa w działaniu: ok. 20–30 s (agenci klientów same ponawiają wysyłkę).
set -euo pipefail
export PATH="$HOME/.orbstack/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."

.venv/bin/python -W ignore n8n/zbuduj_workflow.py

docker compose stop n8n >/dev/null 2>&1
docker compose run --rm --no-deps -T -v "$PWD/n8n:/import:ro" --entrypoint sh n8n -c '
    n8n import:workflow --input=/import/workflow_faktury.json &&
    n8n import:workflow --input=/import/workflow_rejestracja.json &&
    n8n import:workflow --input=/import/workflow_aktualizacja.json &&
    n8n import:workflow --input=/import/workflow_m365.json &&
    n8n publish:workflow --id=wf1Faktury000001 &&
    n8n publish:workflow --id=wf2Rejestracja01 &&
    n8n publish:workflow --id=wf3Aktualizacja1 &&
    n8n publish:workflow --id=wf4Microsoft3651
' 2>&1 | grep -i -E "^(Successfully|Publishing|Error)|error" || true

start=$(date +%s)
docker compose start n8n >/dev/null 2>&1

# Test po wdrożeniu: serwer musi odpowiadać NOWĄ wersją (n8n przez kilkanaście sekund
# po starcie potrafi jeszcze obsługiwać poprzednią)
wersja=$(cat n8n/wersja.txt)
for _ in $(seq 1 45); do
    # tylko_sprawdz: gdyby odpowiedziała jeszcze poprzednia wersja, nie potraktuje testu jak prośby o token
    odp=$(curl -s -m 3 --cacert certyfikat/caddy-root.crt -X POST -H "X-Sprawdzenie-Wdrozenia: 1" \
          -H "Content-Type: application/json" -d '{"komputer":"WDROZENIE","tylko_sprawdz":true}' \
          https://192.168.1.109:8443/webhook/rejestracja 2>/dev/null || true)
    if echo "$odp" | grep -q "\"$wersja\""; then
        echo "n8n gotowy – działa wersja $wersja (po $(( $(date +%s) - start )) s)"
        exit 0
    fi
    sleep 2
done
echo "UWAGA: po 90 s serwer nadal nie odpowiada wersją $wersja – sprawdź: docker logs n8n" >&2
exit 1
