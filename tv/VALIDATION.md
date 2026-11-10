# Walidacja Smart TV

## 2026-11-01 — awaria eksportu katalogu, Samsung Tizen 9

Na QE85QN85CATXXH / Tizen 9 / Chromium 120 (zainstalowana aplikacja 0.1.31)
odtworzono utratę procesu/połączenia inspektora przy `exportCatalog` syntetycznej
listy 1 Live + 20 000 odrębnych seriali, po poprawnym odczycie korzeni. Lokalny
test starego rdzenia potwierdził OOM przy limicie sterty Node 192 MiB.
Poprawiony rdzeń przechodzi ten sam limit, eksportuje 30 647 711 B, odrzuca większy
wariant Unicode i zachowuje modele oraz format schema 1. 14 scenariuszy pełnych
Source przechodzi. Build payloadu przechodzi bramki ES5/CSS.
Końcowe `npm test`: **362/364 PASS, 0 SKIP**; pozostały dwa błędy w niezmienionych
testach wygaszacza AVPlay i cyklu życia (`library.stopPlayback` nieobecne w atrapie).
Nazwy i ograniczenia są zapisane w INSTALL.md; pełna suita nie jest zielona.

Poprawiony kod uruchomiony wyłącznie w pamięci izolowanego workera na fizycznym
TV zakończył scenariusz w 25 próbkach co sekundę; największa próbka sterty JS
wyniosła 59 275 544 B. To nie pomiar całego RAM, test zapisu na dysk ani dowód
trwałej aktualizacji. Nie instalowano WGT i nie usuwano danych. Brakuje starego
profilu autora do podpisania aktualizacji, a checkout ma starszy manifest.
Szczegóły i ograniczenia: [INSTALL.md](samsung_web/INSTALL.md#catalogue-export-crash--fixed-core-tested-in-memory-not-installed-2026-11-01).

## Samsung Web / Tizen 3.0 — aktualizacja 0.1.1 zainstalowana, chmura do odbioru na TV

Data: 25 października 2026. Celem pozostaje
bezpośrednie działanie na Samsungu UE43M5672 / Tizen 3.0 i nowszych. Podpisany
WGT 0.1.1 został zainstalowany i SDB zaakceptował uruchomienie. Użytkownik
potwierdził widoczny UI wcześniejszej wersji 0.1.0; potwierdzenie nowego ekranu
oraz parowanie prawdziwego konta pozostają do odbioru. Onboarding przeszedł test
przeglądarkowy z rzeczywistym kodem i atrapami SDK/HTTP. Nie deklarujemy pełnego 1:1.

Aktualizacja odbioru: użytkownik zgłosił w 0.1.1 ogólny błąd na dole ekranu.
Wynik testów hosta nie potwierdza więc poprawnego startu na tym TV. Podpisaną
0.1.2 z bezpieczną klasą błędu w komunikacie zainstalowano i uruchomiono zwykłym
poleceniem SDK. Web Inspector odmówił startu odpowiedzią `closed`; jego przyczyna
pozostaje nieustalona. [Dowód 0.1.2](output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T112714696448Z/result.json).

| Warstwa | Wynik | Granica dowodu |
| --- | --- | --- |
| Oryginalny Dart | 13 + 10 PASS | 228 deklaracji AST: Source, XMLTV, gate/retry, profile/PIN, parental/resume/supporter, CloudConfig, oryginalne słowniki i reguła startowego wyboru profilu; fizyczne HTTP/IO zastąpione adapterami. |
| Klient i integracja | 91/91 PASS | Rzeczywisty zbudowany rdzeń, panel, chmura i magazyny; atrapy tylko na granicach SDK/HTTP. |
| Wdrożona poprawka API | 11/11 PASS | Izolowana zmiana Origin:null za flagą, rzeczywisty loopback HTTP, zachowane uwierzytelnianie; bez zmian migracji. Produkcja: health 200, preflight 204, profile bez sesji 401. |
| Backend — wcześniejszy pełny zestaw | 60 PASS, 0 FAIL, 33 SKIP | Pominięcia wymagają osobnego PostgreSQL. Relay/server: 21/21 PASS; relay nie jest wdrożony. |
| UI w Chrome | 8 + 4 grupy PASS | Kanały/EPG/VOD oraz język/reload/Back/chmurowy PIN/automatyczne pobranie do Home. Syntetyczny SDK; bez dekodowania mediów lub realnego KeyManager. |
| Pakowanie | 21/21 plików zgodnych | Payload zgodny bajtowo pod podpisami autora i dystrybutora; WGT podpisany. |
| Samsung UE43M5672 | Instalacja 0, uruchomienie 0 | Bieżący DUID dopasowany; aktualizacja 0.1.1 permit/install/run zaakceptowana przez SDB. Widok nowej wersji, prawdziwe parowanie i media pozostają do potwierdzenia. |

[Dowód reużycia](output/samsung-web/core/reuse-proof.json),
[testy rdzenia](output/samsung-web/core/core-test.json),
[testy pełnych Source](output/samsung-web/core/source-test.json),
[końcowy klient 0.1.1](output/samsung-web/client-0.1.1-tests.tap),
[wdrożenie API](output/samsung-web/cloud-api-release/release.json).
Surowy wynik dart2js nie jest ES5; do WGT trafia wynik Babel, sprawdzany ponownie
parserem ES5. Żaden z tych testów nie emuluje całego runtime Chromium M47.

Przeglądarka objęła 161 kanałów M3U i stronicowanie do 80 elementów DOM,
podgląd → pełny ekran → powrót z jednym otwarciem AVPlay, XMLTV/EPG/catch-up,
filmy i serial → sezon → odcinek, ścieżki audio/napisów, tempo/aspekt,
ulubione/historię, ustawienia, ochronę rodzicielską, odmowę/akceptację PIN,
izolację profili oraz Wstecz anulujące rzeczywiste oczekujące XHR.
[Końcowy dowód przeglądarki](../../output/playwright/samsung-full-ui/final-evidence.json)
przypina payload i zrzuty ekranu. Kontrolki testowano klawiszami kierunkowymi,
OK i Wstecz; nie fizycznym pilotem.

Payload: `payload-20261025T105610538Z`.
[Manifest 0.1.1](output/tizen-builder/20261024/samsung-web/20261025T105706658115Z/payload-build.json) SHA256
`71f44f0f2f610865ea7fb5b8bc75b0c0afeb69f85b8345112e90c76f53070130`.
Rdzeń: `52eb6fedb5d99da9862c6f1a553c4fa4a9e3def4931a38c385d73a045ab5131d`.

[Końcowy podpisany WGT 0.1.1](output/tizen-builder/20261024/samsung-web/20261025T105706658115Z/TVBro.wgt):
**3 056 489 B**, SHA256
`70d961f2defaf877b217c59bb9d571bdd4c4571e8cf22af8809212c8d79029b1`.
Podpisy autora i dystrybutora obejmują ten sam zestaw 21 plików payloadu.
[Dowód pakowania](output/tizen-builder/20261024/samsung-web/20261025T105706658115Z/proof.json)
i [wynik instalacji/uruchomienia](output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T105706658115Z/result.json).
Wcześniejsza próba niepodpisanym WGT zakończyła się `install failed[118]`; jej
[artefakt i dowód](output/tizen-builder/20261024/samsung-web/20261024T223246602660418/proof.json)
pozostają historyczne.

Zaadaptowano DOM, transport, stan KeyManager oraz AVPlay; Flutterowe widgety,
CloudSync, LibraryRepository/SQLite i dyskowy cache nie są wykonywane. Nie
kwalifikowano DVR, pobierania mediów offline ani pełnej parzystości desktopu.
API/Panel pochodzą z oryginalnego CloudConfig: `api.tvbro.online` / `tvbro.online`.
Poprawkę API `ba0d2ef` i flagę `SAMSUNG_TV_ENABLED=true` wdrożono w Coolify za
zgodą użytkownika. Opcjonalny relay pozostaje niewdrożony i wyłączony.
Rozłączenie chmury zachowuje dane lokalne. Androida, Windowsa i ich zależności
nie zmieniał zespół tego etapu; równoległe zmiany innych zadań zachowano.

Pozostałe kroki odbioru: potwierdzić onboarding prawdziwego konta, pilot,
odtwarzanie, dźwięk i trwałość
stanu na TV. Profil certyfikatu Samsung dopasowano do bieżącego DUID; permit,
instalacja i polecenie startu zakończyły się kodem 0. Użytkownik potwierdził
widoczny, działający UI TVBro; pełny runtime nie jest jeszcze zakwalifikowany.
Użytkownik
utworzył konto i zalogował się do panelu Samsung Developer. TV odnaleziono
w LAN po dokładnym dopasowaniu MAC ze zdjęcia do ARP. Po włączeniu Developer
Mode i restarcie TV połączenie SDB z `192.168.10.53:26101` działa: urządzenie
zgłasza `UE43M5672`, platformę `3.0`, a DUID odczytano bezpośrednio z TV.
Wcześniejszą odmowę połączenia zachowano jako wynik historyczny.

Wcześniejszą próbę instalatora przerwał błąd SDK przy rozpakowywaniu w katalogu
tylko do odczytu; później TV odrzucił niepodpisaną paczkę jako
`install failed[118]`, exit 1. [Log tej próby](output/tizen-builder/20261024/samsung-device-20261025/install-writable-unsigned.log)
pozostaje zachowany. Bieżący, podpisany WGT zainstalowano i polecenie startu
zwróciło exit 0. [Logi permit/install/run](output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T105706658115Z/)
oraz stan i artefakt zapisuje
[końcowa kwalifikacja](output/samsung-web/final-qualification.json).
Braki pełnego 1:1 są opisane w [52 obszarach UI](output/samsung-web/parity/ui-parity-ledger.json)
oraz [39 obszarach runtime](output/samsung-web/parity/runtime-parity-ledger.json);
inwentaryzacje są datowanymi audytami kodu, a nie deklaracją ukończenia.
Zwykłego WGT nie instaluje się z USB;
osobny USB Demo wymaga pakietu TMG i licencji z Seller Office. Publiczna
publikacja pozostaje osobnym odbiorem Samsung.
[Zakres](samsung_web/README.md), [instalacja](samsung_web/INSTALL.md).

## Historyczna kwalifikacja R02 na hoście

Data: 24 października 2026. **Ostatnia pełna kwalifikacja: 19/19 testów
zaliczonych, bez pominięć**; runner zakończył się kodem 0. Wszystkie cztery fazy
mają status `succeeded`; żadne z 45 wybranych chronionych wejść nie zmieniło się
podczas próby. [Zachowane dowody](output/continuation-20261024/verified-19-bootstrap/evidence.json)
dotyczą hashy z tego przebiegu, nie późniejszych równoległych zmian checkoutu.
Poprzedni błąd `_firstString` został usunięty w równoległym zadaniu; nie wymagał
edycji współdzielonego kodu przez zespół TV.

| Faza | Wynik | Co sprawdzono |
| --- | --- | --- |
| Rdzeń i oryginalny EPG | 16/16 | Dotychczasowe 3 próby źródeł oraz 13 testów istniejącego `test/epg_grid_test.dart`, uruchomionych bez kopiowania pliku. |
| Zapis storage | 1/1 | Produkcyjne `AppDatabase.open()` i obecne magazyny danych, z rzeczywistą wtyczką DPAPI hosta. |
| Odczyt storage | 1/1 | Drugi proces odtwarza konfigurację, profil, sesję i zaszyfrowany cache; sprawdza też usunięcie sesji. |
| Start aplikacji i istniejący UI | 1/1 | Wejście TV wywołuje oryginalne `main()`, inicjalizuje MediaKit i przechodzi przez rzeczywiste ekrany do zapisu źródła. |

## Co wykonuje harness

[Scenariusze](native_probe/test/reuse_test.dart) importują oryginalne pliki przez `package:iptvs`; nie zawierają kopii parsera, fabryki, tożsamości ani repozytorium.

- Oryginalne `SourceConfig` serializuje i odtwarza konfigurację, a `build()` tworzy źródła wszystkich czterech rodzajów. Dla Demo i Stalker potwierdzono konstrukcję; transport tych providerów nie jest testowany.
- Oryginalne M3U źródło pobiera syntetyczną playlistę z loopback HTTP. `LibraryRepository` zapisuje i odczytuje kanały z `AppDatabase.openAt()`, sprawdzane są stabilna tożsamość, ukrycie zapisanego adresu w cache i jego odszyfrowanie przy `resolve()`. Świeże źródło odczytuje cache bez kolejnego żądania do providera.
- Oryginalne Xtream źródło obsługuje syntetyczne uwierzytelnienie oraz katalogi live, filmów i seriali. Test sprawdza mapowanie pozycji i rozwiązywanie adresów live oraz filmu. Nie pobiera ani nie odtwarza mediów; nie testuje szczegółów i odcinków serialu.
- Oryginalny `EpgGridScreen` wykonuje istniejące testy wyboru audycji, nawigacji kierunkowej, fokusu, szczegółów i semantyki dostępności. Nie dodano drugiego ekranu ani modelu nawigacji.
- `SourceStore`, `LocalProfileStore`, `SecureLocalStorage`, `AppDatabase.open()` i `SecretLocatorVault` wykonują rzeczywisty zapis/odczyt przez obecną wtyczkę `FlutterSecureStorageWindows`. Jedyny adapter testowy kieruje `path_provider` do nowego katalogu `storage-<guid>` wewnątrz ignorowanego outputu TV. Nie zmieniono wtyczki ani jej kryptografii.
- [Wejście TV](app/main.dart) ma trzy linie i deleguje do istniejącego `package:iptvs/main.dart`. [Próba startu](native_probe/test/bootstrap_reuse_test.dart) wykonuje rzeczywiste `main()` i trasę `IptvApp → LanguageSelectionScreen → ProfilePickScreen → HomeShell → SourcesScreen → EditSourceScreen → SourceStore.save`. Nie zastępuje inicjalizacji ani nawigacji własnym UI.

Procesy zapisu i odczytu miały różne PID, zapisane w dowodach obu faz. Drugi
odczytał trwały klucz przez wtyczkę jeszcze przed otwarciem bazy i odszyfrował
zapisany kanał przez oryginalne
`LibraryRepository.resolve()`. Bezpośredni odczyt klucza i oddzielny proces
wykluczają pozorny sukces oparty na pamięciowym fallbacku vaulta. Konfiguracja,
metadane, adresy i sesja są syntetyczne; nie korzystano z kont ani danych użytkownika.

Bootstrap używa osobnego `bootstrap-<guid>` i rzeczywistego hostowego DPAPI.
Ładuje istniejące libmpv; API biblioteki zwróciło `131078`. Oryginalne logo i trzy
fonty Inter są automatycznie stage'owane z deklaracji root pubspec pod tymi samymi
kluczami assetów i sprawdzane hashami; test ładuje też rzeczywiste MaterialIcons.
Nie dodano ręcznie utrzymywanych kopii zasobów. [Podgląd Sources 1280×720](output/continuation-20261024/verified-19-bootstrap/sources-1280x720.png)
pokazuje normalny szeroki układ hosta, z zapisanym syntetycznym źródłem M3U.

Chmura jest wyłączona istniejącym define `TVBRO_CLOUD_ENABLED=false`, kanał to
`development`, a licznik prób połączeń HTTP wyniósł **0**. Po próbie usunięto UI,
zamknięto scheduler DVR, jego lokalny serwer, cache obrazów i bazę; dowód zapisuje
`cleanupCompleted=true`. Nie otwarto transmisji ani konta użytkownika.

## Granice dowodu

To wykonanie w Flutter VM na hoście. Pierwotne trzy testy nadal używają
`AppDatabase.openAt()`, atrapy secure storage i resetu bramki żądań dla fixture.
Oryginalne testy EPG używają swojego testowego setupu FFI. Osobne fazy storage
wykonują produkcyjne `open()` i rzeczywiste DPAPI, bez atrapy magazynu; na tym
hoście `open()` wybiera FFI. Wymuszenie testowego `TargetPlatform.windows`
odpowiada rzeczywistemu hostowi i zapobiega wyborowi AndroidOptions przez
`FLUTTER_TEST`; nie symuluje tożsamości Tizena ani telewizora.

Potwierdzono trwałość danych, wykonanie oryginalnego `main()` i wskazaną trasę UI
na hoście, z rzeczywistą inicjalizacją MediaKit. Nie potwierdzono wyboru bazy ani
secure storage TV, pełnej orkiestracji wszystkich ekranów, usług chmury,
odtwarzania, fizycznego pilota, lifecycle TV, rejestracji wtyczek natywnych,
podpisywania ani zgodności urządzeń. Nie wykonano
natywnego builda klienta Tizen ani testów na telewizorze. R02, R03 i odbiór sprzętowy
pozostają otwarte.

W tej kwalifikacji `lib/`, `pubspec.yaml`, `pubspec.lock`, Android i Windows były dla zespołu TV tylko do odczytu. Dowody każdej próby zapisują hashe sprawdzonych wejść i ich zmiany podczas przebiegu.

Analiza zakresu TV nie zgłasza błędów, ale nie jest całkowicie czysta:
11 ostrzeżeń `visibleForTesting` dotyczy położenia testów; 7 informacji dotyczy
importów wtyczek wobec root pubspec, a jedna stylu zapisu w teście storage.
Wtyczki są zadeklarowane
w wygenerowanym projekcie próby; nie zmieniano zależności właściciela ani nie
wyciszano diagnostyki. [Polecenie i transkrypt](output/continuation-20261024/verified-19-bootstrap/scoped-analyze.log).

Raport obejmuje tę pracę kwalifikacyjną, nie cały współdzielony checkout. Pojawiły się w nim równoległe zmiany onboardingowe; nie są częścią ani wynikiem pracy TV. Zespół tego zadania nie edytował kodu Androida ani Windowsa.

Wynik dotyczy wersji plików zapisanych hashami w `evidence.json` z czasu próby.
Późniejsze równoległe zmiany źródeł w tym checkoutcie nie są automatycznie
objęte wcześniejszym wynikiem.

## Blokada Tizena

Sprawdzony aktualny pin `flutter-tizen` wskazuje Flutter `3.47.5` i Dart `3.13.4`.
Obecny TVBro wymaga Dart `^3.13.5`, więc domyślny zestaw nie spełnia wymagań
aplikacji. Nie obniżano wymagania Dart ani nie zmieniano zależności.

[Powtarzalna próba SDK](sdk_probe/README.md) kompiluje oryginalną fabrykę źródeł
i tożsamość treści frontendem 3.13.5. Oficjalny kompilator Tizena 3.13.4 odrzuca
otrzymany kernel kodem 254 i dosłownym `ApiError`; użycie oryginalnych bibliotek
platformy nie pomaga. Kontrola zgodnym kompilatorem 3.13.5 tworzy ARM ELF.
To kontrola kompilatora, bez uruchomienia na TV, linkowania wtyczek ani TPK.
Raport SDK odróżnia zmierzony wynik od wniosku o niezgodności SDK hash.
Pozostałe granice R02 opisuje [raport kwalifikacji](native_probe/QUALIFICATION.md).

Osobny tryb `tv/sdk_probe/run.ps1 -EntryPoint Application` skompilował to samo
wejście TV i pełne oryginalne `main()` frontendem 3.13.5 oraz zgodnym kompilatorem
kontrolnym ARM. Depfile wskazuje **145 oryginalnych plików Dart**; 151 chronionych
hashy pozostało bez zmian. To kompilacja kontrolna bez użycia kompilatora Tizena,
linkowania wtyczek/native assets, wykonania artefaktu ani TPK. Dalsza budowa
zgodnego silnika Tizen wymaga Linux buildera i miejsca na wielogigabajtowe
zależności. Po zleceniu naprawy uruchomiono `TVBro-Builder` na G: z Ubuntu 24.04
i lokalnym Docker Engine; stara rejestracja Ubuntu pozostała zachowana.
Dowody naprawy są w `output/wsl-repair-20261024/`; dalszą kwalifikację własnego
silnika prowadzi [builder TV](engine_builder/README.md).

## Własny silnik Tizena z Dart 3.13.5 — wykonana budowa

Naprawione WSL uruchamia domyślnie `TVBro-Builder` (Ubuntu 24.04 na G:).
Start Linuksa, lokalny Docker Engine 29.9.2 i kontener `hello-world` przeszły.
[Dowód naprawy](output/wsl-repair-20261024/repair-evidence.json) potwierdza
zachowanie wcześniejszych rejestracji Ubuntu i Docker Desktop. Brakującego
dysku starego Ubuntu nie odnaleziono; jego danych nie odzyskano.

[Builder](engine_builder/README.md) zbudował w osobnym checkoutcie silnik Tizena
`a0e550d2` z Dartem `04bcd1036c` (3.13.5), przypiętym obrazem CI i sysrootem
Tizen 6.0. Zmieniono pin Darta, wyłączono zbędne pobieranie SDK i zastosowano
dwie poprawki flag kompilatora z oficjalnego CI. **Budowa 6611 kroków oraz
próba AOT zakończyły się kodem 0.** Kompilacja zajęła około 7 min 45 s przy
8 zadaniach; workspace ma 9,7 GiB, a w Linux ext4 pozostało około 223 GiB.

| Artefakt | Wynik |
| --- | --- |
| `libflutter_engine.so` | Zbudowany runtime ARM ELF32, machine 40; 10 045 816 B. |
| `gen_snapshot` | Wykonany kompilator Linux ELF64 x86_64; zgłasza Dart 3.13.5 stable. |
| `application-tizen-arm.so` | Pierwsza próba ARM ELF32, machine 40; 12 517 960 B, z niezmienionego kernela oryginalnej aplikacji. |
| `application-tizen-arm-qualified.so` | Osobna próba z oficjalnymi flagami ARM Tizena: 12 534 344 B; ELF32, ET_DYN, machine 40, soft-float. |
| `icudtl.dat` | Zachowany plik ICU z tego samego checkoutu silnika. |

Kontrola użyła wcześniejszego `Application` kernela (145 oryginalnych plików
Dart), montowanego tylko do odczytu i sprawdzanego SHA-256 przed/po kompilacji.
Nie edytowano obecnego `lib/`, zależności ani platform Android/Windows.
To **własny** zestaw silnika/kompilatora, a nie nowe oficjalne wydanie SDK.
W tej próbie silnika nie uruchamiano runtime ARM, nie linkowano wtyczek aplikacji
ani nie budowano TPK. Późniejszą kwalifikację pakowania opisuje następna sekcja.
Testów na TV nie wykonywano; R02 pozostaje otwarte dla runtime.

Pełny [dowód końcowy](output/engine-builder/20261024/completed/evidence/runs/20261024T172727589059Z/evidence.json)
zawiera komendy, wersje, hashe i wyniki faz; zachowano także wcześniejsze dwie
nieudane próby walidatora/narzędzia oraz ich poprawki.
[Wejścia sysroot](output/wsl-repair-20261024/sysroot-rpms.json) zapisują hashe
33 rzeczywistych pakietów RPM.

[Audyt struktury](output/engine-builder/20261024/audit/readelf-audit.log)
potwierdził eksporty runtime `FlutterEngineRun/Shutdown`, wymagane dwa symbole
snapshotu AOT i wszystkie hashe kopii artefaktów. Wykazał też brak dwóch
oficjalnych flag ARM w pierwszej próbie. Osobna, wykonana
[kwalifikacja ARM Tizena](output/engine-builder/20261024/tizen-aot-qualified/evidence.json)
użyła `--no-sim-use-hardfp` i `--no-use-integer-division`; zakończyła się kodem 0,
z flagami ELF soft-float zgodnymi z silnikiem i wymaganymi eksportami snapshotu.
Kernel, kompilator, runtime i pierwszy artefakt pozostały niezmienione;
pierwszy wynik zachowano oddzielnie. Nowy runner zapisuje rzeczywiste opcje
kompilacji i stosuje obie flagi w nowych kontrolach. Zgodność tych flag
nie rozstrzyga pełnego ABI urządzenia ani wykonania aplikacji.

## Projekt C# i pierwszy podpisany TPK kwalifikacyjny

[Generator](tizen_app/README.md) wykonał oficjalne C# `create`, odtworzył seed
lock po nadpisaniu przez szablon, uruchomił zwykłe `pub get` wyłącznie we wrapperze
i zweryfikował zachowanie wspólnych wersji/źródeł pakietów. Wygenerowany projekt
ma TV/API 6, `tizen60`, etykietę TVBro, oryginalną ikonę i cztery Flutter assets.
Wejście nadal wskazuje `/owner/tv/app/main.dart → package:iptvs/main.dart`.
Nie utworzono drugiego UI, repozytoriów ani parserów aplikacji.

Managed restore oraz dwa rzeczywiste wywołania Csc przeszły z **0 błędów
i 0 ostrzeżeń**. Runner używa API 6; SDK wybrał zgodny referencyjny target
embeddingu `tizen40`. Narzędzia działają w dedykowanym kontenerze WSL:
Linux Flutter 3.47.7/Dart 3.13.5, .NET 8.0.426, Tizen clang 10.0.0,
rootstrap API 6 i zweryfikowany CUSTOM cache silnika ARM.

Pierwszy przebieg ujawnił, że domyślny hook `sqlite3 3.7.1` dołącza ogólny
Linux ARM hard-float. SDK Tizena używa soft-float. Jawny adapter wyłącznie
w wygenerowanym pubspec ustawia Linux `source: system` i
`name: /usr/lib/libsqlite3.so.0`, sprawdzając [dowód SDK](output/tizen-app/20261024/sqlite-audit/proof.json).
Zachowano istniejący `AppDatabase`/FFI i jego logikę wyszukiwania; nie dodano
nieużywanej fabryki `sqflite_tizen`. Biblioteka systemowa SDK to SQLite 3.31.1.
Runtime, FTS oraz opcjonalne API status/session/changeset pozostają otwarte.

Podczas około 45-sekundowej kompilacji inne zadanie zmieniło pięć plików
wspólnego checkoutu. Guard zachował różnice zamiast cofać cudze zmiany.
[Odczyt rzeczywistego kernela](output/tizen-app/20261024/native-provenance/report.json)
potwierdził **141 niepustych źródeł `/owner` zgodnych bajtowo z hashami T0**,
w tym wszystkie pięć później zmienionych plików. Sześć chronionych plików Dart
nie ma wpisu w mapie źródeł kernela; nie przypisujemy im dowodu embedded bytes.
Pakiet jest związany z przechwyconym kernelem i zapisanym zestawem wejść.
Późniejsze zmiany checkoutu mają osobny stan walidacji.

Po naprawie rzeczywistego headless Secret Service SDK podpisano gotowy payload
tym samym zadaniem `Sign` z Tizen.NET.Sdk 1.1.7, bez ponownej kompilacji Dart.
**Podpis i pakowanie: exit 0**, 33 pliki payloadu zgodne hashami przed/po
i wewnątrz archiwum, `author-signature.xml` oraz `signature1.xml` obecne.
P12, hasła i zaszyfrowany keyring pozostały wyłącznie w prywatnym katalogu
narzędzi Linux; klucza nie skopiowano do projektu ani pakietu.

- TPK: `org.tvbro.tvbro_tizen-1.0.7.tpk`, **15 962 781 B**.
- SHA-256: `be2df80fca1d3cb3978f0372b1f991b769680b496262f100fa01bed7168101bf`.
- [Dowód pakowania i hashy](output/tizen-app/20261024/signed-tpk/audit.json).
- [Managed compile](output/tizen-app/20261024/attempt-02/native/dotnet-compile/summary.json).
- [Naprawiony odczyt certyfikatów SDK](output/tizen-builder/20261024/signing-interop-20261024T194358.json).

[Niezależny audyt TPK](output/tizen-app/20261024/final-audit/proof.json)
potwierdził wszystkie 33 pliki payloadu, profil TV/API 6, etykietę, ikonę
i cztery oryginalne Flutter assets. Cztery natywne ELF-y mają ARM32 soft-float;
silnik jest zgodny bajtowo z kwalifikowanym CUSTOM SDK. Manifest native assets
wskazuje systemowe `/usr/lib/libsqlite3.so.0`; w archiwum nie ma biblioteki
SQLite dołączonej jako plik. **Oba podpisy XML RSA-SHA512 są poprawne**,
z prawidłowymi digestami wszystkich referencji: author 33/33, distributor 34/34.
Kontrola nazw wpisów nie wykazała źródeł `.dart` ani plików kluczy/haseł;
publiczne certyfikaty stanowią część podpisów.

To lokalnie podpisany pakiet kwalifikacyjny. Nie uruchamiano aplikacji na TV
ani emulatorze TV i nie wykonywano publikacji. Główne otwarte granice to
MediaKit/libmpv i renderer/podgląd, rozpoznanie urządzenia TV, pilot/lifecycle
oraz runtime storage. Kodu Androida, Windowsa ani wspólnego `lib/` nie zmieniano
w ramach tej pracy; środowisko narzędziowe i pliki TV są odizolowane.

## Artefakty i wcześniejszy prototyp

- [Log 100 testów oryginalnych modułów panelu](output/reuse-module-tests.tap) jest osobnym, zachowanym wynikiem; nie jest częścią tych 19 testów.
- Rdzeń/EPG: [log](output/continuation-20261024/verified-19-bootstrap/test.log) i [wyniki maszynowe](output/continuation-20261024/verified-19-bootstrap/tests.jsonl).
- Storage: [zapis](output/continuation-20261024/verified-19-bootstrap/storage-write.log), [odczyt](output/continuation-20261024/verified-19-bootstrap/storage-read.log), [dowód zapisu](output/continuation-20261024/verified-19-bootstrap/storage-write-evidence.json) i [odczytu](output/continuation-20261024/verified-19-bootstrap/storage-read-evidence.json).
- Bootstrap: [log](output/continuation-20261024/verified-19-bootstrap/bootstrap.log), [dowód UI/cleanup/sieci](output/continuation-20261024/verified-19-bootstrap/bootstrap-evidence.json), [hashe assetów](output/continuation-20261024/verified-19-bootstrap/asset-staging.json) i [zbiorczy dowód 19/19](output/continuation-20261024/verified-19-bootstrap/evidence.json).
- SDK: [końcowy dowód kompilacji](output/sdk-probe/20261024T103452136Z-tizen-pinned-platform/evidence.json), wraz z komendami, nagłówkami i hashami.
- Pełne `main()` — kompilacja kontrolna ARM: [dowód grafu i hashy](output/sdk-probe/20261024T134658985Z-application-main-stable/evidence.json).
- Dawne 162 testy JavaScript, siedem prób Chrome i raport klienta opisują prototyp z commitu `d3ef714ba835ed91375ceebc1e1e231ce8d98b48`, a nie obecną funkcjonalność TVBro. Wygenerowane IPK, zrzuty i logi były ignorowanymi artefaktami lokalnymi i zostały usunięte; nie są przechowywane w Git.

## LG 0.1.33 — cache i przygotowanie biblioteki jak w Androidzie (2026-11-08)

LG zapisuje pełne katalogi live/filmów/seriali jako atomowe, szyfrowane generacje
z ograniczonymi fragmentami i kompresją. Pierwsze użycie przygotowuje trzy sekcje
oraz próbę EPG; kolejne wejścia pokazują zapisane dane przed odświeżeniem w tle.
Katalog używa 24 godzin, EPG sześciu godzin od rzeczywistego pobrania. Pobrane
szczegóły i odwiedzone strony dzieci są zachowane w ograniczonym cache; nieudane
odświeżenie zachowuje poprzednie dane. Klienci i reguły scalania metadanych
pochodzą z oryginalnego kodu Darta; LG ma ograniczony transport HTTPS tych API.

Końcowe testy: **460/460 wspólnych**, **83/83 LG**, **28/28 referencyjnych
Androida**. Osobne próby rdzenia obejmują segmenty, Unicode, CRC, atomowy import,
pamięć po kolejnych odświeżeniach, szczegóły Xtream offline i terminy EPG z
pamięci oraz natywnych plików. Przegląd Luna max nie pozostawił otwartych uwag.

Dostarczoną listę pobrano raz (14 338 008 B, 48 973 wpisy), a dalsze próby używały
wyłącznie lokalnej kopii chronionej DPAPI. Oryginalny parser rozpoznał 803 kanały,
0 korzeni filmów i 1 524 korzenie seriali. Nowy zapis zajmował około 11 MB
szyfrogramu; nowy proces odtworzył kanały, sezony i odcinki bez pobierania listy.
Testy Chrome na spakowanym payloadzie potwierdziły restart, ulubione, Wstecz 461,
fokus, szczegóły filmu oraz sezony i odcinki z cache. Ruch poza lokalnym serwerem
był blokowany; brak PalmServiceBridge na hoście nie kwalifikuje natywnej usługi.

Oficjalny packager utworzył
[`online.tvbro.webos_0.1.33_all.ipk`](output/lg-webos/package-20261108T160623145Z/online.tvbro.webos_0.1.33_all.ipk).
SHA-256: `adfc99c5e0cfa3c8e2b7a1d573c906041435b52ece3c8c8263d3b90c0d55a525`.
Kontrola archiwum potwierdziła 34 pliki aplikacji i 6 plików usługi zgodnych
z hashami kwalifikowanego buildu. ES5/CSS i kontrola oryginalnych źródeł przeszły.
Nie instalowano paczki na fizycznym LG, nie testowano rzeczywistego EPG dostawcy
ani dekodowania na TV i nie wykonywano publikacji/certyfikacji.

## Audyt i naprawy — 9 listopada 2026

Końcowy [raport, paczki i ograniczenia](../output/remediation-2026-11-09/WDROZENIE.md)
obejmuje Windows/Android 1.0.10+2011, Samsung Web 0.1.37, LG 0.1.35 i Titan 0.1.2.
Flutter: 135 zaliczonych i 51 pominiętych zależnie od platformy; analiza lib/test
bez uwag. Wspólne testy TV: 574/574. Rdzeń: 306 deklaracji, 16 prób źródeł oraz
próby segmentów i metadanych. Poprawiono izolację i migrację cache, odczyt przy
odmowie zapisu, format odpowiedzi Workera, diagnostykę i wskazane problemy UI.

Spakowane UI przeszły syntetyczne próby w Chrome: Samsung 12 scenariuszy;
LG/Titan 161 kanałów, zmiana nazwy i restart bez ponownego pobrania listy.
Titan zachował wymóg HTTPS; testował sztuczne HTTPS mapowane na 127.0.0.1,
nie rzeczywiste TLS/CORS dostawcy. Oba podpisy Samsunga i hashe paczek są
zweryfikowane. Samsung UE43M5672/Tizen 3 potwierdził 0.1.37, dwa oryginalne
profile i PIN oraz zdarzenia góra/dół. Nie odinstalowywano ani nie kasowano danych.
TV pozostawiono na PIN; nie otwierano dostawcy ani strumienia.

Nie kwalifikowano fizycznego LG/Philips/Androida, dekoderów ani długiej pracy.
Nagrywanie i pozostałe różnice opisuje [macierz funkcji](../docs/platform-capabilities.md).
Nie publikowano tych paczek. Historyczne logi nieudanych kandydatów zachowano.
