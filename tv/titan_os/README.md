# TVBro — Titan OS

Wariant hostowany HTML5 budowany bezpośrednio z klienta Samsung Web. Każdy build
czyta aktualne `../samsung_web/ui/`, wspólne moduły platformy, oryginalny rdzeń
Dart i istniejące moduły walidacji/kryptografii panelu. Nie kopiuje ekranów,
parserów ani reguł profili, źródeł, EPG, ulubionych, historii i synchronizacji.
Hash źródeł oraz `reuse-proof.json` muszą zgadzać się z kompilowanym rdzeniem.

Warstwa Titan dodaje odtwarzacz HTML5, wiązania pilota i zamknięcia aplikacji.
Odtwarzacz korzysta z istniejącego silnika HTML5 wariantu LG; jego cykl życia
nie jest powielony. Szyfrowany magazyn IndexedDB, cache katalogów, konserwatywny
limit XMLTV 32 MiB i ograniczenia plikowych kopii zapasowych również korzystają
z tych samych modułów. Payload nie zawiera Samsung AVPlay, Tizen manifestu,
webOSTV.js ani pakietów APK/WGT/IPK. Nie wymaga pobierania zewnętrznego SDK
podczas startu.

## Budowanie

Z katalogu głównego repozytorium, korzystając z istniejących narzędzi:

```powershell
./app/tv/samsung_web/core_builder/build.ps1
node app/tv/titan_os/tools/build.cjs
node --test app/tv/titan_os/test/*.test.cjs
```

Kompilację rdzenia można pominąć, jeżeli jego dowód zgodności nadal jest aktualny.
Builder odrzuca zmienione źródła lub niespójny rdzeń. Zależności budowania są
istniejącymi zależnościami `samsung_web`; świeży checkout wymaga tam
`npm ci --ignore-scripts`, bez osobnego drzewa zależności Titan.

Wynik: `app/tv/output/titan-os/payload-<czas>/`. Plik
`app/tv/output/titan-os/latest-build.json` wskazuje aktualny katalog, hashe
wejść i wyników oraz niepotwierdzony status testów fizycznego telewizora.
JavaScript przechodzi istniejącą bramkę ES5 i zachowane ograniczenia CSS.
`hosting.json` to nasze metadane wydania, a nie oficjalny manifest Titan.

## Hostowanie i instalacja testowa

Na serwer statyczny należy skopiować całą zawartość katalogu `payload-<czas>`,
z zachowaniem podkatalogów. Adres aplikacji wskazuje na `index.html`. Nie należy
publikować repozytorium, plików konfiguracji wydawcy ani `latest-build.json`.
Payload zawiera wyłącznie konfigurację publicznego klienta pochodzącą ze
wspólnego buildera; nie wolno dodawać prywatnych kluczy backendu.

Używaj dedykowanego, stabilnego originu HTTPS dla Titan. WebCrypto wymaga
bezpiecznego kontekstu, a zmiana originu oznacza inny magazyn danych. Wspólne
moduły zachowują istniejące nazwy baz IndexedDB z wariantu LG; nie hostuj
niezależnych klientów LG i Titan pod jednym originem. Serwuj JavaScript z
poprawnym MIME, również dla workera; wszystkie ścieżki zasobów są względne.
Przy aktualizacjach unikaj mieszania plików różnych buildów przez cache HTTP.

Hostowany klient podlega politykom CORS i mixed content. Serwer API oraz
dostawcy list, EPG i metadanych muszą dopuszczać origin aplikacji, a ich adresy
HTTP mogą być blokowane spod HTTPS. Nie włączamy automatycznie proxy ani
przesyłania danych dostawców przez dodatkowy serwer. Istniejący relay nadal
wymaga osobnej konfiguracji i jawnego włączenia.

Testowy URL dodaje się w Titan Partner Portal/DevView. Publikacja sklepu wymaga
osobnego zgłoszenia i QA. Ten lokalny build nie jest instalacją ani publikacją.
Instrukcje producenta: [HTML5 i URL](https://docs.titanos.tv/introduction),
[DevView](https://docs.titanos.tv/devviewinstall),
[zgłoszenie aplikacji](https://docs.titanos.tv/publishing).

Bezpośrednie adresy źródła, EPG i odtwarzania HTTP są odrzucane lokalnie, przed żądaniem.
Dotyczy to również zapisanego źródła oraz adresu filmu/kanału zwróconego przez
API HTTPS. Pomoc w Ustawieniach wyjaśnia to ograniczenie. Jeżeli dostawca ma
wyłącznie HTTP, ta hostowana wersja Titan nie połączy się z nim bez osobno
wdrożonego, zaufanego rozwiązania transportowego; aplikacja nie włącza go sama.
Natywne ścieżki Androida, Windowsa, Samsunga i LG zachowują własną obsługę HTTP.

## Zachowanie i kwalifikacja

- Philips Back `8` i JVC Back `461` trafiają do wspólnej nawigacji; Play/Pause
  `179` do wspólnej obsługi odtwarzacza. Powrót z ekranu głównego otwiera
  potwierdzenie wyjścia, z domyślnie zaznaczonym anulowaniem. Zamknięcie zapisuje
  cache i zatrzymuje odtwarzanie, potem używa `SmartTvA_API.exit()` lub
  potwierdzonego zamknięcia okna.
- Start sprawdza trwały, nieeksportowalny klucz AES-GCM w IndexedDB. Brak API
  lub błąd zapisu zatrzymuje start; nie ma jawnego magazynu zastępczego.
  Dostępność i trwałość tych funkcji wymagają sprawdzenia na modelu TV.
- Odtwarzanie używa natywnego `<video>` i kodeków telewizora. HLS/DASH, audio,
  napisy i przewijanie trzeba sprawdzić na fizycznym TV. Nie dodajemy obsługi
  pozyskiwania licencji DRM. Dostępne kontrolki wynikają z wykrytych możliwości.
- HTML5 nie wysyła dowolnych nagłówków strumienia. Zachowany jest wyłącznie
  istniejący, wąski wyjątek dla domyślnego User-Agent VLC w zaufanym odtwarzaniu
  filmów/odcinków Xtream. Inne wymagane nagłówki i natywne strojenie bufora
  kończą się jawnym błędem, zamiast pozornego odtwarzania.
- Plikowy import/eksport kopii i zewnętrzne uruchamianie zwiastunów pozostają
  niedostępne. Titan App Control wymaga SDK i zgody na uruchamianie aplikacji;
  nie zastępujemy go przekierowaniem bieżącej strony.

Testy hostowe sprawdzają współdzielenie kodu, parsery/workera, kontrakt
odtwarzacza, mapowanie pilota, zapis danych i zamykanie. Test przeglądarkowy
`test/browser_qa.js` działa z istniejącym
`../samsung_web/test/ui_browser_server.cjs <ścieżka-payload>` przez
`playwright-cli run-code --filename`. Używa syntetycznego lokalnego dostawcy.
Żaden z tych wyników nie potwierdza jeszcze działania dekodera, trwałości
magazynu po wyłączeniu TV ani certyfikacji Titan.

## Wynik lokalny — 27 października 2026

Build utworzył 30 plików. Testy Titan: 16/16; testy regresji odtwarzacza,
magazynu i platformy LG oraz nawigacji, startu i fokusu wspólnego UI: 48/48.
Próba w Chrome przeszła bez błędów strony i konsoli: 161 kanałów M3U, odtworzony
profil i ulubione, ten sam trwały klucz AES-GCM po przeładowaniu, brak ponownego
pobrania listy, poprawny Back oraz anulowanie/potwierdzenie wyjścia. Jedyną
zastąpioną granicą natywną było końcowe `SmartTvA_API.exit()`.

Archiwum `tvbro-titan-os-20261027T202721901Z.zip` w wygenerowanym katalogu
`app/tv/output/titan-os/` zawiera zweryfikowane 30 plików payloadu (3 211 754 B).
SHA-256: `8e0eceb3c6065c3100e6f973fbee9737ab84893847bba39ee8ed4f4b0af410fc`.
Nie uruchamiano tego wydania na fizycznym telewizorze ani nie publikowano go.
