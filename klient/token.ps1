<#
  Token agenta „AI Faktury” – sprawdzenie zapamiętanego tokenu i pobranie nowego.
  Nie instaluje agenta ani nie tworzy folderów (to robi instaluj.ps1, który używa tego skryptu).

  Sprawdź zapamiętany token i – jeśli jest nieważny – pobierz nowy:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\token.ps1
  Tylko sprawdź (niczego nie zmienia, nie wysyła prośby do administratora):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\token.ps1 -TylkoSprawdz

  Wynik (kod wyjścia): 0 – token ważny / pobrany, 1 – token nieważny lub brak (tryb -TylkoSprawdz).
  Po pobraniu nowego tokenu działający agent jest restartowany, żeby zaczął go używać.
#>
param(
    [string]$Serwer,
    [switch]$TylkoSprawdz,
    [switch]$BezRestartuAgenta   # używane przez instaluj.ps1 (sam uruchamia agenta)
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Dane   = Join-Path $env:APPDATA 'AI-Faktury'
$Agent  = Join-Path $Dane 'agent.ps1'
$Konfig = Join-Path $Dane 'konfiguracja.json'

# --- Zapamiętany token (zaszyfrowany DPAPI w konfiguracji agenta) ------------------------------
$zapisana = $null
$naglowki = @{}
if (Test-Path -LiteralPath $Konfig) {
    try {
        $zapisana = Get-Content -LiteralPath $Konfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(($zapisana.token | ConvertTo-SecureString))
        $naglowki['X-Klient-Token'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } catch {
        Write-Host 'Zapamiętanego tokenu nie da się odczytać (inne konto Windows lub uszkodzony plik).' -ForegroundColor Yellow
    }
}
if (-not $Serwer) { $Serwer = if ($zapisana.serwer) { $zapisana.serwer } else { 'https://192.168.1.109:8443' } }

if ($naglowki.Count) { Write-Host "Zapamiętany token: jest (klient: $($zapisana.klient))" }
else { Write-Host 'Zapamiętany token: brak' }

function Zapytaj-Serwer([bool]$Sprawdz) {
    $cialo = @{ komputer = $env:COMPUTERNAME; uzytkownik = $env:USERNAME }
    if ($Sprawdz) { $cialo.tylko_sprawdz = $true }
    $bajty = [Text.Encoding]::UTF8.GetBytes(($cialo | ConvertTo-Json))
    Invoke-RestMethod "$Serwer/webhook/rejestracja" -Method Post -Body $bajty -Headers $naglowki `
        -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 30
}

# --- Tryb: tylko sprawdź -----------------------------------------------------------------------
if ($TylkoSprawdz) {
    try { $odp = Zapytaj-Serwer $true }
    catch { throw "Brak połączenia z serwerem $Serwer ($($_.Exception.Message)). Jeśli to nowy komputer – uruchom instaluj.ps1." }
    if ($odp.status -eq 'aktualny') {
        Write-Host "Token WAŻNY – klient $($odp.klient), adres IP $($odp.ip)." -ForegroundColor Green
        exit 0
    }
    Write-Host "Token NIEWAŻNY lub brak. $($odp.komunikat)" -ForegroundColor Red
    Write-Host "  komputer $env:COMPUTERNAME, adres IP $($odp.ip), kod $($odp.kod)"
    if ($odp.kod -eq 'MOZNA_POBRAC') { Write-Host '  Pobierz nowy token: .\token.ps1 (bez -TylkoSprawdz)' }
    exit 1
}

# --- Tryb: sprawdź i w razie potrzeby pobierz nowy ---------------------------------------------
Write-Host "Pytam serwer $Serwer ..."
while ($true) {
    try { $odp = Zapytaj-Serwer $false }
    catch {
        Write-Host "Serwer chwilowo nie odpowiada ($($_.Exception.Message)). Ponawiam za 30 s ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        continue
    }
    if ($odp.status -eq 'aktualny' -or $odp.status -eq 'wydano') { break }
    if ($odp.status -eq 'odrzucono' -and $odp.kod -ne 'TOKEN_JUZ_WYDANY') { throw $odp.komunikat }
    # Niezaufany komputer albo token do resetu – czekamy na administratora
    Write-Host "$($odp.komunikat)" -ForegroundColor Yellow
    Write-Host "  Podaj administratorowi: komputer $env:COMPUTERNAME, adres IP $($odp.ip), kod $($odp.kod)."
    Write-Host '  Ponawiam za 30 s (Ctrl+C przerywa) ...'
    Start-Sleep -Seconds 30
}

if ($odp.status -eq 'aktualny') {
    Write-Host "Token WAŻNY – klient $($odp.klient). Nic nie zmieniam." -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $Dane | Out-Null
$tokenSzyfr = ConvertTo-SecureString $odp.token -AsPlainText -Force | ConvertFrom-SecureString
@{ serwer = $Serwer; klient = $odp.klient; token = $tokenSzyfr } | ConvertTo-Json | Set-Content -LiteralPath $Konfig -Encoding UTF8
Write-Host "Serwer wydał NOWY token dla: $($odp.klient) – zapisany (zaszyfrowany dla tego konta Windows)." -ForegroundColor Green

# Agent czyta token przy starcie – restart, żeby używał nowego
if (-not $BezRestartuAgenta) {
    if (Test-Path -LiteralPath $Agent) {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object { $_.CommandLine -like '*AI-Faktury\agent.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Agent`"" -WindowStyle Hidden
        Write-Host 'Agent uruchomiony ponownie z nowym tokenem.'
    } else {
        Write-Host 'Agent nie jest zainstalowany – uruchom instaluj.ps1.' -ForegroundColor Yellow
    }
}
exit 0
