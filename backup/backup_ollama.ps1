# Backup folderu roboczego z historią wersji (Windows) – odpowiednik backup_ollama.sh.
#
# Źródło:  %USERPROFILE%\LLAMA SERVER\BACKUP2
# Cele:    Pulpit\BACKUP OLLAMA  i  Dokumenty\BACKUP OLLAMA
#   aktualne\                 – bieżąca kopia 1:1 ze źródłem
#   _wersje\RRRR-MM-DD_GGMM\  – pliki nadpisane lub usunięte w danym przebiegu
# Retencja: foldery w _wersje\ starsze niż $RetencjaDni (liczone z nazwy folderu,
# nie z daty modyfikacji pliku – stary plik usunięty dziś nie zniknie od razu).
#
# Wymaga: narzedzia\rclone.exe (https://rclone.org/downloads/ → Windows AMD64/ARM64).
#
# Ręcznie:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\LLAMA SERVER\ai-dokumenty\backup\backup_ollama.ps1"
#
# Harmonogram zadań (PowerShell, na test co godzinę):
#   $skrypt = "$env:USERPROFILE\LLAMA SERVER\ai-dokumenty\backup\backup_ollama.ps1"
#   $akcja  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$skrypt`""
#   $kiedy  = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
#   Register-ScheduledTask -TaskName 'AI-dokumenty backup' -Action $akcja -Trigger $kiedy -Description 'rclone z historią wersji'
# Docelowo co noc:
#   Set-ScheduledTask -TaskName 'AI-dokumenty backup' -Trigger (New-ScheduledTaskTrigger -Daily -At 2:00)
# Usunięcie:
#   Unregister-ScheduledTask -TaskName 'AI-dokumenty backup' -Confirm:$false

$Projekt     = Join-Path $env:USERPROFILE 'LLAMA SERVER\ai-dokumenty'
$Rclone      = Join-Path $Projekt 'narzedzia\rclone.exe'
$Zrodlo      = Join-Path $env:USERPROFILE 'LLAMA SERVER\BACKUP2'
# GetFolderPath zwraca faktyczne położenie – także gdy OneDrive przeniósł Pulpit/Dokumenty
$Cele        = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))     'BACKUP OLLAMA'),
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BACKUP OLLAMA')
)
$RetencjaDni = 30
$Log         = Join-Path $Projekt 'logs\backup.log'

$Znacznik = Get-Date -Format 'yyyy-MM-dd_HHmm'
New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null

# Kopia lokalna nie potrzebuje zdalnych kont – pusty plik konfiguracji w projekcie
$env:RCLONE_CONFIG = Join-Path $Projekt 'narzedzia\rclone.conf'
if (-not (Test-Path $env:RCLONE_CONFIG)) { New-Item -ItemType File -Path $env:RCLONE_CONFIG | Out-Null }

function Zapisz-Log([string]$Tekst) {
    Add-Content -Path $Log -Encoding UTF8 -Value ("{0} [backup] {1}" -f (Get-Date -Format 'yyyy/MM/dd HH:mm:ss'), $Tekst)
}

# Bez źródła nie robimy nic – inaczej sync "usunąłby" całą kopię do _wersje\
if (-not (Test-Path $Zrodlo -PathType Container)) {
    Zapisz-Log "BŁĄD: brak folderu źródłowego $Zrodlo – przerywam"
    exit 1
}

Zapisz-Log "=== start $Znacznik ==="
$Bledy = 0

foreach ($Cel in $Cele) {
    Zapisz-Log "cel: $Cel"
    if ($Cel -match 'OneDrive') {
        Zapisz-Log "UWAGA: cel leży w folderze OneDrive – kopia trafi też do chmury Microsoft"
    }

    & $Rclone sync $Zrodlo (Join-Path $Cel 'aktualne') `
        --backup-dir (Join-Path $Cel "_wersje\$Znacznik") `
        --create-empty-src-dirs `
        --log-file $Log --log-level INFO
    if ($LASTEXITCODE -ne 0) {
        Zapisz-Log "BŁĄD: sync do $Cel nie powiódł się (kod $LASTEXITCODE)"
        $Bledy++
        continue
    }

    # Retencja po nazwie folderu (data przebiegu)
    $Granica = (Get-Date).AddDays(-$RetencjaDni).ToString('yyyy-MM-dd_HHmm')
    $Wersje  = Join-Path $Cel '_wersje'
    if (Test-Path $Wersje) {
        Get-ChildItem -Path $Wersje -Directory |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{4}$' -and $_.Name -lt $Granica } |
            ForEach-Object {
                & $Rclone purge $_.FullName --log-file $Log --log-level INFO
                if ($LASTEXITCODE -eq 0) { Zapisz-Log "retencja: usunięto $($_.Name)" }
            }
    }
}

Zapisz-Log "=== koniec $Znacznik (błędy: $Bledy) ==="
exit $Bledy
