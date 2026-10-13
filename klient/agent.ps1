<#
  Agent „AI Faktury” – działa w tle na komputerze klienta (Autostart, instaluj.ps1).

  Pulpit\AI Faktury\                  ← tu użytkownik wrzuca PDF-y
           Wysłane\                   ← dane zapisane na serwerze
           Do sprawdzenia\            ← serwer miał wątpliwości; obok plik .POWÓD.txt
           Nie wysłane\               ← serwer odrzucił plik (np. nie PDF, nieważny token)

  Folder AI Faktury tworzy tylko instalator. Jeśli zostanie usunięty, agent czeka
  (nic nie wysyła), aż użytkownik uruchomi instalator ponownie.

  Wynik = powiadomienie Windows (kliknięcie otwiera folder).
  Plik odrzucony przez serwer = okno błędu z powodem i danymi dla administratora.
  Dziennik: %APPDATA%\AI-Faktury\agent.log
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Dane = Join-Path $env:APPDATA 'AI-Faktury'
$Log  = Join-Path $Dane 'agent.log'

# Jedna kopia agenta na użytkownika
$mutex = New-Object Threading.Mutex($false, 'Local\AI-Faktury-agent')
try { $jestem = $mutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $jestem = $true }   # poprzedni agent został zabity (np. reinstalacja)
if (-not $jestem) { exit }

function Zapisz-Log([string]$Tekst) {
    Add-Content -LiteralPath $Log -Encoding UTF8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Tekst)
}

$k     = Get-Content -LiteralPath (Join-Path $Dane 'konfiguracja.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Adres = "$($k.serwer)/webhook/faktury"
$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(($k.token | ConvertTo-SecureString))
$Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$Folder  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Faktury'
$Wyslane = Join-Path $Folder 'Wysłane'
$DoSpr   = Join-Path $Folder 'Do sprawdzenia'
$NieWysl = Join-Path $Folder 'Nie wysłane'

# --- Powiadomienia Windows (toast) -------------------------------------------------------------
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function Xml([string]$t) { [Security.SecurityElement]::Escape($t) }

function Pokaz-Powiadomienie([string]$Tytul, [string]$Tresc, [string]$Otworz) {
    try {
        $klik = ''
        if ($Otworz) {
            $uri = ([Uri]$Otworz).AbsoluteUri   # kliknięcie w powiadomienie otwiera folder
            $klik = " activationType=`"protocol`" launch=`"$(Xml $uri)`""
        }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast$klik><visual><binding template=`"ToastGeneric`"><text>$(Xml $Tytul)</text><text>$(Xml $Tresc)</text></binding></visual></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
    } catch {
        Zapisz-Log "Nie udało się pokazać powiadomienia: $($_.Exception.Message)"
    }
}

# --- Okno błędu (na wierzchu innych okien) – gdy serwer odrzuci plik ---------------------------
Add-Type -AssemblyName System.Windows.Forms

function Pokaz-Okno-Bledu([string]$Tytul, [string]$Tresc, [string]$Ikona = 'Error') {
    try {
        $wlasciciel = New-Object Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
        [void][Windows.Forms.MessageBox]::Show($wlasciciel, $Tresc, $Tytul,
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::$Ikona)
        $wlasciciel.Dispose()
    } catch {
        Zapisz-Log "Nie udało się pokazać okna błędu: $($_.Exception.Message)"
    }
}

function Moje-IP {
    try {
        (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress -join ', '
    } catch { '?' }
}

function Pokaz-Odrzucone($Odrzucone) {
    # Jedno okno na każdy powód (a nie osobne okno dla każdego pliku)
    foreach ($grupa in ($Odrzucone | Group-Object { $_.kod })) {
        $p = $grupa.Group[0]
        $pliki = ($grupa.Group | ForEach-Object { "   • $($_.plik)" }) -join "`n"
        $ile = $grupa.Group.Count
        if ($p.kod -eq 'DUPLIKAT') {
            # Duplikat: informacja, nie awaria – użytkownik nie musi nic zgłaszać
            foreach ($d in $grupa.Group) {
                $tresc = @(
                    'Ten dokument był już wcześniej dodany do systemu:'
                    "   • $($d.plik)"
                    ''
                    $d.powod
                    ''
                    'Plik przeniesiono do folderu „Nie wysłane” (Pulpit\AI Faktury).'
                    'Nie musisz nic robić – dane z tego dokumentu są już zapisane.'
                    ''
                    "Jeśli to pomyłka, zgłoś się do administratora (kod: DUPLIKAT, komputer: $env:COMPUTERNAME)."
                ) -join "`n"
                Pokaz-Okno-Bledu 'AI Faktury – dokument już był dodany' $tresc 'Warning'
            }
            continue
        }
        $tresc = @(
            $(if ($ile -eq 1) { 'Serwer AI nie przyjął pliku:' } else { "Serwer AI nie przyjął $ile plików:" })
            $pliki
            ''
            "Powód: $($p.powod)"
            ''
            'Przeniesiono do folderu „Nie wysłane” (Pulpit\AI Faktury).'
            ''
            'Zgłoś się do administratora serwera AI i podaj:'
            "   komputer:   $env:COMPUTERNAME"
            "   użytkownik: $env:USERNAME"
            "   adres IP:   $($p.ip)"
            "   kod błędu:  $($p.kod)"
        ) -join "`n"
        Pokaz-Okno-Bledu 'AI Faktury – plik nie został wysłany' $tresc
    }
}

function Przenies([IO.FileInfo]$Plik, [string]$Cel) {
    if (-not (Test-Path -LiteralPath $Cel)) { New-Item -ItemType Directory -Force -Path $Cel | Out-Null }
    $docelowy = Join-Path $Cel $Plik.Name
    if (Test-Path -LiteralPath $docelowy) {
        $docelowy = Join-Path $Cel ('{0}_{1:yyyyMMdd-HHmmss}{2}' -f $Plik.BaseName, (Get-Date), $Plik.Extension)
    }
    Move-Item -LiteralPath $Plik.FullName -Destination $docelowy
    return $docelowy
}

# --- Pętla główna ------------------------------------------------------------------------------
$Zgloszone = @{}   # pliki, dla których już pokazano „serwer niedostępny” (bez spamu co 10 s)
$BrakFolderu = $false
Zapisz-Log "Agent uruchomiony (klient: $($k.klient), serwer: $($k.serwer))"

while ($true) {
    # Brak folderu AI Faktury (usunięty) – czekamy, aż użytkownik uruchomi instalator
    if (-not (Test-Path -LiteralPath $Folder)) {
        if (-not $BrakFolderu) { Zapisz-Log "Brak folderu $Folder – czekam na ponowne uruchomienie instalatora" }
        $BrakFolderu = $true
        Start-Sleep -Seconds 10
        continue
    }
    $BrakFolderu = $false
    $Odrzucone = @()   # pliki odrzucone w tym obiegu – jedno okno błędu na końcu
    foreach ($plik in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) {
      try {
        if ($plik.Name -like '~$*' -or $plik.Name -like '*.tmp') { continue }

        if ($plik.Extension -ne '.pdf') {
            Przenies $plik $NieWysl | Out-Null
            Zapisz-Log "Pominięto $($plik.Name) – to nie jest PDF"
            Pokaz-Powiadomienie 'AI Faktury: pominięto plik' "$($plik.Name) to nie jest PDF. Przeniesiono do „Nie wysłane”." $NieWysl
            continue
        }

        # Plik jeszcze się kopiuje lub jest otwarty – spróbuj w następnym obiegu
        try { $s = [IO.File]::Open($plik.FullName, 'Open', 'Read', 'None'); $s.Close() } catch { continue }

        try {
            $odp = Invoke-RestMethod -Uri $Adres -Method Post -InFile $plik.FullName -ContentType 'application/pdf' `
                -UseBasicParsing -TimeoutSec 600 `
                -Headers @{ 'X-Klient-Token' = $Token; 'X-Nazwa-Pliku' = [Uri]::EscapeDataString($plik.Name) }
        } catch {
            Zapisz-Log "Błąd wysyłki $($plik.Name): $($_.Exception.Message)"
            if (-not $Zgloszone.ContainsKey($plik.FullName)) {
                $Zgloszone[$plik.FullName] = $true
                Pokaz-Powiadomienie 'AI Faktury: serwer niedostępny' "Nie udało się wysłać $($plik.Name). Agent spróbuje ponownie automatycznie." $Folder
            }
            continue
        }
        $Zgloszone.Remove($plik.FullName)

        switch ($odp.status) {
            'zapisano' {
                Przenies $plik $Wyslane | Out-Null
                $info = 'Nr {0}, {1}, {2:N2} {3}' -f $odp.numer_dokumentu, $odp.kontrahent, [double]$odp.kwota_brutto, $odp.waluta
                if (@($odp.ostrzezenia).Count) { $info += " (uwagi: $(@($odp.ostrzezenia) -join '; '))" }
                Zapisz-Log "Zapisano $($plik.Name): $info"
                Pokaz-Powiadomienie 'AI Faktury: zapisano' "$($plik.Name)`n$info" $Wyslane
            }
            'do_sprawdzenia' {
                $bledy = @($odp.bledy)
                $docelowy = Przenies $plik $DoSpr
                $powody = ($bledy | ForEach-Object { "  - $_" }) -join "`r`n"
                Set-Content -LiteralPath ($docelowy + '.POWÓD.txt') -Encoding UTF8 -Value (
                    "Plik: $($plik.Name)`r`nSprawdzono: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`n`r`n" +
                    "Serwer AI NIE zapisał danych z tego dokumentu, bo:`r`n$powody`r`n`r`n" +
                    'Sprawdź dokument. Jeśli jest poprawny, przekaż go do ręcznego wprowadzenia; ' +
                    'jeśli to był zły plik – wrzuć właściwy do folderu AI Faktury.')
                Zapisz-Log "Do sprawdzenia $($plik.Name): $($bledy -join ' | ')"
                Pokaz-Powiadomienie 'AI Faktury: plik wymaga sprawdzenia' "$($plik.Name)`n$($bledy[0])" $DoSpr
            }
            'odrzucono' {
                Przenies $plik $NieWysl | Out-Null
                $kod = if ($odp.kod) { $odp.kod } else { 'ODRZUCONO' }
                $ip  = if ($odp.ip) { $odp.ip } else { Moje-IP }
                Zapisz-Log "Serwer odrzucił $($plik.Name) [$kod]: $($odp.powod)"
                $Odrzucone += [pscustomobject]@{ plik = $plik.Name; kod = $kod; powod = $odp.powod; ip = $ip }
            }
            default {
                Zapisz-Log "Nieznana odpowiedź serwera dla $($plik.Name) – plik zostaje, ponowię później"
            }
        }
      } catch {
        Zapisz-Log "Błąd obsługi pliku $($plik.Name): $($_.Exception.Message)"
      }
    }
    if ($Odrzucone.Count) { Pokaz-Odrzucone $Odrzucone }   # okno czeka na „OK”, potem agent działa dalej
    Start-Sleep -Seconds 10
}
