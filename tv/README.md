# Klient Smart TV — istniejący TVBro

Wariant [Titan OS](titan_os/README.md) buduje hostowany payload HTML5 z aktualnego
klienta Samsung Web i tego samego kompilowanego rdzenia Dart. Reużywa odtwarzacz
HTML5 i szyfrowany magazyn klienta LG, dodając wiązania pilota i wyjścia Titan.
Wynik wymaga hostowania HTTPS, dostępu testowego DevView i kwalifikacji na TV;
lokalny build nie oznacza instalacji ani publikacji w sklepie.

Wariant [LG webOS](lg_webos/README.md) buduje IPK z tego samego interfejsu,
kompilowanego rdzenia Dart i modułów klienta Samsung. Dodaje adapter wideo LG,
szyfrowany magazyn IndexedDB, pilot i pakowanie. Celem kwalifikacji jest webOS
4.x i nowszy; 3.x pozostaje kandydatem zależnym od dostępności API. Lokalne
testy nie zastępują odbioru na telewizorze. Ograniczenia nagłówków odtwarzania
i kopii plikowych opisuje README wariantu LG. Filmy i odcinki Xtream korzystają
z bezpośredniego odtwarzania z natywnym User-Agent LG zamiast domyślnego VLC.

Aktualny cel obejmuje Samsung UE43M5672 z 2017 roku / Tizen 3.0. Klient
[Samsung Web](samsung_web/README.md) buduje WGT z kompilowanymi oryginalnymi
klasami Source, parserami i regułami Dart, obecnymi modułami walidacji/kryptografii
panelu oraz adapterami AVPlay, KeyManager i pilota. Obejmuje profile/PIN,
Live, filmy/seriale, EPG/catch-up, ulubione, historię i ręczną synchronizację.
Opcjonalny transport metadanych Stalkera wymaga włączenia w istniejącym backendzie.
To implementacja klienta z osobną prezentacją DOM; odbiór sprzętowy jest otwarty.

[Instalacja i publikacja](samsung_web/INSTALL.md) rozróżniają konto/certyfikat
wydawcy od instalacji użytkowników ze sklepu TV. Androida i Windowsa nie
przebudowano ani nie zmieniono w ramach tego klienta. Wyniki są w
[walidacji](VALIDATION.md). Próby Flutter/TPK poniżej dotyczą Tizena 6.0+ i nie
obejmują Samsunga z 2017 roku.

## Wcześniejsza kwalifikacja

Powstał pierwszy lokalnie podpisany **TPK kwalifikacyjny Tizen TV/API 6**.
[Wyniki](VALIDATION.md) obejmują kompilację oryginalnego wejścia, projekt C#,
systemowy adapter SQLite i pakowanie 33 zachowanych plików. Odtwarzanie
MediaKit, działanie na TV oraz pełna kwalifikacja runtime pozostają otwarte.
[Generator projektu](tizen_app/README.md) i [narzędzia](tizen_builder/README.md)
korzystają z istniejącego kodu aplikacji zamontowanego tylko do odczytu.

Pozostałe katalogi `tv/` zachowują historyczny harness R02, który przez
`package:iptvs` uruchamia wybrane, oryginalne moduły Dart z `app/lib/` na hoście.

- [Raport kwalifikacji, ograniczenia i blokady SDK](native_probe/QUALIFICATION.md)
- [Opis harnessu i jego zakresu](native_probe/README.md)
- [Scenariusze testowe](native_probe/test/reuse_test.dart)
- [Runner PowerShell](native_probe/run.ps1)
- [Plan platform TVBro](../docs/platform-expansion.md)

Uruchomienie używa istniejącego, lokalnego SDK Fluttera oraz cache zależności; nie wykonuje instalacji ani `pub get`. Logi i dowód niezmienionych wejść zapisuje w ignorowanym `tv/output/native-probe/`.

Ostatni pełny wynik hostowy to **19/19 testów**: 3 próby źródeł, 13 istniejących
testów EPG, dwa procesy zapisu/odczytu magazynów oraz start oryginalnej aplikacji.
[Wejście TV](app/main.dart) wywołuje istniejące `main()`; próba przechodzi przez
język, profile, Home i Sources do zapisu M3U, z rzeczywistym MediaKit i DPAPI.
Oryginalne logo i fonty są stage'owane automatycznie. Zachowane dowody i
[podgląd UI](output/continuation-20261024/verified-19-bootstrap/sources-1280x720.png)
opisuje [walidacja](VALIDATION.md).
Osobna [próba SDK Tizena](sdk_probe/README.md) sprawdza faktyczne przyjęcie
kernela przez oficjalny kompilator, z oryginalnymi importami i bez zmiany SDK aplikacji.
[Builder silnika TV](engine_builder/README.md) wykorzystuje naprawione WSL na G:
do odizolowanej budowy własnego zestawu Tizen/Dart 3.13.5.
Silnik ARM i kompilator zbudowano poprawnie; nowy kompilator przyjął niezmieniony
kernel TVBro i utworzył ARM AOT. To osobny wynik kompilacji, bez uruchomienia
runtime, linkowania wtyczek ani pakietu TPK; dowody są w [walidacji](VALIDATION.md).

Opisana próba Flutter VM potwierdza oryginalny start i wskazaną trasę UI oraz
trwałość hostowego storage; nie kwalifikuje wtyczek, magazynu, odtwarzania ani
cyklu życia TV. Podczas tamtej kwalifikacji źródła pozostawały tylko do odczytu.
Obecny zakres obejmuje minimalne przełączenia backendu w współdzielonym Dart;
nie zmienia zależności aplikacji ani kodu platformowego Androida i Windowsa.

Usunięty prototyp HTML/JS, jego testy i raport są w historii repozytorium, w commicie `d3ef714ba835ed91375ceebc1e1e231ce8d98b48`. Dawne wyniki dotyczą wyłącznie tamtego prototypu.
