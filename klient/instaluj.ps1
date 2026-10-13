<#
  Instalator agenta „AI Faktury” – komputer kliencki z Windows 10/11.
  Nie wymaga uprawnień administratora.

  Instalacja, aktualizacja i naprawa – zawsze ta sama komenda (w folderze z tym plikiem):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\instaluj.ps1
  Odinstalowanie:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\instaluj.ps1 -Odinstaluj

  Co robi:
    1. sprawdza bezpieczne połączenie z serwerem (certyfikat caddy-root.crt),
    2. tworzy folder Pulpit\AI Faktury (tylko instalator go tworzy – agent nie),
    3. token (token.ps1) – serwer sprawdza zapamiętany token albo wydaje nowy:
         - zapisany token ważny                  → zostaje, aktualizowany jest tylko agent,
         - komputer zaufany, bez tokenu          → serwer od razu wydaje nowy token,
         - komputer niezaufany / token do resetu → czeka na decyzję administratora,
       token jest zapisywany zaszyfrowany przez Windows (DPAPI – tylko to konto na tym komputerze),
    4. kopiuje skrypty do %APPDATA%\AI-Faktury, zapisuje numer wersji, tworzy na Pulpicie skrót
       „AI Faktury – aktualizacja” (aktualizacja.cmd), dodaje agenta do Autostartu i uruchamia go.

  Sam token (sprawdzenie / nowy) bez reinstalacji: token.ps1
#>
param(
    [string]$Serwer = 'https://192.168.1.109:8443',
    [switch]$Odinstaluj,
    [switch]$NowyToken   # dawny parametr – już niepotrzebny (token sprawdzany jest zawsze), zostaje dla zgodności
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$OdciskCA = '140B9D17110DBEFE6CE4E3B67476CFF84DB53F92'   # caddy-root.crt z serwera
$Dane     = Join-Path $env:APPDATA 'AI-Faktury'
$Agent    = Join-Path $Dane 'agent.ps1'
$Konfig   = Join-Path $Dane 'konfiguracja.json'
$Skrot    = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Faktury - agent.lnk'
$Folder   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Faktury'
$SkrotAkt = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Faktury - aktualizacja.lnk'
$Skrypty  = 'agent.ps1', 'token.ps1', 'aktualizacja.ps1', 'aktualizacja.cmd', 'instaluj.ps1', 'CZYTAJ.txt', 'WERSJA'

function Zatrzymaj-Agenta {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*AI-Faktury\agent.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

if ($Odinstaluj) {
    Zatrzymaj-Agenta
    Remove-Item -LiteralPath $Skrot -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SkrotAkt -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Dane -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Agent usunięty. Folder '$Folder' zostaje (to Twoje pliki)."
    Write-Host 'Przy ponownej instalacji administrator musi zresetować token tego komputera.'
    return
}

foreach ($plik in $Skrypty) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $plik))) { throw "Brak pliku $plik obok instalatora." }
}

# --- 1. Bezpieczne połączenie z serwerem ------------------------------------------------------
Write-Host "Sprawdzam połączenie z $Serwer ..."
try {
    Invoke-WebRequest "$Serwer/healthz" -UseBasicParsing -TimeoutSec 10 | Out-Null
} catch {
    $plikCA = Join-Path $PSScriptRoot 'caddy-root.crt'
    if (-not (Test-Path -LiteralPath $plikCA)) {
        throw "Brak bezpiecznego połączenia z serwerem ($($_.Exception.Message)). Zainstaluj certyfikat caddy-root.crt jako zaufany."
    }
    $ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $plikCA
    if ($ca.Thumbprint -ne $OdciskCA) {
        throw "Certyfikat caddy-root.crt ma nieoczekiwany odcisk $($ca.Thumbprint) – NIE instaluję go. Pobierz go ponownie od administratora."
    }
    Write-Host 'Instaluję certyfikat serwera jako zaufany dla Twojego konta (Windows poprosi o potwierdzenie)...'
    Import-Certificate -FilePath $plikCA -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Invoke-WebRequest "$Serwer/healthz" -UseBasicParsing -TimeoutSec 10 | Out-Null
}
Write-Host 'Połączenie szyfrowane działa.'

# --- 2. Folder na Pulpicie (tworzy go tylko instalator) ---------------------------------------
foreach ($f in @($Folder, (Join-Path $Folder 'Wysłane'), (Join-Path $Folder 'Do sprawdzenia'), (Join-Path $Folder 'Nie wysłane'))) {
    New-Item -ItemType Directory -Force -Path $f | Out-Null
}
Write-Host "Folder na Pulpicie: $Folder"

# --- 3. Token: sprawdzenie zapamiętanego albo pobranie nowego (token.ps1) --------------------
& (Join-Path $PSScriptRoot 'token.ps1') -Serwer $Serwer -BezRestartuAgenta
if ($LASTEXITCODE -ne 0) { throw 'Nie udało się uzyskać tokenu.' }

# Skrypty i numer wersji do %APPDATA%\AI-Faktury (stąd działa agent i aktualizacja)
New-Item -ItemType Directory -Force -Path $Dane | Out-Null
foreach ($plik in $Skrypty) {
    $zrodlo = Join-Path $PSScriptRoot $plik
    $cel = Join-Path $Dane $plik
    if ((Resolve-Path -LiteralPath $zrodlo).Path -ne $cel) { Copy-Item -LiteralPath $zrodlo -Destination $cel -Force }
}
$wersja = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'WERSJA') -Raw).Trim()
Set-Content -LiteralPath (Join-Path $Dane 'wersja.txt') -Value $wersja -Encoding ASCII
Write-Host "Wersja agenta: $wersja"

# Skrót do aktualizacji na Pulpicie (poza folderem AI Faktury – agent wysyła wszystko, co tam leży)
$lnkAkt = (New-Object -ComObject WScript.Shell).CreateShortcut($SkrotAkt)
$lnkAkt.TargetPath  = Join-Path $Dane 'aktualizacja.cmd'
$lnkAkt.WorkingDirectory = $Dane
$lnkAkt.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
$lnkAkt.Description = 'Aktualizacja agenta AI Faktury'
$lnkAkt.Save()

# --- 4. Autostart i uruchomienie agenta ------------------------------------------------------
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argumenty  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Agent`""
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Skrot)
$lnk.TargetPath  = $powershell
$lnk.Arguments   = $argumenty
$lnk.WindowStyle = 7
$lnk.Description = 'Agent AI Faktury – wysyła PDF-y do serwera AI i pokazuje powiadomienia'
$lnk.Save()

Zatrzymaj-Agenta
Start-Process -FilePath $powershell -ArgumentList $argumenty -WindowStyle Hidden
Write-Host ''
Write-Host "Gotowe. Wrzucaj faktury PDF do folderu na Pulpicie: $Folder" -ForegroundColor Green
Write-Host 'Wynik każdego pliku pokaże się jako powiadomienie Windows.'
