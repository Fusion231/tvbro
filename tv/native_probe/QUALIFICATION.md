# Kwalifikacja natywnego Flutter TV — R02

Data: **24 października 2026**. Status: **R02 otwarte**. Wykazano możliwość
wykonywania wskazanych oryginalnych modułów Dart na hoście; nie wykazano
kompilacji ani uruchomienia obecnego TVBro na Tizen. Nie zmieniono wspólnego
`lib/`, zależności aplikacji, Androida ani Windowsa. Nie instalowano pełnego SDK
TV i nie wykonywano testów na TV. Dwa małe, zweryfikowane artefakty kompilatora
i bibliotek SDK pobrano wyłącznie do ignorowanego `tv/output/sdk-probe/`.

## Dowód hostowy i jego granice

[Harness](README.md) oraz [jego scenariusze](test/reuse_test.dart) importują
oryginalne pliki przez `package:iptvs`. Obejmują istniejący `SourceConfig.build`,
źródła M3U/Xtream, `LibraryRepository` i `AppDatabase`; odpowiedzi HTTP są
syntetyczne i obsługiwane przez serwer loopback. Runner uruchamia też bez kopii
13 istniejących testów `test/epg_grid_test.dart`. [Osobne fazy storage](test/storage_reuse_test.dart)
wykonują oryginalne `AppDatabase.open()`, `SourceStore`, `LocalProfileStore`,
`SecureLocalStorage` i vault przez obecną wtyczkę Windows DPAPI, w nowym
katalogu pod `tv/output/native-probe/`. Odczyt następuje w drugim procesie,
z trwałym kluczem i rzeczywistym odszyfrowaniem cache. Czwarta faza korzysta z
[wejścia TV](../app/main.dart), które deleguje do oryginalnego `main()`.
Rzeczywisty MediaKit, inicjalizacja i istniejące ekrany prowadzą od języka,
przez profile i Home, do Sources oraz zapisu M3U przez oryginalny formularz.
Ostatni pełny wynik to **19/19** dla hashy zapisanych w zachowanym dowodzie.
Szczegóły są w [walidacji](../VALIDATION.md) i artefaktach runnera.

Pierwotne trzy próby nadal korzystają z `AppDatabase.openAt()` i
`FlutterSecureStorage.setMockInitialValues()`. Oddzielne fazy storage mają
rzeczywisty plugin hosta i `open()`, które na Windows nadal wybiera FFI.
Nie dowodzą wyboru bazy ani trwałego magazynu na Tizenie. Oryginalny EPG
kwalifikuje wskazany widget i logiczne klawisze Fluttera; nowy bootstrap wykonuje
oryginalne `main()` na hoście, z `isTelevision=false`, wyłączoną chmurą,
zerem prób połączeń HTTP i poprawnym zamknięciem DVR/bazy. Pełna orkiestracja
wszystkich ekranów, chmura, odtwarzanie, fizyczny pilot, cykl życia TV,
rejestracja pluginów Tizen, podpisywanie i TPK pozostają poza tym dowodem.
Nie zamyka to R02, R03 ani odbioru sprzętowego. Odczyt adresu strumienia nie jest
próbą odtwarzania.

## SDK: konkretny blok wersji

Stan upstream zamrożono na
[`flutter-tizen` `22bcec9058fbe1e0943e6c6fda21792f24868e91`](https://github.com/flutter-tizen/flutter-tizen/commit/22bcec9058fbe1e0943e6c6fda21792f24868e91).

| Element | Ustalony stan | Wniosek |
| --- | --- | --- |
| Obecne TVBro | `pubspec.yaml`: Dart `^3.13.5`; `pubspec.lock`: Dart `>=3.13.5 <4.0.0`, Flutter `>=3.47.0`. | Wymagania obecnej aplikacji pozostają bez zmian. |
| Lokalny SDK hosta | `evaluation/tooling/flutter/bin/cache/flutter.version.json`: Flutter `3.47.7`, Dart `3.13.5`. | Odpowiedni do opisanej próby hostowej; nie jest SDK Tizen. |
| Framework Flutter for Tizen | [Pin](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/bin/internal/flutter.version) wskazuje `6a19cca56475dbfba1478ee68d7bd0c2ef891da1` — Flutter `3.47.5`. Jego [DEPS](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/DEPS) wskazuje Dart `b530c21f7de367b94fb04787bfed9d8e989d75e8`. | Sam numer Flutter nie wystarcza do potwierdzenia zgodności. |
| Engine Tizen | [Pin](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/bin/internal/engine.version): `a0e550d2b728d26d86bdbd981b33c9e9de7a656b`; jego [DEPS](https://github.com/flutter-tizen/flutter/blob/a0e550d2b728d26d86bdbd981b33c9e9de7a656b/DEPS) wskazuje ten sam Dart `b530c21…`. | Trzeba kwalifikować framework, engine i narzędzia razem. |
| Dart z tych pinów | [Oficjalny `tools/VERSION`](https://github.com/dart-lang/sdk/blob/b530c21f7de367b94fb04787bfed9d8e989d75e8/tools/VERSION): stable **3.13.4**. | **Nie spełnia `^3.13.5` TVBro.** Niezmieniona aplikacja nie rozwiąże zależności z tym SDK. |

Nie znaleziono `flutter-tizen`, `tizen` ani `sdb` w PATH. Sprawdzone lokalizacje
`C:\tizen-studio`, `D:\tizen-studio`, `C:\flutter-tizen`, `D:\flutter-tizen`,
`C:\Users\Maciej\{tizen-studio,flutter-tizen,.tizen-extension-platform}` oraz
`evaluation/tooling/{tizen-studio,flutter-tizen}` nie istnieją. Nie znaleziono też
`tizen-arm-release` w cache engine lokalnego Fluttera. To wynik ograniczonego
sprawdzenia tych miejsc, nie inwentaryzacja całego komputera.

[Oficjalny zakres](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/README.md)
obejmuje Smart TV z Tizen 6.0 i nowszym; nie oznacza zgodności TVBro.
[Instrukcja Windows](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/doc/windows-install.md)
wskazuje narzędzia Tizen osobno od zwykłego Flutter SDK.

### Rzeczywista próba kompilacji z nowszym frontendem

[Próba SDK](../sdk_probe/README.md) sprawdziła aktualne oficjalne wydania oraz
kompilację oryginalnego `SourceConfig.build`, providerów i tożsamości treści.
Frontend Dart 3.13.5 utworzył kernel formatu 138 z SDK hash `04bcd1036c`.
Oficjalny kompilator ARM Tizena 3.13.4 odrzucił go kodem 254 i komunikatem
`ApiError`. Użycie oryginalnych bibliotek platformy z przypiętego frameworka
Tizena dało ten sam wynik. Kontrola kompilatorem 3.13.5 na dokładnie tym samym
kernelu utworzyła poprawny ARM ELF; ten artefakt kontrolny nie jest buildem TV.

Źródła Darta sprawdzają również SDK hash; jego rozbieżność jest popartym kodem
wnioskiem o przyczynie odrzucenia, a nie dokładniejszym komunikatem narzędzia.
Próba nie zmieniała hashy, ograniczeń SDK ani kodu aplikacji. Nie znaleziono
opublikowanego nowszego, zgodnego zestawu w sprawdzonych oficjalnych wydaniach.
Potrzebny jest zgodny komplet frontend–kompilator–runtime Tizena, następnie
osobna kwalifikacja wtyczek i pakowania. Samo podłączenie nowszego CLI hosta
nie rozwiązało tej granicy. Piny, sumy kontrolne, komendy i logi są w raporcie SDK.

Osobny tryb `-EntryPoint Application` tej samej próby skompilował
`tv/app/main.dart → lib/main.dart` zgodnym frontendem i kontrolnym kompilatorem
ARM 3.13.5. Depfile obejmuje 145 oryginalnych plików Dart; 151 hashy źródeł
i metadanych pozostało bez zmian. Nie użyto kompilatora ani runtime Tizena,
nie linkowano wtyczek i nie wykonywano tego artefaktu. Docelowe rozwiązanie
wymaga zgodnego silnika Tizen; jego budowa ze źródeł potrzebuje działającego
Linux buildera i miejsca na zależności. Po zgodzie na naprawę WSL uruchomiono
osobną dystrybucję `TVBro-Builder` (Ubuntu 24.04) na G: i lokalny Docker Engine.
Stara rejestracja Ubuntu została zachowana; jej brakującego dysku nie odzyskano.
Budowa zgodnego zestawu jest prowadzona osobno przez
[builder TV](../engine_builder/README.md), bez zmian aplikacji.
Budowa własnego silnika i kompilatora Dart 3.13.5 zakończyła się powodzeniem;
nowy `gen_snapshot` skompilował niezmieniony kernel pełnej aplikacji do ARM AOT.
Usuwa to zmierzoną blokadę wersji dla tego własnego zestawu. Nie kwalifikuje
jeszcze wtyczek, wykonania runtime, pakietu TPK ani urządzenia; wynik opisuje
[walidacja](../VALIDATION.md).

## Pluginy: deklaracje zgodne zakresami, wykonanie niezakwalifikowane

Poniżej stan
[`flutter-tizen/plugins` `a16990269f9f9631412661c4fe7696ef8bca558d`](https://github.com/flutter-tizen/plugins/commit/a16990269f9f9631412661c4fe7696ef8bca558d).
Zgodność zakresu wersji nie dowodzi rejestracji, działania ABI ani obsługi funkcji.
Implementacje Tizen są nieendorsowane: wymagają osobnych zależności w docelowym
projekcie TV. Obecnego manifestu TVBro nie zmieniamy.

| Obecny lock TVBro | Kandydat Tizen i jego zależność | Ocena deklaracji |
| --- | --- | --- |
| `sqflite 2.4.4+2` | [`sqflite_tizen 0.1.6`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/sqflite/pubspec.yaml): `sqflite ^2.4.3`, Dart `^3.12.0`, Flutter `>=3.44.0`. | Zakres pasuje; obecna fabryka DB go jednak pomija. |
| `path_provider 2.1.6`, interface `2.1.3` | [`path_provider_tizen 2.3.3`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/path_provider/pubspec.yaml): interface `^2.1.3`. | Kandydat rejestracji ścieżek bez przepisywania wywołań aplikacji. |
| `flutter_secure_storage 11.2.0`, interface `2.1.1` | [`flutter_secure_storage_tizen 0.1.6`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/flutter_secure_storage/pubspec.yaml): interface `^2.0.3`. | Zakres pasuje; wymagana osobna kwalifikacja trwałości magazynu. |
| `shared_preferences 2.5.6`, interface `2.4.2` | [`shared_preferences_tizen 2.3.5`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/shared_preferences/pubspec.yaml): interface `^2.4.1`. | Zakres pasuje. Nie zastępuje secure storage sesji TVBro. |
| `package_info_plus 10.2.2`, interface `4.1.0` | [`package_info_plus_tizen 1.2.0`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/package_info_plus/pubspec.yaml): interface `^4.1.0`. | Zakres pasuje. |
| `url_launcher 6.3.3`, interface `2.3.2` | [`url_launcher_tizen 2.1.8`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/url_launcher/pubspec.yaml): interface `^2.3.2`. | Zakres pasuje; dostępność przeglądarki zależy od urządzenia. |
| `media_kit 1.2.6` z git `c533e446755f51cf53c7e57aea873f2aa5355f81`, `media_kit_video 2.0.1`, `media_kit_libs_video 1.0.7` | Pobrane wersje nie deklarują pluginu Tizen. | Linuxowy backend ani import Dart nie dowodzą natywnego playera Tizen. |
| `sqflite_common_ffi 2.4.4`, `sqlite3 3.7.1`, `sqlite3_flutter_libs 0.6.0+eol` | Obecna ścieżka FFI i hook `sqlite3`. | Potrzebna kwalifikacja natywnego assetu, ABI i biblioteki SQLite Tizen. |

Ta macierz dotyczy wymienionych granic, nie całego entrypointu. Nie kwalifikuje
pozostałych pluginów i zależności przechodnich, w tym `file_picker 13.1.0`
ani używanych przez Supabase mechanizmów linków aplikacji.

## Granice wymagające rozstrzygnięcia

1. **SQLite i fabryka.** [AppDatabase](../../lib/data/app_database.dart)
   wybiera `databaseFactoryFfi` dla `Platform.isLinux`; `openAt()` również
   wymusza FFI. Konstruktor i `_openWithFactory` są prywatne.
   [`sqflite_tizen.register()`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/sqflite/lib/sqflite_tizen.dart)
   ustawia globalną fabrykę `sqflite`, nie jawną fabrykę FFI.
   [Kod narzędzia Tizen](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/build_targets/native_assets.dart)
   wskazuje Linux jako rzeczywisty OS runtime i obsługuje native assets.
   Potencjalna następna próba, dopiero z poprawnym SDK: osobny projekt TV,
   oryginalny `AppDatabase.open()` i kwalifikacja hooka `sqlite3` oraz biblioteki
   Tizen. `sqlite3 3.7.1` dokumentuje `hooks.user_defines.sqlite3.source: system`
   w pobranym `doc/hook.md`; trzeba potwierdzić nazwę biblioteki, symbole i ABI.
   Domyślnego prebuilt Linux nie uznajemy za zgodny z Tizen. Upstream wyraźnie
   odróżnia kompilator hosta od kompilatora z rootstrapem Tizen. Wybór
   `sqflite_tizen` zamiast FFI wymagałby małego punktu wstrzyknięcia fabryki
   we wspólnym kodzie — poza obecnym zakresem, bez kopii schematu i repozytorium.

2. **Ścieżki i sekrety.** Rejestracja pluginów Tizen w osobnym projekcie może
   zachować wywołania `path_provider` i `FlutterSecureStorage` istniejących
   właścicieli. [SecretLocatorVault](../../lib/data/secret_locator_vault.dart)
   toleruje błędy magazynu kluczem w pamięci; udany odczyt DB w jednym procesie
   nie dowodzi trwałego klucza. Nowa dwuprocesowa próba wyklucza ten fallback
   dla hostowego DPAPI i wykonuje również `SourceStore`/`SecureLocalStorage`.
   Nie kwalifikuje jednak wtyczki ani trwałości secure storage Tizena.

3. **Tożsamość platformy i TV.**
   [Oficjalne `flutter_tizen`](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/packages/flutter_tizen/lib/flutter_tizen.dart)
   rozpoznaje Tizen przez `TIZEN_API_VERSION`, profil TV przez `ELM_PROFILE=tv`.
   [detectDeviceClass](../../lib/data/device_class.dart) kończy się przed
   wywołaniem kanału na każdej platformie poza Androidem, więc samo dodanie
   Tizenowego handlera `iptvs/device` nie ustawi `isTelevision`.
   `debugIsTelevision` jest wyłącznie testowym API i nie może być obejściem
   produkcyjnym. Produkcyjny punkt wejścia dla klasy urządzenia wymaga
   osobnego rozstrzygnięcia i zgody na minimalną zmianę wspólnego kodu.
   Również [BootAutostartSetting](../../lib/widgets/boot_autostart_setting.dart)
   wiąże samo `isTelevision` z Androidowym autostartem/uprawnieniami; rozpoznanie
   Tizena jako TV nie może automatycznie włączyć tej Androidowej ścieżki.

4. **Player i preview.** [main](../../lib/main.dart) inicjalizuje MediaKit przed
   UI. [LivePreviewController](../../lib/screens/live_preview_controller.dart)
   tworzy konkretne `Player` i `VideoController`;
   [PlayerScreen](../../lib/player/player_screen.dart) wybiera linuxową ścieżkę
   surface/process przez `Platform.isLinux`. `media_kit_video` używa kanału
   `com.alexmercerind/media_kit_video`; implementacja `iptvs/native_hdr_player`
   nie zastępuje tego renderera. Konieczne jest zakwalifikowanie granicy wyboru
   silnika/surface oraz preview w istniejącej orkiestracji, bez nowego UI
   i przepisywania zasad playera. Wymagane punkty wstrzyknięcia wspólnego kodu
   pozostają poza obecnym zakresem.

   [`video_player_tizen 2.5.16`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/video_player/README.md)
   implementuje `video_player`, nie MediaKit. Nie działa w emulatorze TV;
   obsługuje tylko nagłówki Cookie/User-Agent, nie zapewnia wyboru audio/video
   tracks, a seek działa przy prędkości 1.0 i do najbliższej klatki kluczowej.
   [`video_player_avplay 0.8.22`](https://github.com/flutter-tizen/plugins/blob/a16990269f9f9631412661c4fe7696ef8bca558d/packages/video_player_avplay/README.md)
   jest niezgodny z API oryginalnego `video_player`; jego biblioteki wymagają
   pakietów zależnych od `api-version` Tizen, m.in. osobno 6.0, 6.5–9.0 i 10.0.
   Żaden z tych pluginów nie jest gotowym zamiennikiem obecnego playera TVBro.

## Warunki dalszego postępu R02

- Pozyskać i przypiąć zgodny zestaw framework/engine/Dart Tizen spełniający
  obecne wymagania TVBro. Nie obniżać SDK aplikacji ani nie uznawać
  podmienionego hostowego Dart za zgodny zestaw engine Tizen.
- Po usunięciu tego bloku kwalifikować w izolowanym projekcie TV rejestrację
  wymaganych pluginów, native assets/SQLite, ścieżki, trwałość sekretów
  i rzeczywisty import oryginalnych modułów; zachować rozdzielenie tego wyniku
  od obecnego dowodu hostowego.
- Rozstrzygnąć wymienione produkcyjne punkty wstrzyknięcia bazy, klasy
  urządzenia i playera przed implementacją adapterów wymagających zmian
  wspólnego kodu. Obecny zakaz tych zmian nie uzasadnia tworzenia drugich
  właścicieli logiki.
- Zapisać osobno dowód kompilacji/pakietu TPK i późniejszy odbiór na docelowym
  modelu. Odbiór sprzętowy pozostaje odłożony zgodnie z zakresem użytkownika.
  Wynik hostowego harnessu nie zastępuje żadnego z tych dowodów.
