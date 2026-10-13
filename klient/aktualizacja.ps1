<#
  Aktualizacja agenta „AI Faktury”. Uruchamianie: dwuklik na aktualizacja.cmd
  (albo skrót „AI Faktury – aktualizacja” na Pulpicie, tworzony przez instalator).

  Bezpieczeństwo pobierania:
    1. HTTPS + przypięty certyfikat: certyfikat serwera musi pochodzić od NASZEGO urzędu (odcisk CA poniżej),
    2. aktualizację dostaje tylko zaufany komputer z ważnym tokenem (wysłanym z tego samego adresu IP),
    3. lista plików (manifest) jest podpisana cyfrowo kluczem prywatnym serwera (RSA 3072 / SHA-256);
       podpis sprawdzany jest kluczem publicznym wbudowanym w ten skrypt – podrobionej wersji nie da się podpisać,
    4. każdy plik musi mieć sumę SHA-256 z podpisanego manifestu – inaczej przerwanie, bez zmian na komputerze.
  Przed podmianą plików robiona jest kopia poprzedniej wersji (%APPDATA%\AI-Faktury\poprzednia\).
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { $Host.UI.RawUI.WindowTitle = 'AI Faktury – aktualizacja agenta' } catch { }

$OdciskCA          = '140B9D17110DBEFE6CE4E3B67476CFF84DB53F92'
$KluczPublicznyXml = '<RSAKeyValue><Modulus>py9lghjYd6sZyG6hsVgt/ViarLWCeYUqplSfXVrQdrcsFs4xWN++NH26Ezz3XhzqrsWcNHTAeSVkiQKB28hD6moTLY4xNgksjk7LdFQsjGz6vTUdx4KI8fTNHyKkcStah/1f5IsKrXfphzTo8n+rlEQGBKt2ke2igtQyFBUuRcj4fB57Qucgf+Aux+fjJWCb6qft/8VpG1UEkpqrrdPqInS6anaN4Dz2e2D4reFRhfneMxKa1Vylt+aIgGB4l3DU8hVGZ+uSW2Y6DNmYygpXKsioWyvDwiu1fht33jl+qhENpBhsDnkQ0/vFXZnKp/9TOWjFG09C6e8oC5gJqTjdmy+r556ikbUArqExTwYecwzOVxzuQrOenrD65eEEWQdAV9VgKhCUWp9/KYh55F06tpuDiSck88VTLP53pItB8UHGRcsZ9ljjLl4yq6MpnlBEL2tmjDCxWYN6c9nlV/KT9h9HHVFHmds/iILdPW5OCVlCQPV52jpyhB/k/U7r60eN</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

$Dane       = Join-Path $env:APPDATA 'AI-Faktury'
$Konfig     = Join-Path $Dane 'konfiguracja.json'
$PlikWersji = Join-Path $Dane 'wersja.txt'
$Agent      = Join-Path $Dane 'agent.ps1'
$Kopia      = Join-Path $Dane 'poprzednia'
$Powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Postep     = 'Aktualizacja agenta AI Faktury'

function Zakoncz([string]$Tekst, [string]$Kolor = 'Gray', [int]$Kod = 0) {
    Write-Progress -Id 1 -Activity 'Pobieranie' -Completed
    Write-Progress -Id 0 -Activity $Postep -Completed
    Write-Host ''
    if ($Tekst) { Write-Host $Tekst -ForegroundColor $Kolor }
    Write-Host ''
    Write-Host 'Naciśnij dowolny klawisz, aby zamknąć okno...'
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
    exit $Kod
}

function Krok([int]$Procent, [string]$Opis) {
    Write-Progress -Id 0 -Activity $Postep -Status $Opis -PercentComplete $Procent
    Write-Host "  $Opis"
}

function Zatrzymaj-Agenta {
    $procesy = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*AI-Faktury\agent.ps1*' })
    $procesy | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    return $procesy.Count
}

function Uruchom-Agenta {
    if (Test-Path -LiteralPath $Agent) {
        Start-Process -FilePath $Powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Agent`"" -WindowStyle Hidden
    }
}

# Certyfikat serwera musi być wystawiony przez nasz urząd (przypięty odcisk) – ochrona przed podstawionym serwerem.
# Sprawdzamy łańcuch zbudowany PODCZAS połączenia TLS – zawiera certyfikat pośredni przesłany przez serwer
# (serwer → pośredni → główny); sam certyfikat serwera nie wystarczy, bo Windows nie zna certyfikatu pośredniego.
function Sprawdz-Certyfikat([Uri]$Adres) {
    $script:WynikCertyfikatu = @{ zgodny = $false; odcisk = '(brak)'; bledy = '(brak połączenia)' }
    $walidacja = [Net.Security.RemoteCertificateValidationCallback] {
        param($nadawca, $certyfikat, $lancuch, $bledy)
        $elementy = $lancuch.ChainElements
        $glowny = $elementy[$elementy.Count - 1].Certificate
        $zgodny = ($bledy -eq [Net.Security.SslPolicyErrors]::None) -and ($glowny.Thumbprint -eq $OdciskCA)
        $script:WynikCertyfikatu = @{ zgodny = $zgodny; odcisk = $glowny.Thumbprint; bledy = "$bledy" }
        return $zgodny
    }
    $tcp = New-Object Net.Sockets.TcpClient($Adres.Host, $Adres.Port)
    try {
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $walidacja)
        try { $ssl.AuthenticateAsClient($Adres.Host) } catch { }   # odrzucony certyfikat = wyjątek; wynik mamy wyżej
    } finally {
        $tcp.Close()
    }
    return $script:WynikCertyfikatu
}

# Zapytanie do serwera z postępem pobierania (bajty), zwraca odpowiedź JSON
function Pobierz-Json([string]$Adres, [hashtable]$Cialo, [string]$Opis, [long]$Spodziewane) {
    $zadanie = [Net.HttpWebRequest]::Create($Adres)
    $zadanie.Method = 'POST'
    $zadanie.ContentType = 'application/json; charset=utf-8'
    $zadanie.Timeout = 120000
    $zadanie.Headers.Add('X-Klient-Token', $Token)
    $bajty = [Text.Encoding]::UTF8.GetBytes(($Cialo | ConvertTo-Json -Compress))
    $zadanie.ContentLength = $bajty.Length
    $s = $zadanie.GetRequestStream(); $s.Write($bajty, 0, $bajty.Length); $s.Close()

    $odpowiedz = $zadanie.GetResponse()
    $strumien = $odpowiedz.GetResponseStream()
    $calosc = if ($odpowiedz.ContentLength -gt 0) { $odpowiedz.ContentLength } else { [Math]::Max($Spodziewane, 1) }
    $pamiec = New-Object IO.MemoryStream
    $bufor = New-Object byte[] 16384
    while (($n = $strumien.Read($bufor, 0, $bufor.Length)) -gt 0) {
        $pamiec.Write($bufor, 0, $n)
        $proc = [Math]::Min(100, [int](100 * $pamiec.Length / $calosc))
        Write-Progress -Id 1 -ParentId 0 -Activity $Opis -PercentComplete $proc `
            -Status ('{0:N1} KB z {1:N1} KB' -f ($pamiec.Length / 1KB), ($calosc / 1KB))
    }
    $odpowiedz.Close()
    return ([Text.Encoding]::UTF8.GetString($pamiec.ToArray()) | ConvertFrom-Json)
}

Write-Host ''
Write-Host '=== Aktualizacja agenta AI Faktury ===' -ForegroundColor Cyan
Write-Host ''

# --- 0. Konfiguracja i obecna wersja -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $Konfig)) {
    Zakoncz 'Agent nie jest zainstalowany na tym komputerze. Uruchom najpierw instaluj.ps1.' 'Yellow' 1
}
$k = Get-Content -LiteralPath $Konfig -Raw -Encoding UTF8 | ConvertFrom-Json
$Serwer = $k.serwer
$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(($k.token | ConvertTo-SecureString))
$Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$Obecna = if (Test-Path -LiteralPath $PlikWersji) { (Get-Content -LiteralPath $PlikWersji -Raw).Trim() } else { '0.0.0' }
Write-Host "  Zainstalowana wersja: $(if ($Obecna -eq '0.0.0') { 'nieznana (sprzed systemu aktualizacji)' } else { $Obecna })"
Write-Host ''

$byl_agent = $false
try {
    # --- 1. Zatrzymanie agenta ------------------------------------------------------------------
    Krok 5 'Zatrzymuję agenta...'
    $byl_agent = (Zatrzymaj-Agenta) -gt 0

    # --- 2. Bezpieczne połączenie: przypięty certyfikat ------------------------------------------
    Krok 10 'Sprawdzam tożsamość serwera (certyfikat)...'
    $cert = Sprawdz-Certyfikat ([Uri]$Serwer)
    if (-not $cert.zgodny) {
        throw ("Certyfikat serwera NIE pochodzi od zaufanego urzędu AI Faktury. Aktualizacja przerwana – zgłoś to administratorowi.`n" +
               "       (odcisk urzędu: $($cert.odcisk), oczekiwany: $OdciskCA, błędy TLS: $($cert.bledy))")
    }

    # --- 3. Podpisany manifest -------------------------------------------------------------------
    Krok 15 'Pobieram informację o najnowszej wersji...'
    $odp = Pobierz-Json "$Serwer/webhook/aktualizacja" @{} 'Informacja o wersji' 4096
    if ($odp.status -ne 'ok') { throw "Serwer odmówił aktualizacji: $($odp.powod) (kod $($odp.kod))" }

    Krok 20 'Sprawdzam podpis cyfrowy aktualizacji...'
    $bajtyManifestu = [Convert]::FromBase64String($odp.manifest_b64)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($KluczPublicznyXml)
    if (-not $rsa.VerifyData($bajtyManifestu, 'SHA256', [Convert]::FromBase64String($odp.podpis))) {
        throw 'Podpis cyfrowy aktualizacji jest NIEPRAWIDŁOWY. Aktualizacja przerwana – zgłoś to administratorowi.'
    }
    $manifest = [Text.Encoding]::UTF8.GetString($bajtyManifestu) | ConvertFrom-Json

    # --- 4. Czy jest nowsza wersja? -------------------------------------------------------------
    if ([version]$manifest.wersja -le [version]$Obecna) {
        if ($byl_agent) { Uruchom-Agenta }
        Zakoncz "Masz najnowszą wersję agenta: $Obecna (opublikowana $($manifest.opublikowano))." 'Green' 0
    }
    Write-Host ''
    Write-Host "  Dostępna nowa wersja: $($manifest.wersja) (opublikowana $($manifest.opublikowano))" -ForegroundColor Cyan
    foreach ($z in @($manifest.zmiany)) { Write-Host "    - $z" }
    Write-Host ''

    # --- 5. Pobieranie plików z postępem i sprawdzaniem SHA-256 ---------------------------------
    $pliki = @($manifest.pliki)
    $pobrane = @{}
    for ($i = 0; $i -lt $pliki.Count; $i++) {
        $p = $pliki[$i]
        Krok (25 + [int](60 * $i / $pliki.Count)) "Pobieram $($p.nazwa) ($($i + 1) z $($pliki.Count))..."
        $plik = Pobierz-Json "$Serwer/webhook/aktualizacja" @{ plik = $p.nazwa } "Pobieranie $($p.nazwa)" ([long]($p.rozmiar * 4 / 3 + 300))
        if ($plik.status -ne 'ok') { throw "Serwer nie wydał pliku $($p.nazwa): $($plik.powod)" }
        $tresc = [Convert]::FromBase64String($plik.tresc_b64)
        $suma = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($tresc) | ForEach-Object { $_.ToString('x2') })
        if ($suma -ne $p.sha256) { throw "Plik $($p.nazwa) ma inną sumę SHA-256 niż w podpisanym manifeście. Aktualizacja przerwana." }
        $pobrane[$p.nazwa] = $tresc
        Start-Sleep -Milliseconds 150   # żeby postęp był czytelny przy małych plikach
    }
    Write-Progress -Id 1 -Activity 'Pobieranie' -Completed

    # --- 6. Kopia poprzedniej wersji i podmiana plików -------------------------------------------
    Krok 88 'Zapisuję kopię poprzedniej wersji...'
    New-Item -ItemType Directory -Force -Path $Kopia | Out-Null
    foreach ($nazwa in $pobrane.Keys) {
        $cel = Join-Path $Dane $nazwa
        if (Test-Path -LiteralPath $cel) { Copy-Item -LiteralPath $cel -Destination (Join-Path $Kopia $nazwa) -Force }
    }
    if (Test-Path -LiteralPath $PlikWersji) { Copy-Item -LiteralPath $PlikWersji -Destination (Join-Path $Kopia 'wersja.txt') -Force }

    Krok 93 'Instaluję nową wersję...'
    try {
        foreach ($nazwa in $pobrane.Keys) { [IO.File]::WriteAllBytes((Join-Path $Dane $nazwa), $pobrane[$nazwa]) }
        Set-Content -LiteralPath $PlikWersji -Value $manifest.wersja -Encoding ASCII
    } catch {
        # przywrócenie poprzedniej wersji
        Get-ChildItem -LiteralPath $Kopia -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Dane $_.Name) -Force }
        throw "Nie udało się zapisać nowych plików ($($_.Exception.Message)). Przywrócono poprzednią wersję."
    }

    # --- 7. Uruchomienie nowego agenta ----------------------------------------------------------
    Krok 98 'Uruchamiam agenta...'
    Uruchom-Agenta
    Write-Progress -Id 0 -Activity $Postep -Status 'Gotowe' -PercentComplete 100
    Zakoncz "Zaktualizowano agenta: $(if ($Obecna -eq '0.0.0') { 'nieznana' } else { $Obecna }) -> $($manifest.wersja)." 'Green' 0
} catch {
    if ($byl_agent -and -not (Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object { $_.CommandLine -like '*AI-Faktury\agent.ps1*' })) {
        Uruchom-Agenta   # agent wraca do pracy w dotychczasowej wersji
    }
    Zakoncz "BŁĄD: $($_.Exception.Message)" 'Red' 1
}
