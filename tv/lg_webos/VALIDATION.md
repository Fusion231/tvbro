# Walidacja lokalna LG webOS — 27 października 2026

Wariant przygotowano na istniejącym kliencie Samsung przy udziale agentów
Sol 6.1 Ultra i Luna Max. Wspólne UI, kompilowany rdzeń Dart, biblioteka,
profile i protokół chmury pozostają wspólnymi źródłami. Adaptery LG obejmują
wideo, chroniony magazyn/cache, pilot, wyjście i pakowanie.

## Artefakt pierwszego wariantu 0.1.26

- Pakiet: `../output/lg-webos/package-20261027T162824623Z/online.tvbro.webos_0.1.26_all.ipk`.
- SHA-256: `fe6af3e864be8a7b0e58a40ce8c4880866ae0f478fe90e9d5254df4539b50784`.
- Oficjalny LG CLI utworzył IPK. Skrypt niezależnie porównał wszystkie
  30 plików aplikacji w archiwum z hashami zbudowanego payloadu.
- `../output/lg-webos/latest-build.json` i `latest-package.json` zawierają
  hashe wejść, kompilowanego rdzenia i paczki. Stan testu sprzętu, instalacji
  na TV i certyfikacji pozostaje `false`.

## Testy

- `node --test app/tv/lg_webos/test/*.test.cjs`: **30/30**. Obejmują pakowanie,
  ES5, kontrakt odtwarzacza, anulowanie/zwalnianie zasobów, pojedynczy element
  wideo, odzyskiwanie live, brak resetowania pozycji VOD przy zastoju,
  inicjalizację, transakcje magazynu, uszkodzone dane i limity cache.
- Końcowy przebieg `platform_parity_contract`, `platform_contract` oraz
  `ui_back_contract` Samsunga: **18/18**. Pełny wcześniejszy przebieg miał
  332/333; jedyny błąd wynikał z nieaktualnego mocka `stopPlayback` w teście
  cyklu życia. Mock dostosowano do obecnego API biblioteki i ponowiono
  powyższe testy, bez cofania istniejącej implementacji zatrzymania.
- Po wykryciu kolejnej zmiany współdzielonej biblioteki przebudowano payload
  i powtórzono `library_contract`, `library_parity_contract` oraz
  `platform_parity_contract`: **68/68**. Końcowy IPK powstał po tej próbie;
  zgodność hashów jego wejść sprawdzono przed i po pakowaniu.
- Wszystkie skrypty w payloadzie, także biblioteka LG, przechodzą parser ES5.
  Transpilacja celuje w Chromium 38; kontrola CSS zachowuje istniejący układ
  zgodny ze starszymi silnikami. Nie jest to test rzeczywistego Chromium 38.

## Próby w przeglądarce komputera

Użyto rzeczywistego payloadu LG i lokalnego dostawcy testowego ze wspólnego
`samsung_web/test/ui_browser_server.cjs`. Skrypt Samsunga WebAPI nie był
ładowany; używano rzeczywistego IndexedDB, WebCrypto i workera źródeł.

- `test/browser_qa.js`: profil, źródło, ulubione i katalog 161 kanałów przetrwały
  przeładowanie. Playlistę pobrano raz, po restarcie zero dodatkowych pobrań.
  Jeden element wideo, działający Back LG (461), zachowany fokus, zero błędów JS.
- Istniejący `samsung_web/test/performance_browser_qa.js` uruchomiony na LG:
  10 000 kanałów, około 469 ms pierwszego importu; 20 otwarć z pamięci około
  11,6 ms; 60 odczytów szczegółów około 14,3 ms. Jedno pobranie playlisty
  i jedno pobranie szczegółów, bez ponownych pobrań podczas odczytów z cache.
  W tej próbie nie zarejestrowano długich zadań głównego wątku.
- Podgląd zachowanego interfejsu: [ekran Home](../../../output/playwright/lg-webos-home.png).

To pomiary komputera, nie wydajności procesora telewizora. Próby przeglądarkowe
poprzedzały ostatnią poprawkę ochrony VOD przed automatycznym restartem;
tę poprawkę obejmują końcowe testy odtwarzacza w zestawie 30/30.

## Zakres zgodności do późniejszego sprawdzenia

Pierwszym celem kwalifikacji jest webOS 4.x i nowszy. webOS 3.x jest kandydatem
zależnym m.in. od trwałego zapisu nieeksportowalnego CryptoKey; brak wymaganych
API zatrzymuje start bez zastępowania magazynu jawnym zapisem haseł.
webOS 1.x i 2.x nie należą do tego zakresu.

W wersji 0.1.26 niepusta mapa nagłówków blokowała także filmy i odcinki Xtream.
Wersja 0.1.27 usuwa tę blokadę dla dokładnego domyślnego User-Agent VLC,
wyłącznie na potwierdzonej ścieżce filmu/odcinka ze źródła Xtream. Odtwarzacz
używa bezpośrednio oryginalnego URL i natywnego User-Agent przeglądarki LG.
Inne nagłówki i źródła nie otrzymują tego wyjątku. Dostawca wymuszający konkretny
User-Agent nadal wymaga osobnego sprawdzenia; LG nie ma tu pełnej zgodności
z możliwością ustawiania nagłówków AVPlay. Nie dodano serwera ani proxy.
Lokalny import/eksport plikowych kopii jest niedostępny; wspólny UI otrzymuje
odpowiednie capabilities. Brak też samsungowego sterowania buforem i szybkości
innych niż 1x. Szczegóły oraz źródła LG są w [README](README.md) i [INSTALL](INSTALL.md).

Na fizycznym TV pozostają: instalacja, trwałość danych po restarcie urządzenia,
kodeki/audio/napisy/HLS, rzeczywisty dostawca (CORS/TLS/nagłówki), Magic Remote,
uśpienie/wznowienie i dłuższa sesja. Nie instalowano paczki na telewizorze.

## Poprawka Xtream — wersja 0.1.27

Końcowy pakiet: `../output/lg-webos/package-20261027T164721870Z/online.tvbro.webos_0.1.27_all.ipk`.
SHA-256: `ba8eb4c950a4d2f81088d23693ba4f34626af04ecfeecc5df3b682af98313e9e`.
Oficjalny LG CLI utworzył IPK; skrypt sprawdził zgodność wszystkich 30 plików
z manifestem oraz hashe źródeł przed i po pakowaniu.

Wykonanie: Sol 6.1 Ultra (integracja z oryginalną biblioteką) i Luna Max
(adapter odtwarzacza). Nie zmieniono resolvera Dart, adresów, poświadczeń,
interfejsu ani odtwarzacza Samsunga. Osobny kontekst odtwarzania pozwala
adapterowi LG rozpoznać domyślny nagłówek klienta; przekazana mapa nagłówków
pozostaje niezmieniona.

- **35/35 testów LG**, w tym oryginalny kompilowany resolver Xtream przez
  rzeczywistą bibliotekę i adapter LG, odmowa wyjątku dla M3U/Stalker,
  przełączanie filmu na odcinek, przewijanie i zwalnianie zasobów.
- **97/97 testów regresji Samsunga**: biblioteka, fasada i AVPlay.
- `test/xtream_browser_qa.js`: rzeczywisty plik H.264/AAC 320×180 odtworzony
  jako film, pierwszy i drugi odcinek, przez oryginalne ścieżki `/movie/…`
  i `/series/…`. Potwierdzono zdekodowany obraz, seek do 4/3 s, pauzę/wznowienie,
  zmianę odcinka, jeden element wideo i usunięcie źródła po stop. Zero błędów JS;
  trzy bezpośrednie żądania mediów z natywnym User-Agent przeglądarki.
- Próba wykonana w Chrome na komputerze, z rzeczywistym DOM, IndexedDB,
  WebCrypto i workerem, bez mockowania playera. Lokalny serwer udaje jedynie
  dostawcę w teście i obsługuje HTTP Range. Nie jest częścią ani zależnością IPK.
  Test dekodowania był wyciszony ze względu na politykę autoplay Chrome;
  odsłuch i dekoder fizycznego LG pozostają do późniejszego sprawdzenia.

Przygotowanie lokalnego materiału testowego z katalogu projektu:

```powershell
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24 -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 -t 12 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -movflags +faststart -y output/lg-xtream-fixture.mp4
$env:TVBRO_QA_MEDIA = (Resolve-Path output/lg-xtream-fixture.mp4).Path
node app/tv/samsung_web/test/ui_browser_server.cjs <payload-LG>
```

Otworzyć zwrócony lokalny URL w izolowanej sesji Playwright CLI, następnie
wykonać `run-code --filename app/tv/lg_webos/test/xtream_browser_qa.js`.
Domyślny serwer testowy bez `TVBRO_QA_MEDIA` zachowuje wcześniejsze zachowanie.

## Audyt starszego webOS i zgodności — wersja 0.1.28

Przegląd wykonali Sol 6.1 Ultra (zgodność silnika, build, bootstrap) i Luna Max
(odtwarzacz, magazyn i zużycie zasobów). Nie dodano funkcji ani zmieniono UI.
Jedyna zmiana zachowania produkcyjnego dotyczy magazynu LG: ponowna
inicjalizacja może teraz powieść się po chwilowym błędzie IndexedDB, a zmiana
wersji bazy unieważnia zamknięte połączenie, klucz i stan gotowości. Dwa testy
regresji obejmują ponowienie i odtworzenie zachowanych danych.

Pakiet: `../output/lg-webos/package-20261027T165658720Z/online.tvbro.webos_0.1.28_all.ipk`.
SHA-256: `fd72b6827ab315f247fbdee128869356e17d5d408ea3ed81bfe21f6adfbd4c25`.
Oficjalny LG CLI utworzył IPK; sprawdzono wszystkie 30 plików archiwum oraz
zgodność wejść z manifestem przed i po pakowaniu.

### Sprawdzenie kodu i kontraktów

- Pełny zestaw LG: **38/38**. Obejmuje player, szyfrowany magazyn/cache,
  inicjalizację platformy, rzeczywistą ścieżkę resolvera Xtream i build.
- Dodany test uruchamia wygenerowane polyfille, SDK LG, parser/resolver Dart
  i worker bez natywnych Promise, Map, Set, URL i wybranych nowszych metod.
  Jest to symulacja brakujących API w Node, nie emulator Chromium 38.
- Cały wygenerowany JavaScript przechodzi parser ES5. Nie znaleziono nowego
  blokera w bootstrapie, kolejności skryptów ani obsłudze Back LG.
- Pełny pierwszy przebieg Samsunga: 332/333. Jedyny błąd był w mocku testu,
  który nadal wystawiał `stopPlayback` zamiast aktualnego `backgroundPlayback`.
  Poprawiono wyłącznie mock i oczekiwanie; powiązane testy platformy: **13/13**.
  Następnie powtórzono cały zestaw Samsunga: **333/333**.

### Próby finalnego payloadu przy CPU spowolnionym 6 razy

Użyto Chrome na komputerze, prawdziwego IndexedDB/WebCrypto i natywnego
elementu video, bez SDK Samsunga. Każdy scenariusz miał oddzielny kontekst
przeglądarki. Scenariusz seriali uruchomiono osobno dla każdej rozdzielczości:
w przeciwieństwie do mocka Samsunga rzeczywisty magazyn LG zachowuje dane po
przeładowaniu. Lokalne fixture HTTP zastępują tylko dostawcę. Nie są częścią
aplikacji ani wymaganym dodatkowym serwerem.

- **EPG, 10 000 kanałów:** import 1349 ms, lista 1249 ms, program 1734 ms;
  40 wierszy DOM, zero dodanych/usuniętych wierszy przy drobnym przewijaniu,
  poprawne 60 przejść klawiszem Down. Jedno pobranie playlisty i jedno EPG,
  także po powrocie do katalogu; wyszukanie kanału 9999 działało.
- **Cache, 10 000 kanałów:** import około 933 ms, 20 odczytów źródła około
  504 ms, 60 odczytów szczegółów około 168 ms. Jedno pobranie playlisty
  i szczegółów filmu, bez dodatkowych pobrań z ciepłego cache.
  Zarejestrowano zadania głównego wątku 211, 81, 107, 62, 50, 60 i 56 ms,
  odstęp między klatkami p95 około 33 ms i maksymalny 517 ms. To sygnał
  możliwych przycięć przy dużych danych; bez profilu CPU nie przypisujemy go
  konkretnej funkcji. Ten scenariusz nie renderuje listy seriali.
- **Trwałość:** profil, źródło, ulubione i katalog 161 kanałów przetrwały
  przeładowanie bez ponownego pobrania. Jeden element video, Back 461 i fokus
  działały.
- **Seriale, 720p i 1080p:** 96 pozycji, strony 1–7, najwyżej jeden odczyt
  jednocześnie; stabilne doładowywanie, EOF, fokus i powrót ze szczegółów.
  Zmiana kategorii odrzucała spóźnioną odpowiedź; wyszukiwanie oraz jawne
  ponowienie błędnego doładowania działały. Paginacja filmów pozostała bez zmian.
- **Szczegóły, 720p i 1080p:** opis, obsada, przewijanie, sezony i ograniczone
  okno odcinków działały; przejście do odcinka i powrót zachowywały fokus
  i przewinięcie. Wideo korzystało z lokalnego pliku H.264/AAC i było wyciszone
  z powodu polityki autoplay Chrome. Nie jest to odsłuch ani test dekodera LG.
- Wszystkie powyższe scenariusze przeszły bez błędów JavaScript. Odtwarzanie
  live nie było sprawdzane tym fixture: jego adresy live zwracają 404.

### Otwarte ograniczenia audytu

Nie można potwierdzić braku problemów z wydajnością ani pełnej zgodności
z Samsungiem na podstawie tych prób. Spowolnienie CPU nie odtwarza starego
silnika, pamięci, GPU, dekodera ani systemu telewizora.

Wspólna lista seriali zachowuje wszystkie doładowane karty, a obsługa grafik
przegląda zamontowane obrazy. Pamięć i koszt skanowania mogą rosnąć podczas
długiego przewijania. Jest to ryzyko także wersji Samsunga, odrębne od
zmierzonych zadań w próbie cache. Nie zmierzono tutaj tysięcy kart ani nie
wprowadzono przebudowy wirtualizacji i obsługi fokusu.

Cel kwalifikacji nadal stanowi webOS 4.x+; webOS 3.x pozostaje warunkowym
kandydatem zależnym od API i trwałego CryptoKey. [Specyfikacja LG](https://webostv.developer.lge.com/develop/specifications/web-api-and-web-engine)
podaje Chromium 53 dla 4.x i 38 dla 3.x oraz zastrzega różnice API platformy.
Dotychczasowe ograniczenia nagłówków dostawcy, kodeków/ścieżek audio/napisów,
regulacji bufora, szybkości innych niż 1x i lokalnych kopii plikowych pozostają.
Fizyczny TV, starszy silnik i rzeczywisty dostawca nadal wymagają późniejszego
testu. Nie instalowano aplikacji na telewizorze.

## Poprawki wydajności — wersja 0.1.29

Sol 6.1 Ultra ograniczył DOM seriali; Luna Max zoptymalizowała odczyt cache
i zbędne przebiegi po katalogu. Zachowano istniejące ekrany i funkcje.

- Lista seriali montuje widoczne wiersze, cztery wiersze zapasu i najwyżej
  jeden dodatkowy wiersz z aktywnym fokusem. Pozostałą wysokość zachowują
  niewidoczne elementy dystansujące. Dane katalogu pozostają w cache, więc
  cofanie nie wymaga ponownego pobrania. Nie jest to limit liczby seriali.
- Zachowano wymiary kart, mieszane wysokości wierszy, wyszukiwanie,
  doładowywanie, retry, nawigację pilotem i powrót ze szczegółów. Niezmienione
  okno nie jest przebudowywane przy drobnym przewijaniu.
- Odczyt zaszyfrowanego UTF-16LE składa tekst w ograniczonych paczkach zamiast
  doklejać każdy znak osobno. Format danych, szyfrowanie i oddawanie czasu
  wątkowi UI pozostają zachowane.
- Zapis katalogu pomija skan UTF-8, jeśli konserwatywna granica rozmiaru
  już dowodzi, że dane mieszczą się w limicie. Większe dane nadal przechodzą
  dokładny skan. Nie dodano bufora Blob ani zwiększonych limitów pamięci.
- Widok kanałów bez aktywnych reguł widoczności używa natywnej kopii tablicy
  zamiast wykonywać predykat JavaScript dla każdego wiersza. Nadal zwraca
  odrębną tablicę; organizacja, ukrywanie i kontrola rodzicielska są zachowane.

### Wyniki

Wszystkie pomiary dotyczą Chrome na komputerze przy CPU spowolnionym 6 razy.
Nie są pomiarem procesora ani silnika starszego telewizora.

| Próba | Przed | Po |
| --- | ---: | ---: |
| Maksymalna liczba kart DOM po przewinięciu 2000 seriali, 720p | 2000 | 48 |
| Cały scenariusz przewijania, powrotu ze szczegółów i cofania, 720p | 188,5 s | 46,8 s |
| Dekodowanie 2 359 296 znaków w jednym kontekście, dwie próby | 3,01–3,61 s | 1,25–1,27 s |

Próba finalnego payloadu w 1080p również osiągnęła wszystkie 2000 pozycji:
maksymalnie 48 kart DOM, 42 po powrocie na początek, poprawne 40 przejść
w górę, fokus i Back ze szczegółów. Trwała około 27,9 s. Wyniki czasowe
zależą od obciążenia komputera; stabilny limit DOM jest istotniejszy od
pojedynczej wartości czasu. Pojedyncze długie zadania nadal występują
(najdłuższe 317 ms w końcowej próbie 1080p), więc nie deklarujemy usunięcia
każdego możliwego przycięcia.

Porównanie geometrii 84 kart o mieszanej zawartości metadanych dało identyczne
wyniki: wysokość listy 4003 px, pozycja ostatniej karty 3774 px, jej rozmiar
150 × 284,390625 px i położenie w widoku 1054 × 395,125 px. Zrzuty
[przed](../../../output/playwright/lg-series-geometry-before.png) i
[po](../../../output/playwright/lg-series-geometry-after.png) różnią się
zaledwie dwoma pikselami przy krawędzi karty na 921 600 pikseli obrazu.

- **338/338 testów Samsunga, 40/40 testów LG**. Test magazynu sprawdza także
  dokładne bajty UTF-16LE i znak spoza BMP na granicy paczki; stary i nowy
  magazyn poprawnie odszyfrowują wzajemnie swoje dane.
- Końcowe scenariusze przeglądarkowe seriali w 720p/1080p: doładowywanie,
  odrzucanie spóźnionych odpowiedzi, EOF, wyszukiwanie, błędy/retry i fokus.
- Szczegóły filmów i seriali w obu rozdzielczościach, odtwarzanie odcinka
  i powrót do jego pozycji, trwałość danych po przeładowaniu, Back LG.
- EPG 10 000 kanałów: nadal 40 wierszy DOM, bez przebudowy wierszy przy
  drobnym przewijaniu, po jednym pobraniu playlisty i EPG.
- Wszystkie te scenariusze przeszły bez błędów JavaScript. Lokalne media
  pozostają fixture testowym; aplikacja nie wymaga dodatkowego serwera.

Test dużego katalogu: `test/series_performance_browser_qa.js`, uruchamiany
w świeżym kontekście na payloadzie LG. Parametr `?baseline=1` pozwala zebrać
pomiar starej wersji bez wymagania nowego limitu DOM. Przegląd nie potwierdza
fizycznego webOS, kodeków ani dostawcy; zgodnie z ustaleniem test TV później.

Pakiet: `../output/lg-webos/package-20261027T182837182Z/online.tvbro.webos_0.1.29_all.ipk`.
SHA-256: `94b3cba57f53f7584d3a4db6c8a829b4cbff3632d6b4e4ebb25a65b8ef74c4e1`.
Oficjalny LG CLI utworzył IPK; wszystkie 30 plików archiwum i hashe wejść
przeszły kontrolę integralności. JavaScript nadal przechodzi bramkę ES5.

## 0.1.30 — zbędne pomiary grafik i fokus podczas budowania ekranów

Przegląd wykonano z Sol 6.1 Ultra i Luna Max. Zakres tej poprawki obejmuje
wyłącznie pięć funkcji współdzielonego `ui/app.js` oraz numer wersji LG.
Porównanie plików payloadu z 0.1.29 potwierdza, że CSS, zasoby i moduły
platformy pozostają identyczne.

- Scheduler grafik nie mierzy widoczności ani geometrii kolejnych obrazów,
  gdy oba sloty pobierania są zajęte, i kończy skan po ich zapełnieniu.
  Zakończenie, błąd i timeout nadal zwalniają slot i wznawiają kolejkę.
  Zachowano kolejność, limity hostów, obsługę duplikatów i fallback obrazów.
- Ekrany języka i profili ustawiają fokus raz, po zbudowaniu listy.
  Zachowano wybór języka, pierwszy profil, fallback i zachowanie pozostałych
  ekranów. Usunięto pośredni fokus wymuszający dodatkowy layout.

Walidacja: **343/343 testy wspólnej aplikacji Samsung i 40/40 testów LG**,
w tym test pomiarów grafik przy pełnej kolejce oraz cztery testy zachowania
fokusu. Przeglądarkowy scenariusz 2000 seriali nadal montuje maksymalnie
48 kart i zachowuje powrót do ostatniej pozycji, 40 przejść w górę i powrót
na początek. Szczegóły filmów/seriali, odcinki, przewijanie, fokus oraz powrót
z odtwarzania przeszły w 720p i 1080p bez błędów JavaScript.

Profilowanie Chrome z CPU spowolnionym 6 razy nadal wykazuje koszt pierwszego
otwarcia szczegółów. W porównaniu przeplatanym pierwszy layout trwał około
234 ms, kolejne około 14–25 ms; po odwróceniu kolejności wariantów pierwsze
otwarcie również było kosztowne (około 510 ms). Eksperyment zamiany reguł
height/max-height zachował geometrię, ale nie usunął tego kosztu, więc nie
trafił do kodu. Fonty były już załadowane. Nie ustalono jeszcze przyczyny
tego pierwszego layoutu i nie deklarujemy usunięcia wszystkich przycięć ani
poprawy całkowitego czasu na podstawie zmiennych wyników hosta. Wymienione
dwie poprawki eliminują konkretną zbędną pracę; testy na fizycznym webOS,
w tym ocena pierwszego otwarcia szczegółów, pozostają na później.

Pakiet: `../output/lg-webos/package-20261027T191026248Z/online.tvbro.webos_0.1.30_all.ipk`.
SHA-256: `2973c1a058e26de7c7c6fc236015585cb70d044ec73adfc893efb91960751cd3`.
Oficjalny LG CLI oraz kontrola wszystkich 30 plików IPK i hashy źródeł:
zaliczone. ES5 i bramka starszego CSS: zaliczone. Bez instalacji na TV.
