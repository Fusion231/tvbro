/* Samsung presentation. Provider requests, identities, validation, persistence
 * and playback belong to the original Dart core and the platform. */
(function startTVBroUi() {
  'use strict';
  if (window.TVBroPlatformReady && !window.TVBroSamsungPlatform) {
    window.TVBroPlatformReady.then(startTVBroUi).catch(function () {
      var node = document.getElementById('app-status');
      if (node) {
        node.textContent = 'Could not open protected TV storage. Restart the app or update the TV software. / Nie można otworzyć chronionego magazynu TV. Uruchom aplikację ponownie lub zaktualizuj oprogramowanie telewizora.';
        node.setAttribute('role', 'alert');
      }
    });
    return;
  }
  var platform = window.TVBroSamsungPlatform, validation = window.TVBroPanelValidation;
  // Canonical dictionaries stay in the compiled Dart core; only TV-specific UI text lives here.
  var core = window.TVBroCanonical, uiLanguage = "en", staticUi = [];
  var canonicalMessages = JSON.parse(core.translationCatalog()), trustedUiKeys = Object.create(null);
  var uiMessages = {
    "Cancelled.": "Anulowano.",
    "Could not perform this action.": "Nie udało się wykonać czynności.",
    "Details from your provider.": "Dane od dostawcy.",
    "Refresh details": "Odśwież szczegóły",
    "Could not refresh details.": "Nie udało się odświeżyć szczegółów.",
    "Details from your provider and saved metadata.": "Dane od dostawcy i zapisane metadane.",
    "Profile PIN": "PIN profilu",
    "Confirm": "Potwierdź",
    "Exit TVBro?": "Wyjść z TVBro?",
    "Do you want to close TVBro?": "Czy chcesz zamknąć TVBro?",
    "Could not change the setting.": "Nie można zmienić ustawienia.",
    "Help & connection": "Pomoc i połączenie",
    "TVBro sends provider requests directly from this TV.": "TVBro wysyła zapytania do dostawcy bezpośrednio z tego telewizora.",
    "On Titan OS, this TV version requires HTTPS. HTTP provider and media addresses are blocked before a request or playback.": "Na Titan OS ta wersja TV wymaga HTTPS. Adresy dostawcy i multimedia HTTP są blokowane przed wysłaniem zapytania lub odtworzeniem.",
    "The provider must allow TVBro to connect from this app. Ask them to enable access for TVBro.": "Dostawca musi zezwolić aplikacji TVBro na połączenie. Poproś go o włączenie dostępu dla TVBro.",
    "On native Samsung and LG apps, HTTP and required cookies or headers depend on the TV transport.": "W natywnych aplikacjach Samsung i LG obsługa HTTP, ciasteczek i wymaganych nagłówków zależy od transportu telewizora.",
    "TVBro does not automatically rewrite provider URLs or use a generic proxy. Stalker relay is used only when explicitly configured.": "TVBro nie zmienia automatycznie adresów dostawcy ani nie używa ogólnego serwera pośredniczącego. Przekazywanie Stalker działa tylko po osobnym skonfigurowaniu.",
    "This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.": "Dostawca używa HTTP. Ta wersja TV wymaga HTTPS. Poproś o adres HTTPS albo użyj TVBro na Androidzie, Windows lub Samsungu.",
    "Saved source data could not be moved safely. The source settings were not changed.": "Nie udało się bezpiecznie przenieść zapisanych danych źródła. Ustawienia źródła pozostały bez zmian.",
    "Done": "Gotowe",
    "Local profile": "Na telewizorze",
    "Choose a profile to manage.": "Wybierz profil, aby zmienić jego ustawienia.",
    "Preparing Demo…": "Przygotowywanie profilu demo…",
    "Could not prepare the Demo source.": "Nie udało się przygotować źródła demo.",
    "Rename profile": "Zmień nazwę profilu",
    "PIN (optional)": "PIN · opcjonalnie",
    "Could not save the profile.": "Nie udało się zapisać profilu.",
    "Rename": "Zmień nazwę",
    "Change or remove PIN": "Zmień lub usuń PIN",
    "Current PIN": "Obecny PIN",
    "New PIN (leave blank to remove)": "Nowy PIN · puste pole usuwa PIN",
    "Could not change the PIN.": "Nie udało się zmienić PIN-u.",
    "M3U playlist": "Lista M3U",
    "Source": "Źródło",
    "Connect and load channels": "Połącz i wczytaj kanały",
    "Save and open": "Zapisz i otwórz",
    "Source removed.": "Źródło usunięte.",
    "Loading source…": "Wczytywanie źródła…",
    "Live TV": "Telewizja na żywo",
    "Movies": "Filmy",
    "Series": "Seriale",
    "TV guide": "Program TV",
    "Preparing live TV…": "Przygotowywanie telewizji na żywo…",
    "Preparing movies…": "Przygotowywanie filmów…",
    "Preparing series…": "Przygotowywanie seriali…",
    "Saving your library…": "Zapisywanie biblioteki…",
    "Some sections could not be loaded: {sections}. Available sections remain usable.": "Nie udało się wczytać części biblioteki: {sections}. Dostępne sekcje są gotowe do użycia.",
    "Reading saved channel list…": "Odczytywanie zapisanej listy kanałów…",
    "Saving channel list…": "Zapisywanie listy kanałów…",
    "Could not save the channel list on this TV. It may need to download again next time.": "Nie udało się zapisać listy na telewizorze. Przy kolejnym uruchomieniu może być potrzebne ponowne pobranie.",
    "Loading cloud profiles…": "Wczytywanie profili z chmury…",
    "Preparing your library…": "Przygotowywanie biblioteki…",
    "Preparing your profile…": "Przygotowywanie profilu…",
    "Saving your profile…": "Zapisywanie profilu…",
    "Connecting to source…": "Łączenie ze źródłem…",
    "Generating pairing code…": "Generowanie kodu parowania…",
    "Checking pairing…": "Sprawdzanie parowania…",
    "Downloading from panel…": "Pobieranie z panelu…",
    "Uploading to panel…": "Przesyłanie do panelu…",
    "Could not load the source.": "Nie udało się wczytać źródła.",
    "No channels, movies or series were found in this source.": "To źródło nie zwróciło kanałów TV, filmów ani seriali.",
    "Could not start the preview.": "Nie udało się uruchomić podglądu.",
    "Could not load TV guide.": "Nie można wczytać programu TV.",
    "Could not start playback.": "Nie udało się uruchomić odtwarzania.",
    "Could not stop playback.": "Nie udało się zatrzymać odtwarzania.",
    "Playback failed.": "Błąd odtwarzania.",
    "Paused": "Odtwarzanie wstrzymane",
    "Your library": "TWOJA BIBLIOTEKA",
    "On demand": "NA ŻĄDANIE",
    "All": "Wszystkie",
    "♡ Favorites": "♡ Ulubione",
    "♥ Favorites": "♥ Ulubione",
    "Lock / unlock item": "Zablokuj / odblokuj pozycję",
    "Previous": "Poprzednie",
    "Continue watching?": "Kontynuować oglądanie?",
    "Added to favorites.": "Dodano do ulubionych.",
    "Removed from favorites.": "Usunięto z ulubionych.",
    "Could not update favorites.": "Nie udało się zmienić ulubionych.",
    "Loading guide…": "Wczytywanie programu…",
    "♡ Favorite channel": "♡ Ulubiony kanał",
    "Protection updated.": "Zmieniono blokadę.",
    "Could not update protection.": "Nie udało się zmienić blokady.",
    "Protection is enabled. Enter the current PIN to make changes.": "Ochrona jest włączona. Zmiany wymagają obecnego PIN-u.",
    "Set a four-digit PIN to protect selected channels and categories.": "Ustaw czterocyfrowy PIN, aby chronić wybrane kanały i kategorie.",
    "New PIN": "Nowy PIN",
    "Yes": "Tak",
    "No": "Nie",
    "Save PIN and settings protection": "Zapisz PIN i ochronę ustawień",
    "Could not save parental controls.": "Nie udało się zapisać ochrony.",
    "Disable parental controls": "Wyłącz ochronę",
    "Could not disable parental controls.": "Nie udało się wyłączyć ochrony.",
    "Loading settings…": "Wczytywanie ustawień…",
    "Default": "Domyślnie",
    "Aspect ratio": "Proporcje obrazu",
    "Subtitles off": "Wyłącz napisy",
    "Could not select the profile.": "Nie można wybrać profilu.",
    "Connecting to cloud sync…": "Łączenie z panelem…",
    "Your profile, playlists and settings are downloaded. Continue to open your library.": "Profil, listy i ustawienia zostały pobrane. Wybierz Kontynuuj, aby otworzyć bibliotekę.",
    "Enter this code in the TVBro panel, then check the connection.": "Wpisz ten kod w panelu TVBro, a potem wybierz Sprawdź połączenie.",
    "New pairing code": "Nowy kod parowania",
    "Generate pairing code": "Generuj kod parowania",
    "This profile has no usable playlists.": "Profil nie zawiera źródła gotowego do oglądania.",
    "Unpair this device?": "Odłączyć panel?",
    "Downloaded sources and favorites will stay on this TV.": "Pobrane źródła i ulubione pozostaną na telewizorze.",
    "Saving source…": "Zapisywanie źródła…",
    "Could not save the source.": "Nie udało się zapisać źródła.",
    "Could not start the app.": "Nie udało się uruchomić aplikacji.",
    "Starting TVBro…": "Uruchamianie TVBro…",
    "Could not read TVBro data.": "Nie można odczytać danych TVBro.",
    "Restart TVBro and try again.": "Uruchom TVBro ponownie i spróbuj jeszcze raz.",
    "Who is watching?": "Kto ogląda?",
    "Continue without a profile": "Kontynuuj bez profilu",
    "Add IPTV source": "Dodaj źródło IPTV",
    "M3U playlist, Xtream Codes or an available Stalker portal.": "Lista M3U, Xtream Codes lub dostępny portal Stalker.",
    "Sample channels, movies and series.": "Przykładowe kanały, filmy i seriale.",
    "Back to profiles": "Wróć do profili",
    "Your TV": "TWOJA TELEWIZJA",
    "Add your source": "Dodaj swoje źródło",
    "Choose a saved source or enter your provider details.": "Wybierz zapisane źródło albo dodaj dane od swojego dostawcy.",
    "Your sources": "Twoje źródła",
    "· optional": "· opcjonalnie",
    "My TV": "Moja telewizja",
    "OK — edit field · Back — finish editing": "OK — edycja pola · Wstecz — zakończ edycję",
    "Cancel editing": "Anuluj edycję",
    "Library": "Biblioteka",
    "Channel name or number": "Nazwa lub numer kanału",
    "Clear search": "Wyczyść wyszukiwanie",
    "Lock / unlock category": "Blokada kategorii",
    "Select a channel to preview.": "Wybierz kanał, aby włączyć podgląd.",
    "Preview": "Podgląd",
    "Fullscreen": "Pełny ekran",
    "Lock / unlock channel": "Blokada kanału",
    "Search catalogue": "Szukaj w katalogu",
    "No items match": "Brak pozycji dla tego wyszukiwania.",
    "← Earlier": "← Wcześniej",
    "Later →": "Później →",
    "Previous channels": "Poprzednie kanały",
    "Next channels": "Następne kanały",
    "No programmes in this time range.": "Brak programu w wybranym przedziale.",
    "Check connection": "Sprawdź połączenie",
    "Choose a profile": "Wybierz profil panelu",
    "Arrows — choose": "Strzałki — wybór",
    "OK — open": "OK — otwórz",
    "Back — return": "Wstecz — powrót",
    "Player": "Odtwarzacz",
    "Playback position": "Pozycja odtwarzania",
    "Back to channels": "Wróć do kanałów",
    "Stop": "Zatrzymaj",
    "Hide controls": "Ukryj kontrolki",
    "OK — controls · Back — hide controls · Hold seek — keep seeking": "OK — kontrolki · Wstecz — ukryj kontrolki · Przytrzymaj przewijanie — przewijaj dalej",
    "← / → — adjust · OK — seek · Back — cancel": "← / → — wybierz pozycję · OK — przewiń · Wstecz — anuluj",
    "Previous channel": "Poprzedni kanał",
    "Channels": "Kanały",
    "No channel {number}": "Brak kanału {number}",
    "OK — controls · ↑ / ↓ — channel · ← — channels · → — previous · 0–9 — channel number": "OK — kontrolki · ↑ / ↓ — kanał · ← — kanały · → — poprzedni · 0–9 — numer kanału",
    "OK — controls · Up / down with controls hidden — change channel": "OK — kontrolki · Góra / dół przy ukrytych kontrolkach — zmień kanał",
    "Enter your parental PIN.": "Podaj PIN kontroli rodzicielskiej.",
    "Incorrect PIN.": "Nieprawidłowy PIN.",
    "Language": "Język",
    "Source name": "Nazwa źródła",
    "Set up {profile}": "Skonfiguruj profil: {profile}",
    "{count} channels": "{count} kanałów",
    "Page {page}": "Strona {page}",
    "Protect settings: {value}": "Chroń ustawienia: {value}",
    "Source settings": "Ustawienia źródła",
    "Organize channels": "Uporządkuj kanały",
    "Channel name": "Nazwa kanału",
    "Empty restores the provider name": "Puste pole przywraca nazwę dostawcy",
    "Hidden": "Ukryty",
    "Hide channel": "Ukryj kanał",
    "Show channel": "Pokaż kanał",
    "Move up": "Przesuń w górę",
    "Move down": "Przesuń w dół",
    "Groups": "Grupy",
    "New group": "Nowa grupa",
    "Group name": "Nazwa grupy",
    "Delete group?": "Usunąć grupę?",
    "Channels stay in your source.": "Kanały pozostaną w źródle.",
    "Hide categories": "Ukryj kategorie",
    "EPG mapping": "Dopasowanie EPG",
    "Find a guide channel by name or ID": "Szukaj kanału EPG według nazwy lub ID",
    "Automatic matching": "Automatyczne dopasowanie",
    "Selected guide channel: {id}": "Wybrany kanał EPG: {id}",
    "Time correction in minutes": "Korekta czasu w minutach",
    "Positive values move programmes later; negative values move them earlier.": "Wartości dodatnie przesuwają program później, ujemne wcześniej.",
    "Enter whole minutes between −1440 and 1440.": "Podaj całkowitą liczbę minut od −1440 do 1440.",
    "No XMLTV channel catalogue is cached yet. Refresh the guide first.": "Katalog kanałów XMLTV nie jest jeszcze zapisany. Najpierw odśwież program TV.",
    "Search programmes": "Szukaj audycji",
    "Searches the guide already loaded on this TV.": "Przeszukuje program TV wczytany na tym telewizorze.",
    "Extra EPG URLs": "Dodatkowe adresy EPG",
    "Add guide": "Dodaj program TV",
    "Clear a URL to remove that guide. Guides are tried in this order.": "Wyczyść adres, aby usunąć program TV. Kolejność określa priorytet.",
    "Playlist expiry": "Ważność źródła",
    "Expiry date unavailable": "Data ważności niedostępna",
    "Unlimited": "Bez ograniczeń",
    "Your playlist has expired.": "Ważność źródła wygasła.",
    "Your playlist expires on {date}.": "Ważność źródła wygasa {date}.",
    "Show protected content": "Pokaż chronione treści",
    "Hide protected content": "Ukryj chronione treści",
    "Automatic cloud sync": "Automatyczna synchronizacja z chmurą",
    "Primary EPG URL": "Główny adres EPG",
    "Catch-up timezone": "Strefa czasowa archiwum",
    "Catch-up offset (minutes)": "Przesunięcie archiwum (min)",
    "Catch-up day limit": "Limit dni archiwum",
    "Expiry reminder": "Przypomnienie o wygaśnięciu",
    "Playback buffer": "Bufor odtwarzania",
    "Stream format": "Format strumienia",
    "Maximum simultaneous streams": "Limit równoległych strumieni",
    "Stable": "Stabilny",
    "{days} days before": "{days} dni wcześniej",
    "Export encrypted backup": "Eksportuj szyfrowaną kopię",
    "Import encrypted backup": "Importuj szyfrowaną kopię",
    "Choose backup folder": "Wybierz folder kopii",
    "Choose backup file": "Wybierz plik kopii",
    "Use this folder": "Wybierz ten folder",
    "Up": "W górę",
    "File name": "Nazwa pliku",
    "Backup password": "Hasło kopii",
    "Confirm password": "Potwierdź hasło",
    "Use a password with at least 8 characters.": "Użyj hasła o długości co najmniej 8 znaków.",
    "Passwords do not match.": "Hasła nie są takie same.",
    "Encrypting backup…": "Szyfrowanie kopii…",
    "Reading encrypted backup…": "Odczytywanie szyfrowanej kopii…",
    "Backup saved: {path}": "Zapisano kopię: {path}",
    "Only the first 200 entries are shown. Open a folder to narrow the list.": "Wyświetlono pierwsze 200 pozycji. Otwórz folder, aby zawęzić listę.",
    "The backup adds recovery profiles. Your current profiles and settings stay as they are.": "Kopia zostanie dodana jako profile odzyskiwania. Obecne profile i ustawienia pozostaną bez zmian.",
    "{profiles} profiles · {sources} sources · {favorites} favorites": "{profiles} profili · {sources} źródeł · {favorites} ulubionych",
    "Add recovery profiles": "Dodaj profile odzyskiwania",
    "Recovery profiles added.": "Dodano profile odzyskiwania.",
    "EPG URL (optional)": "Adres EPG (opcjonalnie)"
  };
  var uiLabelAliases = {
    "Wybór profilu przy starcie": "Profile picker at startup",
    "Dopasuj": "Fit",
    "Pełny ekran": "Fill",
    "Automatycznie": "Automatic",
    "Automatyczna synchronizacja": "Automatic cloud sync",
    "Wyłączona": "Off",
    "Włączona": "On",
    "Główny adres EPG": "Primary EPG URL",
    "Dodatkowe adresy EPG": "Extra EPG URLs",
    "Strefa czasowa archiwum": "Catch-up timezone",
    "Przesunięcie archiwum (min)": "Catch-up offset (minutes)",
    "Limit dni archiwum": "Catch-up day limit",
    "Przypomnienie o wygaśnięciu": "Expiry reminder",
    "Bufor odtwarzania": "Playback buffer",
    "Format strumienia": "Stream format",
    "Limit równoległych strumieni": "Maximum simultaneous streams",
    "default": "Default",
    "stable": "Stable",
    "Podaj PIN profilu.": "Enter the PIN for this profile."
  };
  Object.keys(canonicalMessages).forEach(function (key) { trustedUiKeys[canonicalMessages[key]] = key; });
  Object.keys(uiMessages).forEach(function (key) { if (!trustedUiKeys[uiMessages[key]]) trustedUiKeys[uiMessages[key]] = key; });
  var pageSize = 80;
  var guideRowHeight = 52, guideWindowSize = 40;
  var view = {
    screen: 'sources', kind: 'm3u', busy: false, profiles: [], profile: null,
    sources: [], settings: {}, caps: {}, history: [], favorites: [], source: null,
    categories: [], channels: [], filtered: [], category: null, page: 0,
    player: false, playerReady: false, preview: false, chrome: true, channel: null, item: null,
    sourceId: null, playingState: {}, request: 0, playbackRequest: 0,
    mediaRequest: 0, guideRequest: 0, nowNextRequest: 0, statusStage: null, mediaKind: 'movie', mediaCategory: null,
    mediaPage: 1, mediaCategories: [], nowNext: {}, guideStartIndex: 0, guideFrom: 0, guideVisible: true, guideFilter: null,
    guideData: Object.create(null), guideDataOrder: [], guideDataRange: '',
    manageProfiles: false, profileSelecting: false, editSource: null, episodes: null, sourceSetup: false,
    pairingOnboarding: false, pairingReturn: 'settings', pairingReady: false,
    pairingPaired: false, pairingBusy: false, pairingDownloading: false, pairingRequest: 0,
    pairingExpiresAt: 0, pairingRetryAt: 0, pairingQrLink: '', pairingQrData: '', pairingStage: '',
    languageSelected: false, languageCode: 'en', languages: [], languageReturn: false,
    languagePrevious: 'en', languageSaving: false
  };
  var fieldInputs = {}, dialogs = [], hideTimer = null, searchTimer = null, editableSequence = 0;
  var mediaSearchTimer = null, returnFocus = null, pairingTimer = null;
  var previewIdleTimer = null;
  var exitPending = null;
  var playerZapTimer = null, playerZapFeedbackTimer = null, playerZapPending = null, playerZapDigits = '', previousPlayer = null, readyPlayer = null;
  var guideScrollTimer = null, guidePaintScheduled = false, guideRenderState = null, channelNowNextTimer = null;
  var previewStart = null, playerStart = null, playerContent = null, nowNextStart = null, mediaStart = null, detailsStart = null;
  var seekIntent = null, seekTimer = null, seekFlight = null, seekHold = null, scrub = null;
  var episodeNavigation = null, completedEpisodeRequest = null;
  var childrenStart = null, guideStart = null;
  var suspendedDetails = null;
  var seriesList = null, seriesScrollScheduled = false;
  var artworkScheduled = false;
  var artworkFlights = Object.create(null), artworkInFlight = 0;
  var artworkHosts = Object.create(null), artworkFailures = Object.create(null);
  function byId(id) { return document.getElementById(id); }
  function t(key, parameters) {
    var values = Object.assign({ app: 'TVBro' }, parameters || {});
    var translated = core.translateUi(key, uiLanguage, JSON.stringify(values));
    if (uiLanguage === 'pl' && !Object.prototype.hasOwnProperty.call(canonicalMessages, key) && Object.prototype.hasOwnProperty.call(uiMessages, key)) {
      translated = uiMessages[key].replace(/\{(\w+)\}/g, function (match, name) { return values[name] == null ? match : String(values[name]); });
    }
    return translated;
  }
  // These inputs are authored platform field labels or errors, never catalogue/user data.
  function uiLabel(value) {
    var label = String(value == null ? '' : value);
    return t((Object.prototype.hasOwnProperty.call(uiLabelAliases, label) ? uiLabelAliases[label] : null) || trustedUiKeys[label] || label);
  }
  function captureStaticUi(node) {
    if (node.nodeType === 3) {
      var key = node.nodeValue.trim();
      if (key) staticUi.push({ node: node, key: key, before: node.nodeValue.slice(0, node.nodeValue.indexOf(key)), after: node.nodeValue.slice(node.nodeValue.indexOf(key) + key.length) });
      return;
    }
    if (node.nodeType !== 1 || /^(SCRIPT|STYLE|OBJECT)$/.test(node.tagName)) return;
    ['placeholder', 'aria-label', 'alt', 'title'].forEach(function (attribute) {
      var value = node.getAttribute(attribute); if (value) staticUi.push({ node: node, key: value, attribute: attribute });
    });
    for (var child = node.firstChild; child; child = child.nextSibling) captureStaticUi(child);
  }
  function applyUiLanguage(code) {
    uiLanguage = code; document.documentElement.lang = code;
    staticUi.forEach(function (entry) {
      if (entry.attribute) entry.node.setAttribute(entry.attribute, t(entry.key));
      else entry.node.nodeValue = entry.before + t(entry.key) + entry.after;
    });
  }
  function routeAfterLanguage() {
    if (view.profile && view.profile.locked && view.settings.profilePickerStartup === 'off') {
      showProfiles(); selectExistingProfile(view.profile); return;
    }
    if (!view.profile || view.showProfilePicker) showProfiles();
    else { openProfileContent(); refreshParental().catch(report); }
  }
  function openProfileContent() {
    var active = view.sources.filter(function (source) { return source.id === view.activeSourceId; })[0];
    if (active) {
      cancelSourceEdit(); clear(byId('home-history-list')); byId('home-history').hidden = true;
      text(byId('home-source'), sourceName(active)); showScreen('home'); return loadSource(active);
    }
    if (view.sources.length) showSources(); else showSetup();
  }
  function showLanguage(fromSettings) {
    view.languageReturn = fromSettings === true; view.languagePrevious = view.languageCode;
    showScreen('language', false); renderLanguages();
  }
  function renderLanguages() {
    var parent = byId('language-list'); clear(parent);
    (view.languages.length ? view.languages : JSON.parse(core.appLanguages())).forEach(function (language) {
      var selected = language.code === uiLanguage;
      var node = button(language.name, 'button language-choice' + (selected ? ' selected-option' : ''), function () { saveLanguage(language.code); });
      node.setAttribute('aria-pressed', selected ? 'true' : 'false'); node.disabled = view.languageSaving; parent.appendChild(node);
    });
    byId('language-continue').disabled = view.languageSaving; byId('language-back').hidden = !view.languageReturn;
    byId('language-back').disabled = view.languageSaving; focus(parent.querySelector('[aria-pressed="true"]') || parent.firstChild || byId('language-continue'));
  }
  function saveLanguage(code) {
    if (view.languageSaving) return;
    view.languageSaving = true; applyUiLanguage(code); renderLanguages(); text(byId('language-error'), '');
    query('language.set', { code: code }).then(function (data) {
      if (!data || data.languageSelected !== true || data.languageCode !== code) throw new Error('Language was not saved.');
      view.languageSaving = false; view.languageCode = data.languageCode; view.languageSelected = data.languageSelected === true;
      view.languages = array(data.languages); applyUiLanguage(view.languageCode);
      if (view.languageReturn) showSettings(); else routeAfterLanguage();
    }).catch(function () {
      view.languageSaving = false; renderLanguages(); text(byId('language-error'), t('Could not save the language. Please try again.'));
    });
  }
  function leaveLanguage() {
    if (view.languageSaving) return;
    if (view.languageReturn) { applyUiLanguage(view.languagePrevious); showSettings(); }
    else requestExit();
  }
  function text(node, value) { node.textContent = value == null ? '' : String(value); }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function array(value) { return Array.isArray(value) ? value : value && Array.isArray(value.items) ? value.items : []; }
  function message(error, fallback) {
    var value; try { value = error && error.message; } catch (_) {}
    if (typeof value !== 'string' || !value || value === 'Nie udało się wykonać operacji.' || value === 'Something went wrong.') {
      return bootFailureMessage(error, fallback || t('Could not perform this action.'));
    }
    return uiLabel(value);
  }
  function status(value, error, loading) {
    view.statusStage = null;
    var node = byId('app-status'), pending = !!value && !error && (loading === true || view.busy || view.pairingBusy);
    text(node, value); node.className = 'app-status' + (error ? ' is-error' : '') + (pending && view.screen !== 'pairing' ? ' is-busy' : '');
    node.setAttribute('aria-busy', pending ? 'true' : 'false');
  }
  function afterLoadingPaint() {
    return new Promise(function (resolve) {
      var done = false, fallback = window.setTimeout(finish, 100);
      function finish() { if (done) return; done = true; window.clearTimeout(fallback); resolve(); }
      try {
        if (!document.hidden && typeof window.requestAnimationFrame === 'function') window.requestAnimationFrame(function () { window.setTimeout(finish, 0); });
        else window.setTimeout(finish, 0);
      } catch (_) { window.setTimeout(finish, 0); }
    });
  }
  function visible(node) { return node && !node.disabled && node.offsetWidth > 0 && node.offsetHeight > 0; }
  function focus(node) {
    if (!visible(node)) return;
    node.focus();
    if (node.scrollIntoViewIfNeeded) node.scrollIntoViewIfNeeded(false); else node.scrollIntoView(false);
  }
  function element(tag, className, value) { var node = document.createElement(tag); if (className) node.className = className; if (value != null) text(node, value); return node; }
  function button(label, className, action) { var node = element('button', className, label); node.type = 'button'; node.setAttribute('data-nav', ''); node.addEventListener('click', action); return node; }
  function artworkUrl(url, className) {
    if (className !== 'media-poster' && className !== 'details-poster' && className !== 'details-backdrop' && className !== 'episode-image') return url;
    var match = /^((?:https?:)?\/\/image\.tmdb\.org\/t\/p\/)(original|w([0-9]+))(\/[a-z0-9_-]+\.(?:jpe?g|png|webp))$/i.exec(url);
    var maximum = className === 'details-backdrop' ? 780 : 342;
    if (!match || match[2] !== 'original' && Number(match[3]) <= maximum) return url;
    // Reuse one CDN thumbnail in the grid and details instead of decoding full posters.
    return match[1] + 'w' + maximum + match[4];
  }
  function image(url, className, parent) {
    var thumbnail = artworkUrl(url, className), fallback = thumbnail !== url ? url : null;
    var node = element('img', className); node.alt = ''; node.addEventListener('error', function () {
      if (fallback) { var original = fallback; fallback = null; this.setAttribute('data-artwork-src', original); scheduleArtwork(); }
      else this.hidden = true;
    });
    node.setAttribute('data-artwork-src', thumbnail); parent.appendChild(node); scheduleArtwork(); return node;
  }
  function startArtwork(node, url) {
    var now = Date.now(), address = document.createElement('a'); address.href = url;
    var host = address.host || 'local', state = artworkHosts[host];
    if (!state) {
      // Bound session bookkeeping while retaining hosts that are cooling down.
      Object.keys(artworkHosts).forEach(function (key) {
        if (artworkHosts[key].next < now - 60000 && artworkHosts[key].until < now) delete artworkHosts[key];
      });
      if (Object.keys(artworkHosts).length >= 64) return;
      state = artworkHosts[host] = { next: 0, until: 0, failures: 0 };
    }
    if (state.until > now || artworkFailures[url] > now) return;
    if (artworkInFlight >= 2 || artworkFlights[url]) return;
    state.next = now; artworkFlights[url] = true; artworkInFlight++;
    var done = false, timeout;
    function finish(failed) {
      if (done) return; done = true; clearTimeout(timeout);
      node.removeEventListener('load', loaded); node.removeEventListener('error', failedLoad);
      delete artworkFlights[url]; artworkInFlight--;
      if (failed) {
        var keys = Object.keys(artworkFailures);
        if (keys.length >= 256) delete artworkFailures[keys[0]];
        artworkFailures[url] = Date.now() + 60000;
        // <img> does not expose HTTP status on Tizen. Three consecutive
        // failures pause this artwork host, without blocking playback/API.
        if (++state.failures >= 3) state.until = Date.now() + 60000;
      } else state.failures = 0;
      scheduleArtwork();
    }
    function loaded() { finish(false); }
    function failedLoad() { finish(true); }
    node.addEventListener('load', loaded); node.addEventListener('error', failedLoad);
    timeout = setTimeout(function () {
      finish(true); node.removeAttribute('src'); node.hidden = true;
    }, 15000);
    node.removeAttribute('data-artwork-src'); node.src = url;
  }
  function scheduleArtwork() {
    if (artworkScheduled) return;
    artworkScheduled = true;
    afterLoadingPaint().then(function () {
      artworkScheduled = false; if (document.hidden || view.player && !dialogs.length || artworkInFlight >= 2) return;
      var scope = dialogs.length ? dialogs[dialogs.length - 1].node : document;
      var nodes = scope.querySelectorAll('img[data-artwork-src]'), margin = Math.min(160, window.innerHeight / 6);
      for (var i = 0; i < nodes.length && artworkInFlight < 2; i++) {
        var node = nodes[i]; if (!visible(node)) continue;
        var rect = node.getBoundingClientRect(), top = 0, left = 0, right = window.innerWidth, bottom = window.innerHeight;
        for (var clip = node.parentNode; clip && clip !== document.body; clip = clip.parentNode) {
          if (clip.scrollHeight > clip.clientHeight || clip.scrollWidth > clip.clientWidth) {
            var bounds = clip.getBoundingClientRect(); top = Math.max(top, bounds.top); left = Math.max(left, bounds.left);
            right = Math.min(right, bounds.right); bottom = Math.min(bottom, bounds.bottom);
          }
        }
        if (bottom > top && right > left && rect.bottom >= top - margin && rect.top <= bottom + margin && rect.right >= left - margin && rect.left <= right + margin) {
          startArtwork(node, node.getAttribute('data-artwork-src'));
        }
      }
    });
  }
  function cap(name) { return view.caps[name] === true; }
  function busy(value) {
    var controls = document.querySelectorAll('#source-form input, #source-form button, .source-open, .source-edit, .source-remove, #home-view button');
    view.busy = value; for (var i = 0; i < controls.length; i++) controls[i].disabled = value;
    syncPreviewIdleTimer();
  }
  function cancelled() { var error = new Error(t("Cancelled.")); error.code = 'ui_cancelled'; return error; }
  function report(error, fallback) { if (!error || error.code !== 'ui_cancelled') status(message(error, fallback || t("Could not perform this action.")), true); }
  function bootFailureMessage(error, context) {
    var allowed = ['Error', 'UnknownError', 'NotSupportedError', 'TypeError', 'SyntaxError', 'SecurityError', 'TypeMismatchError', 'QuotaExceededError', 'InvalidStateError', 'VerificationError', 'InvalidValuesError', 'NotFoundError', 'CloudError', 'NetworkError', 'ProtocolError', 'SessionError', 'TimeoutError', 'AbortError', 'ConfigurationError', 'CloudStateError', 'CloudCapabilityError', 'CryptoError', 'CryptoUnsupportedError', 'CryptoLockedError', 'CryptoRollbackError'];
    var candidate, status, operation, code, origin, detail = '', name = 'Error';
    try { candidate = error && error.name; } catch (_) {}
    if (typeof candidate === 'string' && allowed.indexOf(candidate) >= 0) name = candidate;
    if (name === 'CloudError') { try { status = error.status; } catch (_) {} }
    var http = typeof status === 'number' && status % 1 === 0 && status >= 100 && status <= 599 ? ' / HTTP ' + status : '';
    try { operation = error && error.cloudOperation; code = error && error.code; } catch (_) {}
    if (operation === 'signup' || operation === 'request_pairing') detail += ' / ' + operation;
    if (code === 'origin_not_allowed') detail += ' / Origin rejected';
    else if (code === '42501') detail += ' / Access denied';
    if (name === 'CloudError' && status === 403) {
      try { origin = window.location.origin; } catch (_) {}
      if (typeof origin === 'string' && origin.length <= 128 && !/\s/.test(origin) &&
          (origin === 'null' || origin === 'file://' || /^[a-z][a-z0-9+.-]*:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/i.test(origin))) detail += ' / origin: ' + origin;
    }
    return (context || t('Could not read TVBro data.')) + ' (' + name + http + detail + ')' + (context ? '' : ' ' + t('Restart TVBro and try again.'));
  }
  function query(action, args, prompted) {
    return Promise.resolve().then(function () { return platform.query(action, args || {}); }).catch(function (error) {
      if (!prompted && error && (error.code === 'pin_required' || error.code === 'pin_invalid')) {
        return pinPrompt(error.message).then(function (pin) {
          var next = Object.assign({}, args || {});
          next[action === 'profiles.pin' || action === 'profiles.rename' || action === 'profiles.delete' ? 'currentPin' : 'pin'] = pin;
          return query(action, next, true);
        });
      }
      throw error;
    });
  }
  function dialog(title, wide, onCancel) {
    stopSeekHold();
    cancelPlayerZap();
    var layer = byId('modal-layer'); if (dialogs.length) dialogs[dialogs.length - 1].node.hidden = true;
    var node = element('section', 'dialog' + (wide ? ' dialog-wide' : ''));
    node.setAttribute('role', 'dialog'); node.setAttribute('aria-modal', 'true'); node.setAttribute('aria-label', title);
    var heading = element('h2', '', title), body = element('div', 'dialog-body'), error = element('p', 'dialog-error'), actions = element('div', 'dialog-actions');
    node.appendChild(heading); node.appendChild(body); node.appendChild(error); node.appendChild(actions); layer.appendChild(node); layer.hidden = false;
    var record = { node: node, body: body, error: error, actions: actions, focus: document.activeElement, onCancel: onCancel };
    dialogs.push(record); document.body.classList.add('dialog-open'); window.clearTimeout(hideTimer); hideTimer = null; syncPreviewIdleTimer(); return record;
  }
  function closeDialog(cancel, expected) {
    if (!dialogs.length || expected && dialogs[dialogs.length - 1] !== expected) return;
    var record = dialogs.pop(), inputs = record.node.querySelectorAll('input'); record.closed = true;
    for (var i = 0; i < inputs.length; i++) inputs[i].value = '';
    record.node.parentNode.removeChild(record.node);
    if (dialogs.length) dialogs[dialogs.length - 1].node.hidden = false; else { byId('modal-layer').hidden = true; document.body.classList.remove('dialog-open'); }
    focus(record.focus);
    if (!visible(document.activeElement) || document.activeElement === document.body) {
      var root = dialogs.length ? dialogs[dialogs.length - 1].node : view.player ? byId('player-chrome') : byId(view.screen + '-view');
      var candidates = root.querySelectorAll('[data-nav]');
      for (var j = 0; j < candidates.length; j++) if (visible(candidates[j])) { focus(candidates[j]); break; }
    }
    if (cancel && record.onCancel) record.onCancel();
    if (!dialogs.length && view.player) showChrome(true);
    resetPreviewIdleTimer();
  }
  function closeAllDialogs() { while (dialogs.length) closeDialog(true); }
  function dialogButton(record, label, action, primary) { var node = button(label, 'button' + (primary ? ' button-primary' : ''), action); record.actions.appendChild(node); return node; }
  function editableInput(parent, label, type, value, maxLength) {
    var node = element('input'), id = 'dialog-input-' + (++editableSequence);
    var caption = element('label', '', label); caption.htmlFor = id;
    node.id = id; node.type = type || 'text'; node.value = value || ''; node.readOnly = true; node.autocomplete = 'off';
    node.setAttribute('data-nav', ''); node.setAttribute('data-editable', ''); node.setAttribute('autocapitalize', 'off'); node.setAttribute('spellcheck', 'false');
    if (maxLength) node.maxLength = maxLength;
    parent.appendChild(caption); parent.appendChild(node); return node;
  }
  // Editors reuse the loaded catalogue and mount only one small page of rows.
  function pagedEditor(title, rows, label, action, searchLabel) {
    var record = dialog(title, true), page = 0, timer = null;
    var input = editableInput(record.body, searchLabel || t('Search channels'), 'search', '', 200);
    var list = element('div', 'dialog-list'), count = element('p', 'muted editor-count'); record.body.appendChild(list); record.body.appendChild(count);
    record.rows = rows;
    record.repaint = function (keepPage) {
      if (record.closed) return;
      if (!keepPage) page = 0;
      var term = input.value.toLowerCase(), filtered = record.rows.filter(function (row) { return !term || label(row).toLowerCase().indexOf(term) >= 0; });
      var pages = Math.max(1, Math.ceil(filtered.length / 40)); page = Math.max(0, Math.min(page, pages - 1)); clear(list);
      filtered.slice(page * 40, (page + 1) * 40).forEach(function (row) { list.appendChild(button(label(row), 'button editor-item', function () { action(row, record); })); });
      previous.disabled = page === 0; next.disabled = page + 1 >= pages; text(count, (page + 1) + ' / ' + pages + ' · ' + filtered.length);
    };
    input.addEventListener('input', function () { window.clearTimeout(timer); timer = window.setTimeout(function () { timer = null; record.repaint(); }, 180); });
    var previous = dialogButton(record, t('Previous'), function () { page--; record.repaint(true); focus(list.firstChild || input); });
    var next = dialogButton(record, t('Next'), function () { page++; record.repaint(true); focus(list.firstChild || input); });
    dialogButton(record, t('Back'), function () { window.clearTimeout(timer); closeDialog(true, record); });
    record.repaint(); focus(input); return record;
  }
  function pinPrompt(description) {
    return new Promise(function (resolve, reject) {
      var record = dialog(t("Profile PIN"), false, function () { reject(cancelled()); });
      record.body.appendChild(element('p', 'muted', description || t("Enter the PIN for this profile.")));
      var input = editableInput(record.body, 'PIN', 'password', '', 4); input.setAttribute('inputmode', 'numeric');
      dialogButton(record, t("Continue"), function () { var pin = input.value; closeDialog(false); resolve(pin); }, true);
      dialogButton(record, t("Cancel"), function () { closeDialog(true); }); focus(input);
    });
  }
  function confirmAction(title, description, action) {
    var record = dialog(title); record.body.appendChild(element('p', 'muted', description));
    dialogButton(record, t("Confirm"), function () {
      var controls = record.actions.querySelectorAll('button'); for (var i = 0; i < controls.length; i++) controls[i].disabled = true;
      Promise.resolve().then(action).then(function () { closeDialog(false, record); }, function (error) {
        for (var j = 0; j < controls.length; j++) controls[j].disabled = false;
        text(record.error, message(error, t("Could not perform this action.")));
      });
    }, true);
    focus(dialogButton(record, t("Cancel"), function () { closeDialog(true); }));
  }
  function requestExit() {
    if (exitPending) return;
    function exit() {
      if (exitPending) return exitPending;
      exitPending = Promise.resolve().then(function () { return platform.exit(); });
      return exitPending.then(function () { exitPending = null; }, function (error) { exitPending = null; throw error; });
    }
    if (window.TVBroPlatformAdapters && window.TVBroPlatformAdapters.confirmExit === true) {
      confirmAction(t('Exit TVBro?'), t('Do you want to close TVBro?'), exit);
    } else exit().catch(report);
  }
  function optionDialog(title, options, selected, action) {
    var record = dialog(title), list = element('div', 'dialog-list'); record.body.appendChild(list);
    options.forEach(function (option) {
      list.appendChild(button(option.label, 'button' + (option.value === selected ? ' selected-option' : ''), function () {
        Promise.resolve().then(function () { return action(option.value); }).then(function () { closeDialog(false, record); }, function (error) { text(record.error, message(error, t("Could not change the setting."))); });
      }));
    });
    dialogButton(record, t("Back"), function () { closeDialog(true); }); focus(list.querySelector('button') || record.actions.firstChild);
  }
  function showScreen(name, target) {
    if (suspendedDetails && name !== suspendedDetails.screen) discardDetails();
    cancelPlayerZap();
    cancelPreviewIdleTimer();
    if (view.screen === 'pairing' && name !== 'pairing') { stopPairingWatch(); ++view.pairingRequest; }
    if (name !== 'catalog') { window.clearTimeout(searchTimer); searchTimer = null; window.clearTimeout(guideScrollTimer); guideScrollTimer = null; window.clearTimeout(channelNowNextTimer); channelNowNextTimer = null; ++view.guideRequest; }
    if (name !== 'media') { window.clearTimeout(mediaSearchTimer); mediaSearchTimer = null; ++view.mediaRequest; }
    if (name !== view.screen) detailsStart = null;
    var screens = document.querySelectorAll('[data-screen]');
    for (var i = 0; i < screens.length; i++) screens[i].hidden = screens[i].getAttribute('data-screen') !== name;
    view.screen = name;
    var shell = byId('app-shell'), header = document.querySelector('.app-header');
    shell.setAttribute('data-active-screen', name);
    var section = name === 'catalog' || name === 'media';
    var toolbar = section && byId(name + '-view').querySelector('.catalog-toolbar, .guide-toolbar');
    if (toolbar) toolbar.insertBefore(header, toolbar.firstChild);
    else shell.insertBefore(header, shell.firstChild);
    var onboarding = name === 'language' || name === 'profiles' || name === 'setup' || name === 'pairing' && view.pairingOnboarding;
    byId('show-home').hidden = !view.source || name === 'home' || onboarding;
    byId('show-sources').hidden = section || !view.profile || name === 'sources' || onboarding;
    byId('show-profiles').hidden = section || !cap('profiles') || onboarding;
    byId('show-settings').hidden = section || !view.profile || name === 'settings' || onboarding;
    if (name !== 'catalog' && view.preview && !view.player) suspendPreview();
    status(''); if (target !== false) focus(target || byId(name + '-view').querySelector('[data-nav]')); scheduleArtwork();
  }
  function applyBootstrap(data) {
    view.profiles = array(data.profiles); view.profile = data.profile || null; view.sources = array(data.sources);
    view.settings = data.settings || {}; view.caps = data.capabilities || {}; view.favorites = array(data.favorites); view.history = array(data.history);
    view.activeSourceId = data.activeSourceId || null;
    view.showProfilePicker = data.showProfilePicker === true;
    view.languageSelected = data.languageSelected === true; view.languageCode = data.languageCode || 'en';
    view.languages = array(data.languages); applyUiLanguage(view.languageCode);
    ['movie', 'series', 'favorites'].forEach(function (kind) { byId('home-' + kind).hidden = !cap(kind === 'movie' ? 'movies' : kind); });
    ['m3u', 'xtream', 'stalker'].forEach(function (kind) { byId('kind-' + kind).hidden = (view.caps.sourceKinds || []).indexOf(kind) < 0; });
    if ((view.caps.sourceKinds || []).indexOf(view.kind) < 0) view.kind = (view.caps.sourceKinds || [])[0] || 'm3u';
    byId('show-guide').hidden = !cap('guide'); byId('preview-panel').hidden = !cap('preview'); renderFields(); renderSources();
  }
  function refreshBootstrap() { return query('bootstrap').then(function (data) { applyBootstrap(data); return data; }); }
  function afterProfile(data) {
    ++view.request; ++view.mediaRequest; ++view.guideRequest;
    ++view.pairingRequest; view.pairingOnboarding = false; view.pairingReady = false;
    view.source = null; view.channels = []; view.categories = []; view.nowNext = {}; clearPlaybackPresentation();
    applyBootstrap(data); view.manageProfiles = false; if (!view.profile) showProfiles(); else { openProfileContent(); refreshParental().catch(report); }
  }
  function profileSelectionBusy(value) {
    view.profileSelecting = value; busy(value);
    var controls = byId('profiles-view').querySelectorAll('button');
    for (var i = 0; i < controls.length; i++) controls[i].disabled = value;
    if (!value && view.screen === 'profiles') renderProfiles();
  }
  function selectExistingProfile(profile) {
    if (view.busy || view.profileSelecting) return Promise.resolve();
    var request = ++view.request; profileSelectionBusy(true); status(t('Preparing your profile…'));
    return afterLoadingPaint().then(function () {
      if (request !== view.request || view.screen !== 'profiles') throw cancelled();
      return query('profiles.select', { id: profile.id, source: profile.source || 'local' });
    }).then(function (data) {
      if (request !== view.request || view.screen !== 'profiles') return;
      profileSelectionBusy(false); afterProfile(data);
    }).catch(function (error) {
      if (request !== view.request || view.screen !== 'profiles') return;
      profileSelectionBusy(false); report(error);
    });
  }
  function showProfiles() { showScreen('profiles', false); renderProfiles(); focus(byId('profile-list').querySelector('button') || byId('add-profile')); }
  function renderProfiles() {
    var parent = byId('profile-list'); clear(parent);
    var localProfiles = view.profiles.some(function (profile) { return profile.source !== 'cloud'; });
    if (!localProfiles) view.manageProfiles = false;
    view.profiles.forEach(function (profile) {
      var node = button('', 'profile-card', function () { if (view.manageProfiles) manageProfile(profile); else selectExistingProfile(profile); });
      node.appendChild(element('span', 'profile-avatar', String(profile.name || '?').charAt(0).toUpperCase())); node.appendChild(element('span', 'profile-name', profile.name));
      node.appendChild(element('span', 'profile-origin', profile.source === 'cloud' ? t("Cloud profile") : t("Local profile")));
      node.disabled = view.manageProfiles && profile.source === 'cloud';
      if (profile.pinSet) node.appendChild(element('span', 'profile-lock', 'PIN')); parent.appendChild(node);
    });
    text(byId('manage-profiles'), view.manageProfiles ? t("Done") : t("Manage profiles")); byId('manage-profiles').hidden = !localProfiles; byId('skip-profile').hidden = !view.profile;
    byId('download-cloud').hidden = !cap('pairing') || view.manageProfiles;
    text(byId('profiles-message'), view.manageProfiles ? t("Choose a profile to manage.") : t("Choose a profile to continue"));
  }
  function showSetup() {
    if (!view.profile) { showProfiles(); return; }
    view.sourceSetup = false; text(byId('setup-title'), t('Set up {profile}', { profile: view.profile.name }));
    byId('setup-cloud').hidden = !cap('pairing'); showScreen('setup', byId('setup-source'));
  }
  function useDemo() {
    if (view.busy) return;
    var request = ++view.request;
    busy(true); status(t("Preparing Demo…"));
    query('sources.demo').then(function () { if (request === view.request) return refreshBootstrap(); }).then(function () {
      if (request !== view.request) return;
      busy(false); var config = view.sources.filter(function (row) { return row.id === 'demo'; })[0];
      if (!config) throw new Error(t("Could not prepare the Demo source."));
      return loadSource(config);
    }).catch(function (error) { if (request === view.request) { busy(false); report(error); } });
  }
  function profileForm(profile) {
    var record = dialog(profile ? t("Rename profile") : t("Add profile"));
    var name = editableInput(record.body, t("Profile name"), 'text', profile && profile.name, 80);
    var pin = profile ? null : editableInput(record.body, t("PIN (optional)"), 'password', '', 4); if (pin) pin.setAttribute('inputmode', 'numeric');
    dialogButton(record, t("Save"), function () {
      var args = { name: name.value }; if (profile) args.id = profile.id; else args.pin = pin.value;
      query(profile ? 'profiles.rename' : 'profiles.create', args).then(function (data) { closeDialog(false, record); if (profile) { applyBootstrap(data); renderProfiles(); } else afterProfile(data); }).catch(function (error) { text(record.error, message(error, t("Could not save the profile."))); });
    }, true);
    dialogButton(record, t("Cancel"), function () { closeDialog(true); }); focus(name);
  }
  function manageProfile(profile) {
    var record = dialog(profile.name), list = element('div', 'dialog-list'); record.body.appendChild(list);
    list.appendChild(button(t("Rename"), 'button', function () { closeDialog(false); profileForm(profile); }));
    list.appendChild(button(profile.pinSet ? t("Change or remove PIN") : t("Set a PIN"), 'button', function () {
      closeDialog(false); var form = dialog(t("Profile PIN"));
      var current = profile.pinSet ? editableInput(form.body, t("Current PIN"), 'password', '', 4) : null;
      var next = editableInput(form.body, t("New PIN (leave blank to remove)"), 'password', '', 4); next.setAttribute('inputmode', 'numeric'); if (current) current.setAttribute('inputmode', 'numeric');
      dialogButton(form, t("Save"), function () { query('profiles.pin', { id: profile.id, currentPin: current ? current.value : '', pin: next.value }, true).then(function (data) { closeDialog(false, form); applyBootstrap(data); renderProfiles(); }).catch(function (error) { text(form.error, message(error, t("Could not change the PIN."))); }); }, true);
      dialogButton(form, t("Cancel"), function () { closeDialog(true); }); focus(current || next);
    }));
    list.appendChild(button(t("Delete profile"), 'button', function () { closeDialog(false); confirmAction(t("Delete profile?"), profile.name, function () { return query('profiles.delete', { id: profile.id }).then(function (data) { applyBootstrap(data); renderProfiles(); }); }); }));
    dialogButton(record, t("Back"), function () { closeDialog(true); }); focus(list.firstChild);
  }
  function sourceName(config) { return config.label || ({ m3u: t("M3U playlist"), xtream: 'Xtream Codes', stalker: 'Stalker / MAG' })[config.kind] || t("Source"); }
  function renderFields(config) {
    var metadata = validation.KIND_FIELDS[view.kind] || [], allowed = view.caps.sourceFields && view.caps.sourceFields[view.kind] || [];
    var parent = byId('source-fields'); fieldInputs = {}; clear(parent);
    metadata.forEach(function (field) {
      if (allowed.indexOf(field.key) < 0) return;
      var label = element('label', '', uiLabel(field.label)), input = element('input');
      input.id = 'source-field-' + field.key; input.type = field.password ? 'password' : 'text'; input.readOnly = true;
      input.required = !!field.required; input.maxLength = field.maxLength; input.autocomplete = 'off';
      input.setAttribute('autocapitalize', 'off'); input.setAttribute('spellcheck', 'false'); input.setAttribute('data-nav', ''); input.setAttribute('data-editable', '');
      label.htmlFor = input.id; input.value = config && config.fields && config.fields[field.key] || '';
      parent.appendChild(label); parent.appendChild(input); fieldInputs[field.key] = input;
    });
    ['m3u', 'xtream', 'stalker'].forEach(function (kind) { byId('kind-' + kind).className = 'source-tab' + (kind === view.kind ? ' is-active' : ''); byId('kind-' + kind).setAttribute('aria-pressed', kind === view.kind ? 'true' : 'false'); });
  }
  function cancelSourceEdit() { view.editSource = null; byId('source-form').reset(); renderFields(); text(byId('source-form-title'), t("Add source")); text(byId('connect-source'), t("Connect and load channels")); byId('cancel-source-edit').hidden = true; }
  function renderSources() {
    var parent = byId('saved-sources'); clear(parent);
    view.sources.forEach(function (config) {
      var row = element('div', 'source-row');
      row.appendChild(button(sourceName(config), 'button source-open', function () { loadSource(config); }));
      row.appendChild(button(t("Edit"), 'button source-edit', function () {
        view.editSource = config; view.kind = config.kind; renderFields(config); byId('source-label').value = config.label || '';
        text(byId('source-form-title'), t("Edit source")); text(byId('connect-source'), t("Save and open")); byId('cancel-source-edit').hidden = false; focus(byId('source-label'));
      }));
      row.appendChild(button(t('Settings'), 'button source-edit', function () { sourceTools(config); }));
      row.appendChild(button(t("Delete"), 'button source-remove', function () {
        confirmAction(t("Delete source?"), sourceName(config), function () { return query('sources.remove', { id: config.id }).then(function (sources) {
          view.sources = array(sources); clearPlaybackPresentation(); if (view.source && view.source.id === config.id) view.source = null; renderSources(); status(t("Source removed."));
        }); });
      })); parent.appendChild(row);
    });
  }
  function showSources(fromSetup) {
    if (view.busy) return;
    if (!view.profile) { showProfiles(); return; }
    if (!view.sources.length && fromSetup !== true) { showSetup(); return; }
    view.sourceSetup = fromSetup === true;
    if (view.preview || view.player) stopPlayback(false);
    cancelSourceEdit(); showScreen('sources'); renderSources(); focus(byId('saved-sources').querySelector('button') || byId('kind-' + view.kind));
  }
  function sourceTools(config) {
    if (!view.source || view.source.id !== config.id) return loadSource(config).then(function () { if (view.source && view.source.id === config.id) sourceTools(view.source); });
    var record = dialog(sourceName(config)), list = element('div', 'dialog-list'); record.body.appendChild(list);
    list.appendChild(button(t('Source settings'), 'button', function () { sourceSettings(config); }));
    list.appendChild(button(t('Organize channels'), 'button', function () { openOrganization(config); }));
    list.appendChild(button(t('Hide categories'), 'button', function () {
      optionDialog(t('Hide categories'), [{value:'live',label:t('TV')},{value:'movie',label:t('Movies')},{value:'series',label:t('Series')}], null, function (kind) {
        closeDialog(false); return openCategoryVisibility(config, kind);
      });
    }));
    if (cap('guide')) list.appendChild(button(t('EPG mapping'), 'button', function () {
      var current = editorContext();
      query('organization.get', {sourceId:config.id}).then(function (data) {
        if (!current()) return;
        pagedEditor(t('EPG mapping'), array(data.channels), function (channel) { return channel.name; }, function (channel) { epgMapping(config, channel); });
      }).catch(report);
    }));
    dialogButton(record, t('Back'), function () { closeDialog(true, record); }); focus(list.firstChild);
  }
  function applyEditedCatalog(data) {
    var catalog = data && data.catalog;
    if (!catalog || !view.source || !catalog.source || catalog.source.id !== view.source.id) return;
    setCatalog(catalog, catalog.source);
    if (view.screen === 'catalog') { renderCategories(); renderChannels(); }
  }
  function editorContext() {
    var parent = dialogs[dialogs.length - 1], request = view.request, screen = view.screen;
    return function () { return request === view.request && screen === view.screen && (!parent || !parent.closed); };
  }
  function openOrganization(config) {
    var current = editorContext();
    return query('organization.get', {sourceId:config.id}).then(function (data) {
      if (!current()) return;
      var state = {config:config,data:data,saving:false};
      state.record = pagedEditor(t('Organize channels'), array(data.channels), function (channel) {
        return channel.name + (array(state.data.organization.hidden).indexOf(channel.id) >= 0 ? ' · ' + t('Hidden') : '');
      }, function (channel) { editOrganizedChannel(state, channel); });
      dialogButton(state.record, t('New group'), function () { editChannelGroup(state); });
      dialogButton(state.record, t('Groups'), function () {
        var record = pagedEditor(t('Groups'), array(state.data.organization.groups), function (group) { return group.name; }, function (group) { editChannelGroup(state, group); }, t('Group name'));
        state.groupsRecord = record;
      });
    }).catch(report);
  }
  function saveOrganization(state, organization, record) {
    if (state.saving) return Promise.resolve();
    state.saving = true;
    return query('organization.set', {sourceId:state.config.id,organization:organization}).then(function (data) {
      applyEditedCatalog(data);
      if (state.record.closed) return;
      state.data = data; state.record.rows = array(data.channels); state.record.repaint(true);
      if (state.groupsRecord && !state.groupsRecord.closed) { state.groupsRecord.rows = array(data.organization.groups); state.groupsRecord.repaint(true); }
      if (record) closeDialog(false, record); return true;
    }).catch(function (error) { text((record || state.record).error, message(error)); return false; }).then(function (saved) { state.saving = false; return saved; });
  }
  function organizationCopy(state) { return JSON.parse(JSON.stringify(state.data.organization)); }
  function editOrganizedChannel(state, channel) {
    var record = dialog(channel.name), name = editableInput(record.body, t('Channel name'), 'text', channel.name, 240);
    record.body.appendChild(element('p', 'muted', t('Empty restores the provider name')));
    dialogButton(record, t('Save'), function () {
      var next = organizationCopy(state), value = name.value.trim(); next.names = next.names || {};
      if (value) next.names[channel.id] = value; else delete next.names[channel.id]; saveOrganization(state, next, record);
    }, true);
    var hidden = array(state.data.organization.hidden).indexOf(channel.id) >= 0;
    dialogButton(record, t(hidden ? 'Show channel' : 'Hide channel'), function () {
      var next = organizationCopy(state); next.hidden = array(next.hidden).filter(function (id) { return id !== channel.id; });
      if (!hidden) next.hidden.push(channel.id); saveOrganization(state, next, record);
    });
    [-1, 1].forEach(function (delta) {
      var index = state.data.channels.map(function (row) { return row.id; }).indexOf(channel.id), target = index + delta;
      var move = dialogButton(record, t(delta < 0 ? 'Move up' : 'Move down'), function () {
        var next = organizationCopy(state), order = state.data.channels.map(function (row) { return row.id; });
        order[index] = order[target]; order[target] = channel.id; next.order = order; saveOrganization(state, next, record);
      }); move.disabled = target < 0 || target >= state.data.channels.length;
    });
    dialogButton(record, t('Groups'), function () {
      var next = organizationCopy(state), groups = array(next.groups);
      var groupRecord = pagedEditor(t('Groups'), groups, function (group) { return (array(group.channels).indexOf(channel.id) >= 0 ? '✓ ' : '') + group.name; }, function (group, picker) {
        var ids = array(group.channels), index = ids.indexOf(channel.id); if (index < 0) ids.push(channel.id); else ids.splice(index, 1); group.channels = ids; picker.repaint(true);
      }, t('Group name'));
      dialogButton(groupRecord, t('Save'), function () { saveOrganization(state, next, groupRecord).then(function () { if (!groupRecord.closed) return; closeDialog(false, record); }); }, true);
    });
    dialogButton(record, t('Back'), function () { closeDialog(true, record); }); focus(name);
  }
  function editChannelGroup(state, group) {
    var record = dialog(t(group ? 'Group name' : 'New group')), input = editableInput(record.body, t('Group name'), 'text', group ? group.name : '', 200);
    dialogButton(record, t('Save'), function () {
      if (!input.value.trim()) return;
      var next = organizationCopy(state), groups = array(next.groups);
      if (group) groups.forEach(function (row) { if (row.id === group.id) row.name = input.value.trim(); });
      else groups.push({id:'tvbro.group.' + core.newSourceId(),name:input.value.trim(),channels:[]});
      next.groups = groups; saveOrganization(state, next, record);
    }, true);
    if (group) dialogButton(record, t('Delete'), function () {
      confirmAction(t('Delete group?'), t('Channels stay in your source.'), function () {
        var next = organizationCopy(state); next.groups = array(next.groups).filter(function (row) { return row.id !== group.id; });
        return saveOrganization(state, next).then(function (saved) { if (saved) { closeDialog(false); closeDialog(false, record); } else throw new Error(state.record.error.textContent); });
      });
    });
    dialogButton(record, t('Back'), function () { closeDialog(true, record); }); focus(input);
  }
  function openCategoryVisibility(config, kind) {
    var current = editorContext();
    return query('organization.get', {sourceId:config.id,kind:kind}).then(function (data) {
      if (!current()) return;
      var hidden = array(data.hiddenCategoryIds).slice();
      var record = pagedEditor(t('Hide categories'), array(data.categories), function (category) { return (category.title || category.name) + (hidden.indexOf(category.id) >= 0 ? ' · ' + t('Hidden') : ''); }, function (category, picker) {
        var index = hidden.indexOf(category.id); if (index < 0) hidden.push(category.id); else hidden.splice(index, 1); picker.repaint(true);
      }, t('Categories'));
      dialogButton(record, t('Save'), function () {
        if (record.saving) return; record.saving = true;
        query('organization.set', {sourceId:config.id,kind:kind,hiddenCategoryIds:hidden}).then(function (updated) { applyEditedCatalog(updated); closeDialog(false, record); }).catch(function (error) { record.saving = false; text(record.error, message(error)); });
      }, true);
    }).catch(report);
  }
  function sourceSettings(config) {
    var current = editorContext();
    return query('sourceSettings.get', {sourceId:config.id}).then(function (data) {
      if (!current()) return;
      var record = dialog(t('Source settings'), true), inputs = [], urls = [];
      if (data.expiry) {
        var expiry = data.expiry, expiryText = expiry.kind === 'unlimited' ? t('Unlimited') : expiry.date ? new Date(expiry.date).toLocaleDateString() : t('Expiry date unavailable');
        record.body.appendChild(element('p', 'muted', t('Playlist expiry') + ': ' + expiryText));
        if (expiry.notice) record.body.appendChild(element('p', 'source-expiry-notice', t(expiry.notice === 'expired' ? 'Your playlist has expired.' : 'Your playlist expires on {date}.', {date:expiryText})));
      }
      array(data.fields).forEach(function (field) {
        var current = field.value == null ? (field.scope === 'fields' ? (data.values || config.fields || {})[field.key] : (data.settings || {})[field.key]) : field.value;
        if (field.type === 'urls') {
          var container = element('div', 'source-guide-fields'); record.body.appendChild(container);
          function addUrl(value) { var input = editableInput(container, t('EPG URL (optional)') + ' ' + (urls.length + 1), 'text', value, 4096); urls.push(input); }
          (Array.isArray(current) ? current : String(current || '').split(/\r?\n/)).filter(function (value) { return !!value; }).slice(0, 8).forEach(addUrl);
          if (!urls.length) addUrl('');
          record.body.appendChild(element('p', 'field-hint', t('Clear a URL to remove that guide. Guides are tried in this order.')));
          var add = button(t('Add guide'), 'button', function () { if (urls.length < (field.maxItems || 8)) { addUrl(''); focus(urls[urls.length - 1]); } add.disabled = urls.length >= (field.maxItems || 8); });
          record.body.appendChild(add); add.disabled = urls.length >= (field.maxItems || 8);
          inputs.push({field:field,read:function () { return urls.map(function (input) { return input.value.trim(); }).filter(function (value) { return !!value; }).join('\n'); }});
        } else if (field.type === 'select' && Array.isArray(field.options)) {
          function optionLabel(option) {return field.key === 'expiryReminderDays' ? option.value === 0 ? t('Off') : t('{days} days before',{days:option.value}) : uiLabel(option.label);}
          var value = current, row = button('', 'setting-row', function () {
            optionDialog(uiLabel(field.label), field.options.map(function (option) { return {value:option.value,label:optionLabel(option)}; }), value, function (next) { value = next; update(); return Promise.resolve(); });
          });
          function update() { var selected = field.options.filter(function (option) { return option.value === value; })[0]; text(row, uiLabel(field.label) + ': ' + (selected ? optionLabel(selected) : t('Default'))); }
          update(); record.body.appendChild(row); inputs.push({field:field,read:function () { return value; }});
        } else if (field.type === 'text' || field.type === 'number') {
          var input = editableInput(record.body, uiLabel(field.label), 'text', current == null ? '' : String(current), field.maxLength || 4096);
          if (field.type === 'number') input.setAttribute('inputmode', 'numeric');
          inputs.push({field:field,read:function () { return input.value.trim(); }});
        }
      });
      dialogButton(record, t('Save'), function () {
        if (record.saving) return;
        var settings = {}, fields = {};
        inputs.forEach(function (entry) { (entry.field.scope === 'fields' ? fields : settings)[entry.field.key] = entry.read(); });
        record.saving = true;
        query('sourceSettings.set', {sourceId:config.id,settings:settings,fields:fields}).then(function (updated) {
          applyEditedCatalog(updated); return Promise.all([query('sources.list'),query('sources.catalog')]);
        }).then(function (data) { view.sources = array(data[0]); applyEditedCatalog({catalog:data[1]}); if (view.screen === 'sources') renderSources(); closeDialog(false, record); }).catch(function (error) { record.saving = false; text(record.error, message(error)); });
      }, true);
      dialogButton(record, t('Back'), function () { closeDialog(true, record); }); focus(record.body.querySelector('[data-nav]') || record.actions.firstChild);
    }).catch(report);
  }
  function epgMapping(config, channel) {
    var current = editorContext();
    return query('guide.mapping.get', {sourceId:config.id,channelId:channel.id,limit:40}).then(function (data) {
      if (!current()) return;
      var record = dialog(t('EPG mapping') + ' · ' + channel.name, true), selected = data.override || {}, revision = 0;
      var selection = element('p', 'muted'); record.body.appendChild(selection);
      function updateSelection() { text(selection, selected.guideChannelId ? t('Selected guide channel: {id}', {id:selected.guideChannelId}) : t('Automatic matching')); }
      updateSelection();
      record.body.appendChild(button(t('Automatic matching'), 'button', function () { selected = {}; updateSelection(); }));
      var offset = editableInput(record.body, t('Time correction in minutes'), 'text', String((data.override || {}).offsetMinutes || 0), 6); offset.setAttribute('inputmode', 'numeric');
      record.body.appendChild(element('p', 'field-hint', t('Positive values move programmes later; negative values move them earlier.')));
      var search = editableInput(record.body, t('Find a guide channel by name or ID'), 'search', '', 200), list = element('div', 'dialog-list'); record.body.appendChild(list);
      function renderCandidates(rows) {
        clear(list); array(rows).slice(0, 40).forEach(function (candidate) {
          list.appendChild(button(candidate.name + ' · ' + candidate.guideLabel + ' · ' + candidate.channelId, 'button editor-item', function () { selected = candidate; selected.guideChannelId = candidate.channelId; updateSelection(); }));
        });
      }
      if (!data.available || !array(data.channels).length) record.body.appendChild(element('p', 'muted', t('No XMLTV channel catalogue is cached yet. Refresh the guide first.')));
      renderCandidates(data.channels);
      var timer = null;
      search.addEventListener('input', function () {
        window.clearTimeout(timer); var current = ++revision;
        timer = window.setTimeout(function () {
          timer = null; if (record.closed) return;
          query('guide.mapping.get', {sourceId:config.id,channelId:channel.id,query:search.value,limit:40}).then(function (result) { if (!record.closed && current === revision) renderCandidates(result.channels); }).catch(function (error) { if (!record.closed && current === revision) text(record.error, message(error)); });
        }, 180);
      });
      dialogButton(record, t('Save'), function () {
        if (record.saving) return;
        if (!/^-?\d+$/.test(offset.value.trim()) || Math.abs(Number(offset.value)) > 1440) { text(record.error, t('Enter whole minutes between −1440 and 1440.')); return; }
        record.saving = true;
        query('guide.mapping.set', {sourceId:config.id,channelId:channel.id,guideId:selected.guideId || null,guideChannelId:selected.guideChannelId || null,offsetMinutes:Number(offset.value)}).then(function () {
          view.guideData = Object.create(null); view.guideDataOrder = []; view.guideDataRange = ''; view.nowNext = {}; view.nowNextAt = Object.create(null);
          closeDialog(false, record); if (view.screen === 'catalog' && view.source && view.source.id === config.id) renderChannels();
        }).catch(function (error) { record.saving = false; text(record.error, message(error)); });
      }, true);
      dialogButton(record, t('Back'), function () { window.clearTimeout(timer); closeDialog(true, record); }); focus(offset);
    }).catch(report);
  }
  function searchProgrammes() {
    if (!view.source) return;
    var source = view.source, record = dialog(t('Search programmes'), true), revision = 0, timer = null;
    record.body.appendChild(element('p', 'muted', t('Searches the guide already loaded on this TV.')));
    var input = editableInput(record.body, t('Search programmes'), 'search', '', 200), list = element('div', 'dialog-list'); record.body.appendChild(list);
    function search() {
      window.clearTimeout(timer); var current = ++revision; clear(list); if (!input.value.trim()) return;
      timer = window.setTimeout(function () {
        timer = null; if (record.closed) return;
        query('guide.search', {sourceId:source.id,query:input.value,limit:40}).then(function (data) {
          if (record.closed || current !== revision) return;
          array(data.programmes).slice(0, 40).forEach(function (entry) {
            list.appendChild(button(entry.programme.title + ' · ' + entry.channel.name + ' · ' + new Date(entry.programme.start).toLocaleDateString() + ' ' + clock(entry.programme.start), 'button editor-item', function () { showProgramme(entry.programme, entry.channel); }));
          });
          text(record.error, list.firstChild ? '' : t('No programmes in this time range.'));
        }).catch(function (error) { if (!record.closed && current === revision) text(record.error, message(error)); });
      }, 180);
    }
    input.addEventListener('input', search); dialogButton(record, t('Back'), function () { window.clearTimeout(timer); closeDialog(true, record); }); focus(input);
  }
  function chooseBackupPath(exporting) {
    return new Promise(function (resolve, reject) {
      var record = dialog(t(exporting ? 'Choose backup folder' : 'Choose backup file'), true, function () { reject(cancelled()); });
      var location = element('p', 'muted backup-location'), list = element('div', 'dialog-list'), entries = [], path = '', page = 0, revision = 0;
      record.body.appendChild(location); record.body.appendChild(list);
      function finish(value) { closeDialog(false, record); resolve(value); }
      function repaint() {
        clear(list); var pages = Math.max(1, Math.ceil(entries.length / 40)); page = Math.max(0, Math.min(page, pages - 1));
        entries.slice(page * 40, (page + 1) * 40).forEach(function (entry) {
          var directory = entry.isDirectory === true || entry.label != null;
          var row = button((directory ? '▸ ' : '') + (entry.name || entry.label), 'button editor-item', function () { if (directory) load(entry.path || entry.label); else finish(entry.path); });
          row.disabled = !directory && entry.size > 32 * 1024 * 1024; list.appendChild(row);
        });
        previous.disabled = page === 0; next.disabled = page + 1 >= pages; up.disabled = !path; if (choose) choose.disabled = !path;
      }
      function load(nextPath) {
        var current = ++revision; text(record.error, t('Loading…'));
        query('backup.files.list', nextPath ? {path:nextPath} : {}).then(function (data) {
          if (record.closed || revision !== current) return;
          path = data.path || ''; page = 0;
          entries = array(data.entries || data.storages).filter(function (entry) { return entry.label != null || entry.isDirectory || !exporting && /\.tvbro$/i.test(entry.name); });
          text(location, path); text(record.error, data.truncated ? t('Only the first 200 entries are shown. Open a folder to narrow the list.') : ''); repaint(); focus(list.firstChild || choose || up);
        }).catch(function (error) { if (!record.closed && revision === current) { text(record.error, message(error)); focus(up.disabled ? record.actions.lastChild : up); } });
      }
      var up = dialogButton(record, t('Up'), function () { var slash = path.lastIndexOf('/'); load(slash < 0 ? '' : path.slice(0,slash)); });
      var previous = dialogButton(record, t('Previous'), function () { page--; repaint(); focus(list.firstChild); });
      var next = dialogButton(record, t('Next'), function () { page++; repaint(); focus(list.firstChild); });
      var choose = exporting ? dialogButton(record, t('Use this folder'), function () { if (path) finish(path); }, true) : null;
      dialogButton(record, t('Back'), function () { closeDialog(true, record); }); repaint(); load('');
    });
  }
  function backupFlow(exporting) {
    chooseBackupPath(exporting).then(function (path) {
      var record = dialog(t(exporting ? 'Export encrypted backup' : 'Import encrypted backup'), true);
      record.body.appendChild(element('p', 'muted backup-location', path));
      var filename = exporting ? editableInput(record.body, t('File name'), 'text', 'TVBro-' + new Date().toISOString().slice(0,10) + '.tvbro', 100) : null;
      var password = editableInput(record.body, t('Backup password'), 'password', '', 4096);
      var confirmation = exporting ? editableInput(record.body, t('Confirm password'), 'password', '', 4096) : null;
      record.body.appendChild(element('p', 'field-hint', t('Use a password with at least 8 characters.')));
      dialogButton(record, t(exporting ? 'Export encrypted backup' : 'Continue'), function () {
        if (record.saving) return;
        if (!record.archive && password.value.length < 8) { text(record.error, t('Use a password with at least 8 characters.')); return; }
        if (!record.archive && confirmation && password.value !== confirmation.value) { text(record.error, t('Passwords do not match.')); return; }
        record.saving = true; var secret = password.value; password.value = ''; if (confirmation) confirmation.value = '';
        text(record.error, t(exporting ? 'Encrypting backup…' : 'Reading encrypted backup…'));
        var ready = exporting ? record.archive ? Promise.resolve(record.archive) : query('backup.export', {password:secret}) : query('backup.import.read', {path:path}).then(function (data) { if (record.closed) throw cancelled(); return query('backup.inspect', {bytes:data.bytes,password:secret}); });
        ready.then(function (data) {
          secret = ''; if (record.closed) throw cancelled();
          if (exporting) {
            record.archive = data;
            return query('backup.export.save', {bytes:data.bytes,filename:filename.value,directoryPath:path}).then(function (saved) { closeDialog(false, record); status(t('Backup saved: {path}', {path:saved.path})); });
          }
          closeDialog(false, record); confirmBackupImport(data);
        }).catch(function (error) { secret = ''; record.saving = false; if (!record.closed && error.code !== 'ui_cancelled') text(record.error, message(error)); });
      }, true);
      dialogButton(record, t('Back'), function () { closeDialog(true, record); }); focus(filename || password);
    }).catch(report);
  }
  function confirmBackupImport(data) {
    var record = dialog(t('Import encrypted backup')), summary = data.summary || {};
    record.body.appendChild(element('p', 'muted', t('The backup adds recovery profiles. Your current profiles and settings stay as they are.')));
    record.body.appendChild(element('p', '', t('{profiles} profiles · {sources} sources · {favorites} favorites', {profiles:summary.profileCount || 0,sources:summary.sourceCount || 0,favorites:summary.favoriteCount || 0})));
    dialogButton(record, t('Add recovery profiles'), function () {
      if (record.saving) return; record.saving = true;
      query('backup.import', {token:data.token}).then(function () {
        closeAllDialogs(); return refreshBootstrap();
      }).then(function () { view.manageProfiles = false; showProfiles(); status(t('Recovery profiles added.')); }).catch(function (error) { record.saving = false; if (!record.closed) text(record.error, message(error)); else report(error); });
    }, true);
    dialogButton(record, t('Cancel'), function () { closeDialog(true, record); }); focus(record.actions.firstChild);
  }
  function loadSource(config) {
    cancelPlayerZap();
    if (view.busy) return Promise.resolve();
    if (view.caps.requiresHttpsProvider === true && hostedHttpSource(config)) {
      status(t('This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.'), true); return Promise.resolve();
    }
    var request = ++view.request, screen = view.screen; busy(true); status(t("Loading source…") + ' ' + sourceName(config));
    return afterLoadingPaint().then(function () {
      if (request !== view.request) throw cancelled();
      return query('sources.load', { id: config.id });
    }).then(function (catalog) {
      if (request !== view.request) return;
      clearPlaybackPresentation(); setCatalog(catalog, config); busy(false); if (view.screen === screen) showHome();
      var notices = [], warnings = catalog.preparation && catalog.preparation.warnings || [];
      view.catalogPreparationWarningKey = warnings.length ? JSON.stringify(warnings) : '';
      if (warnings.length) notices.push(t('Some sections could not be loaded: {sections}. Available sections remain usable.', {
        sections:warnings.map(function (warning) { return warning.label && t(warning.label); }).filter(Boolean).join(', ')}));
      if (catalog.cachePersisted === false) notices.push(t("Could not save the channel list on this TV. It may need to download again next time."));
      if (catalog.expiry && catalog.expiry.notice) notices.push(t(catalog.expiry.notice === 'expired' ? 'Your playlist has expired.' : 'Your playlist expires on {date}.', {date:new Date(catalog.expiry.date).toLocaleDateString()}));
      if (notices.length) status(notices.join(' '), catalog.cachePersisted === false || catalog.expiry && catalog.expiry.notice === 'expired');
    }).catch(function (error) { if (request === view.request) { busy(false); report(error, t("Could not load the source.")); } });
  }
  function hostedHttpSource(config) {
    if (!config || !config.fields) return false;
    var fields = config.fields;
    if (config.kind === 'xtream') {
      var host = String(fields.host || '').trim();
      return !!host && !/^https:\/\//i.test(host);
    }
    if (config.kind !== 'm3u') return false;
    return [fields.playlistUrl, fields.epgUrl, fields.epgUrls].some(function (value) {
      return String(value || '').split(/\r?\n/).some(function (url) { return /^\s*http:/i.test(url); });
    });
  }
  function setCatalog(catalog, config) {
    view.source = catalog.source || config; view.categories = array(catalog.categories); view.channels = array(catalog.channels);
    if (catalog.capabilities) view.caps = catalog.capabilities;
    view.category = null; view.page = 0; view.nowNext = {}; view.nowNextAt = Object.create(null); view.guideFrom = 0; view.guideStartIndex = 0; view.guideFilter = null;
    view.guideData = Object.create(null); view.guideDataOrder = []; view.guideDataRange = ''; byId('channel-search').value = '';
    view.guideScrollRow = -1; guideRenderState = null;
    text(byId('source-title'), sourceName(view.source)); text(byId('home-source'), sourceName(view.source));
    byId('preview-panel').hidden = !cap('preview'); byId('show-guide').hidden = !cap('guide');
  }
  function showHome() {
    if (!view.source) { showSources(); return; }
    showScreen('home'); text(byId('home-source'), sourceName(view.source));
    renderHistory(byId('home-history-list'), view.history); byId('home-history').hidden = !view.history.length;
    query('history.list').then(function (data) { view.history = array(data); if (view.screen === 'home') { renderHistory(byId('home-history-list'), view.history); byId('home-history').hidden = !view.history.length; } }).catch(report);
    focus(byId('home-live'));
  }
  function showLive() {
    if (!view.source || view.screen === 'catalog') return;
    showScreen('catalog'); renderCategories(); renderChannels();
    focus(firstLiveChannel() || byId('category-list').querySelector('button'));
    if (!usesLiveGuide()) loadNowNext(view.filtered.slice(view.page * pageSize, (view.page + 1) * pageSize));
  }
  function usesLiveGuide() { return cap('guide') && view.guideVisible; }
  function firstLiveChannel() { return usesLiveGuide() ? byId('guide-grid').querySelector('.guide-channel[data-nav]') : byId('channel-list').querySelector('button'); }
  function renderCategories() {
    var parent = byId('category-list'); clear(parent);
    function add(id, title) {
      var node = button(title, 'button category-button' + (id === view.category ? ' is-active' : ''), function () {
        if (id === view.category && view.page === 0 && !searchTimer) { focus(firstLiveChannel() || byId('channel-search')); return; }
        window.clearTimeout(searchTimer); searchTimer = null;
        view.category = id; view.page = 0; renderCategories(); renderChannels(); focus(firstLiveChannel() || byId('channel-search'));
        if (!usesLiveGuide()) loadNowNext(view.filtered.slice(0, pageSize));
      }); node.setAttribute('aria-pressed', id === view.category ? 'true' : 'false'); node.setAttribute('data-category-id', JSON.stringify(id)); parent.appendChild(node);
    }
    add(null, t("All channels")); view.categories.forEach(function (category) { add(category.id, category.title || category.name); });
  }
  function renderChannels(retainGuidePosition) {
    window.clearTimeout(channelNowNextTimer); channelNowNextTimer = null;
    var term = byId('channel-search').value.toLowerCase(), parent = byId('channel-list');
    var filter = JSON.stringify([view.source && view.source.id, view.category, term]);
    if (filter !== view.guideFilter || view.filteredCatalog !== view.channels) {
      var selectedCategory = view.categories.filter(function (category) { return category.id === view.category; })[0], members = null;
      if (selectedCategory && Array.isArray(selectedCategory.channelIds)) { members = Object.create(null); selectedCategory.channelIds.forEach(function (id) { members[id] = true; }); }
      view.filtered = view.category === null && !term ? view.channels : view.channels.filter(function (channel) {
        return (view.category === null || (members ? members[channel.id] === true : channel.categoryId === view.category)) && (!term || String(channel.name).toLowerCase().indexOf(term) >= 0 || String(channel.number || '').indexOf(term) >= 0);
      });
      view.filteredCatalog = view.channels; view.guideFilter = filter;
      if (!retainGuidePosition) { view.guideStartIndex = 0; view.guideScrollRow = -1; byId('guide-grid').scrollTop = 0; }
      else {view.guideStartIndex = Math.min(view.guideStartIndex,Math.max(0,view.filtered.length - guideWindowSize));byId('guide-grid').scrollTop = Math.min(byId('guide-grid').scrollTop,Math.max(0,view.filtered.length - 1) * guideRowHeight);}
    }
    var pages = Math.max(1, Math.ceil(view.filtered.length / pageSize)); view.page = Math.max(0, Math.min(view.page, pages - 1));
    clear(parent); var start = view.page * pageSize, end = Math.min(start + pageSize, view.filtered.length);
    if (!usesLiveGuide()) for (var i = start; i < end; i++) appendChannel(view.filtered[i], i, parent);
    byId('channel-empty').hidden = !!view.filtered.length; byId('channel-list').hidden = !view.filtered.length;
    byId('previous-page').disabled = view.page === 0; byId('next-page').disabled = view.page + 1 >= pages;
    text(byId('page-label'), (view.page + 1) + ' / ' + pages); text(byId('channel-count'), t('{count} channels', { count: view.filtered.length })); text(byId('category-title'), t("All channels"));
    view.categories.forEach(function (category) { if (category.id === view.category) text(byId('category-title'), category.title || category.name); }); byId('clear-channel-search').hidden = !term; updateLockButtons();
    syncLiveGuide();
  }
  function activateChannel(channel) {
    if (cap('preview') && !(view.preview && view.channel && view.channel.id === channel.id && (!previewStart || previewStart.pending || previewStart.ready))) previewChannel(channel);
    else playContent({ channel: channel, sourceId: view.source.id });
  }
  function appendChannel(channel, index, parent) {
    var node = button('', 'button channel-row' + (view.channel && view.channel.id === channel.id && view.preview ? ' is-playing' : ''), function () { activateChannel(channel); }); node.id = 'channel-row-' + index; node.setAttribute('data-channel-id', channel.id); node.appendChild(element('span', 'channel-number', channel.number || index + 1));
    if (channel.logo) image(channel.logo, 'channel-logo', node);
    var copy = element('span', 'channel-copy'); copy.appendChild(element('span', 'channel-name', channel.name));
    var programme = view.nowNext[channel.id] && view.nowNext[channel.id].now;
    if (programme) copy.appendChild(element('span', 'channel-programme', programme.title)); node.appendChild(copy); parent.appendChild(node);
  }
  function refreshChannelRows() {
    var rows = byId('channel-list').querySelectorAll('[data-channel-id]');
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i], id = row.getAttribute('data-channel-id'), copy = row.querySelector('.channel-copy'), programme = view.nowNext[id] && view.nowNext[id].now;
      row.classList.toggle('is-playing', !!(view.preview && view.channel && String(view.channel.id) === id));
      var label = row.querySelector('.channel-programme');
      if (programme) { if (!label) { label = element('span', 'channel-programme'); copy.appendChild(label); } text(label, programme.title); }
      else if (label) copy.removeChild(label);
    }
    var guideRows = byId('guide-grid').querySelectorAll('.guide-channel[data-channel-id]');
    for (var j = 0; j < guideRows.length; j++) guideRows[j].classList.toggle('is-playing', !!(view.preview && view.channel && String(view.channel.id) === guideRows[j].getAttribute('data-channel-id')));
  }
  function page(delta) { window.clearTimeout(searchTimer); searchTimer = null; view.page += delta; renderChannels(); focus(byId('channel-list').querySelector('button')); loadNowNext(view.filtered.slice(view.page * pageSize, (view.page + 1) * pageSize)); }
  function loadNowNext(channels) {
    channels = visibleNowNextChannels(channels);
    var loadedAt = view.nowNextAt || (view.nowNextAt = Object.create(null)), now = Date.now();
    channels = channels.filter(function (channel) { return !loadedAt[channel.id] || now - loadedAt[channel.id] >= 60000; });
    if (!cap('guide') || !channels.length) { ++view.nowNextRequest; return; }
    var request = view.request, source = view.source, pageIndex = view.page, category = view.category, search = byId('channel-search').value;
    var key = JSON.stringify([request, source && source.id, pageIndex, category, search, channels.map(function (channel) { return channel.id; })]);
    if (nowNextStart && nowNextStart.key === key && nowNextStart.ticket === view.nowNextRequest) return nowNextStart.promise;
    var ticket = ++view.nowNextRequest, start = { key: key, ticket: ticket }; nowNextStart = start;
    function current() { return ticket === view.nowNextRequest && request === view.request && source === view.source && pageIndex === view.page && category === view.category && search === byId('channel-search').value && view.screen === 'catalog'; }
    start.promise = query('guide', { channels: channels, from: new Date().toISOString(), to: new Date(Date.now() + 4 * 3600000).toISOString() }).then(function (data) {
      if (!current()) return;
      view.nowNext = Object.assign({}, view.nowNext);
      channels.forEach(function (channel) { delete view.nowNext[channel.id]; });
      Object.assign(view.nowNext, data.nowNext || {});
      channels.forEach(function (channel) { loadedAt[channel.id] = Date.now(); });
      refreshChannelRows(); renderNowNext();
    }).catch(function () { if (current() && view.statusStage === 'guide-download') status(''); }).then(function () { if (nowNextStart === start) nowNextStart = null; });
    return start.promise;
  }
  function visibleNowNextChannels(channels) {
    var list = byId('channel-list'), bounds = list.getBoundingClientRect(), rows = list.querySelectorAll('[data-channel-id]');
    var visibleIds = Object.create(null), count = 0;
    for (var i = 0; i < rows.length && count < 12; i++) {
      var rect = rows[i].getBoundingClientRect();
      if (rect.bottom > bounds.top && rect.top < bounds.bottom) { visibleIds[rows[i].getAttribute('data-channel-id')] = true; count++; }
    }
    return (count ? channels.filter(function (channel) { return visibleIds[channel.id]; }) : channels).slice(0, 12);
  }
  function onChannelListScroll() {
    if (view.screen !== 'catalog' || usesLiveGuide() || view.player) return;
    window.clearTimeout(channelNowNextTimer);
    var request = view.request, pageIndex = view.page;
    channelNowNextTimer = window.setTimeout(function () {
      channelNowNextTimer = null;
      if (request === view.request && pageIndex === view.page && view.screen === 'catalog' && !usesLiveGuide() && !view.player) loadNowNext(view.filtered.slice(pageIndex * pageSize, (pageIndex + 1) * pageSize));
    }, 180);
  }
  function renderNowNext() {
    [byId('preview-now-next'), byId('player-now-next')].forEach(function (node) {
      clear(node); var line = view.channel && view.nowNext[view.channel.id]; if (!line) return;
      ['now', 'next'].forEach(function (key) { if (line[key]) { var row = element('p', 'now-next'); row.appendChild(element('span', 'muted', key === 'now' ? t("Now") : t("Next"))); row.appendChild(element('span', '', line[key].title)); node.appendChild(row); } });
    });
  }
  function previewRect() { var r = byId('preview-slot').getBoundingClientRect(); return { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) }; }
  function fullRect() { return { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight }; }
  function nativeRect(rect) {
    var node = byId('native-player'); node.style.left = rect.x + 'px'; node.style.top = rect.y + 'px'; node.style.width = rect.width + 'px'; node.style.height = rect.height + 'px';
    if (window.TVBroSamsungViewport) window.TVBroSamsungViewport.setPreviewRect(rect);
  }
  function cancelPreviewIdleTimer() { window.clearTimeout(previewIdleTimer); previewIdleTimer = null; }
  function idlePreviewChannel() {
    var state = view.playingState || {};
    return view.screen === 'catalog' && view.preview && !view.player && !view.busy &&
      !document.hidden && !dialogs.length && byId('channel-search').readOnly && !byId('channel-search').value &&
      previewStart && previewStart.ready && !previewStart.pending &&
      state.playing && !state.buffering && !state.error ? view.channel : null;
  }
  function syncPreviewIdleTimer() {
    var channel = idlePreviewChannel();
    if (!channel) { cancelPreviewIdleTimer(); return; }
    // Playback notifications must not postpone an otherwise idle viewer.
    if (previewIdleTimer !== null) return;
    var request = view.playbackRequest, sourceId = view.sourceId;
    previewIdleTimer = window.setTimeout(function () {
      previewIdleTimer = null;
      var current = idlePreviewChannel();
      if (current && current.id === channel.id && sourceId === view.sourceId && request === view.playbackRequest) {
        playContent({ channel: current, sourceId: sourceId });
      }
    }, 30000);
  }
  function resetPreviewIdleTimer(event) {
    cancelPreviewIdleTimer(); syncPreviewIdleTimer();
    if (event && event.type === 'focusin' && view.player) updatePlayerHint(view.playingState);
  }
  function previewChannel(channel) {
    cancelPreviewIdleTimer();
    var request = ++view.playbackRequest; view.channel = channel; view.item = null; view.sourceId = view.source.id; view.preview = true; view.player = false; updateLockButtons();
    var start = { request: request, sourceId: view.sourceId, channelId: channel.id, pending: true, ready: false }; previewStart = start;
    document.body.classList.add('preview-open'); nativeRect(previewRect()); text(byId('preview-title'), channel.name); text(byId('preview-status'), t("Loading stream…"));
    byId('preview-placeholder').hidden = true; text(byId('preview-hint'), t('OK · Fullscreen')); renderNowNext();
    refreshChannelRows();
    start.promise = query('playback.preview', { channel: channel, sourceId: view.sourceId, rect: previewRect() }).then(function () {
      if (request !== view.playbackRequest) return; start.ready = true; rememberReadyPlayer(channel, view.sourceId); updatePlayer(platform.getState()); refreshChannelRows();
    }).catch(function (error) { if (request === view.playbackRequest) { text(byId('preview-status'), message(error, t("Could not start the preview."))); report(error); } }).then(function () { start.pending = false; syncPreviewIdleTimer(); });
    return start.promise;
  }
  function suspendPreview() {
    cancelPreviewIdleTimer();
    ++view.playbackRequest; previewStart = null; query('playback.stop').catch(report); view.preview = false; document.body.classList.remove('preview-open'); refreshChannelRows();
    byId('preview-placeholder').hidden = false; text(byId('preview-hint'), t('OK · Preview'));
  }
  function clearPlaybackPresentation() {
    cancelSeekIntent();
    cancelPlayerZap();
    cancelPreviewIdleTimer();
    ++view.playbackRequest; previewStart = null; playerContent = null; view.player = false; view.playerReady = false; view.preview = false; view.channel = null; view.item = null;
    window.clearTimeout(hideTimer); hideTimer = null; document.body.classList.remove('player-open'); document.body.classList.remove('preview-open');
    byId('player-view').hidden = true; byId('preview-placeholder').hidden = false; text(byId('preview-hint'), t('OK · Preview'));
  }
  function showChrome(value) {
    if (!value && scrub) return;
    var previous = view.chrome; view.chrome = value; byId('player-chrome').hidden = !value; window.clearTimeout(hideTimer); hideTimer = null;
    if (value && !previous) focus(byId('play-pause'));
    if (value && view.playerReady && view.playingState.playing && !view.playingState.buffering && !dialogs.length) hideTimer = window.setTimeout(function () { hideTimer = null; if (!scrub) showChrome(false); }, 5000);
  }
  function playContent(args) {
    cancelSeekIntent();
    cancelPlayerZap();
    cancelPreviewIdleTimer();
    var sourceId = args.sourceId || view.source && view.source.id;
    if (!args.programme && args.channel && view.preview && previewStart && previewStart.pending && previewStart.sourceId === sourceId && previewStart.channelId === args.channel.id && previewStart.request === view.playbackRequest) {
      var preview = previewStart;
      if (!preview.fullscreen) preview.fullscreen = preview.promise.then(function () {
        if (preview.ready && preview.request === view.playbackRequest && view.preview && view.screen === 'catalog' && view.channel && view.channel.id === preview.channelId) return playContent(args);
      });
      return preview.fullscreen;
    }
    var content = args.item || args.channel, key = JSON.stringify([sourceId, content.kind || 'live', content.id, args.programme && args.programme.start, args.programme && args.programme.stop, args.resumeMode]);
    if (playerStart && playerStart.key === key && playerStart.request === view.playbackRequest) return playerStart.promise;
    var request = ++view.playbackRequest; if (!view.player) returnFocus = document.activeElement;
    episodeNavigation = null; completedEpisodeRequest = null;
    view.episodes = null;
    var start = { key: key, request: request }; playerStart = start;
    playerContent = { args: Object.assign({}, args, { sourceId: sourceId }), profileId: view.profile && view.profile.id, request: request };
    view.channel = args.channel || null; view.item = args.item || null; view.sourceId = sourceId;
    renderEpisodeControls();
    if (args.item && args.item.kind === 'episode') {
      query('media.episodes', {item:args.item}).then(function (navigation) {
        if (request !== view.playbackRequest || !view.player || view.sourceId !== sourceId) return;
        episodeNavigation = navigation;
        if (navigation.parent) view.episodes = {parent:navigation.parent,sourceId:sourceId};
        renderEpisodeControls();
        if (view.playingState && view.playingState.completed) advanceCompletedEpisode(view.playingState);
      }).catch(function () { if (request === view.playbackRequest) renderEpisodeControls(); });
    }
    view.player = true; view.playerReady = false; view.playerOrigin = view.screen; byId('player-view').hidden = false; byId('player-view').setAttribute('aria-busy', 'true');
    nativeRect(fullRect()); document.body.classList.add('player-open'); document.body.classList.remove('preview-open');
    text(byId('player-title'), args.channel ? args.channel.name : args.item.title); text(byId('player-status'), t("Loading stream…"));
    byId('player-favorite').hidden = !cap('favorites'); byId('player-settings').hidden = !(cap('tracks') || cap('rate') || cap('aspect'));
    byId('player-episodes').hidden = !view.episodes || !args.item || args.item.kind !== 'episode'; renderNowNext(); showChrome(!args.keepChromeHidden); if (!args.keepChromeHidden) focus(byId('play-pause'));
    start.promise = query('playback.play', Object.assign({}, args, { sourceId: view.sourceId, rect: fullRect() })).then(function () {
      if (request !== view.playbackRequest) return;
      return afterLoadingPaint();
    }).then(function () {
      if (request !== view.playbackRequest) return;
      nativeRect(fullRect()); document.body.classList.add('player-open'); document.body.classList.remove('preview-open');
      return query('player.rect', { rect: fullRect() }).then(function () {
        if (request !== view.playbackRequest) return;
        nativeRect(fullRect()); document.body.classList.add('player-open'); document.body.classList.remove('preview-open');
        if (args.channel && !args.programme) rememberReadyPlayer(args.channel, sourceId);
        view.playerReady = true; byId('player-view').setAttribute('aria-busy', 'false'); updatePlayer(platform.getState());
      });
    }).catch(function (error) { if (request === view.playbackRequest) { byId('player-view').setAttribute('aria-busy', 'false'); text(byId('player-status'), message(error, t("Could not start playback."))); showChrome(true); } }).then(function () { if (playerStart === start) playerStart = null; });
    return start.promise;
  }
  function returnFromPlayer() {
    stopSeekHold();
    cancelPlayerZap();
    if (!view.playerReady) return stopPlayback(true);
    if (view.preview && view.channel && view.playerOrigin === 'catalog') {
      ++view.playbackRequest; view.player = false; view.playerReady = false; window.clearTimeout(hideTimer); document.body.classList.remove('player-open'); document.body.classList.add('preview-open');
      byId('player-view').hidden = true; nativeRect(previewRect()); query('player.rect', { rect: previewRect() }).catch(report); focus(visible(returnFocus) ? returnFocus : firstLiveChannel()); resetPreviewIdleTimer();
    } else stopPlayback(true);
  }
  function stopPlayback(restore) {
    cancelSeekIntent();
    cancelPlayerZap();
    cancelPreviewIdleTimer();
    var request = ++view.playbackRequest;
    return query('playback.stop').then(function () { if (request === view.playbackRequest) { clearPlaybackPresentation(); if (!restoreDetails() && restore) focus(returnFocus || byId('channel-search')); } }).catch(function (error) {
      if (request === view.playbackRequest) { text(byId('player-status'), message(error, t("Could not stop playback."))); report(error); }
    });
  }
  function control(action) { Promise.resolve().then(action).then(function () { updatePlayer(platform.getState()); }, function (error) { text(byId('player-status'), message(error, t("Could not perform this action."))); showChrome(true); }); }
  function playPause() {
    var state = platform.getState();
    // Backgrounding closes AVPlay while keeping the fullscreen selection.
    // Explicit Play must resolve it again through the normal source checks.
    if (view.player && state.nativeState === 'NONE' && playerContent && playerContent.request === view.playbackRequest &&
        playerContent.profileId === (view.profile && view.profile.id) && playerContent.args.sourceId === view.sourceId) {
      return playContent(playerContent.args);
    }
    return platform.playPause();
  }
  function cancelSeekIntent() {
    stopSeekHold();
    window.clearTimeout(seekTimer); seekTimer = null; seekIntent = null; scrub = null;
  }
  function seekDuration(state) {
    var duration = Number(state && state.duration);
    return !state || state.isLive || !isFinite(duration) || duration <= 0 ? 0 : duration;
  }
  function setScrubTarget(target) {
    var state = platform.getState(), duration = seekDuration(state), position = Number(target);
    if (!view.player || !duration || !isFinite(position)) return false;
    scrub = {request:view.playbackRequest,target:Math.max(0,Math.min(duration,position))};
    showChrome(true); updatePlayerTimeline(state); return true;
  }
  function adjustScrub(delta) {
    var state = platform.getState(), duration = seekDuration(state);
    if (!view.player || !duration) return false;
    var position = scrub && scrub.request === view.playbackRequest ? scrub.target : Number(state.position);
    if (!isFinite(position)) position = 0;
    return setScrubTarget(position + delta);
  }
  function cancelScrub() {
    scrub = null;
    if (view.player) updatePlayerTimeline(platform.getState());
  }
  function commitScrub() {
    if (!scrub) return false;
    var pending = scrub, state = platform.getState(), duration = seekDuration(state);
    scrub = null;
    if (pending.request !== view.playbackRequest || !view.player || !duration) {
      updatePlayerTimeline(state); return false;
    }
    seekIntent = {request:view.playbackRequest,target:Math.max(0,Math.min(duration,pending.target))};
    window.clearTimeout(seekTimer); seekTimer = null;
    updatePlayerTimeline(state); flushSeekIntent(); return true;
  }
  function seekBarClick(event) {
    var track = byId('player-progress-track'), bounds = track.getBoundingClientRect(), duration = seekDuration(platform.getState());
    if (!view.player || !duration || !(bounds.width > 0) || !isFinite(Number(event.clientX))) return;
    if (event.detail === 0 && !Number(event.clientX) && !Number(event.clientY)) return;
    if (event.preventDefault) event.preventDefault();
    focus(track);
    setScrubTarget((Number(event.clientX) - bounds.left) * duration / bounds.width);
    commitScrub();
  }
  function stopSeekHold() {
    if (seekHold) window.clearTimeout(seekHold.timer);
    seekHold = null;
  }
  function startSeekHold(key, delta) {
    if (seekHold && seekHold.key === key) return;
    stopSeekHold();
    var state = platform.getState();
    if (!seekDuration(state)) { seek(delta); return; }
    var hold = {key:key, request:view.playbackRequest, timer:null}; seekHold = hold;
    function step() {
      if (seekHold !== hold) return;
      if (!view.player || dialogs.length || hold.request !== view.playbackRequest) { stopSeekHold(); return; }
      seek(delta);
      hold.timer = window.setTimeout(step, 300);
    }
    seek(delta);
    hold.timer = window.setTimeout(step, 400);
  }
  function onKeyUp(event) {
    var key = event.keyCode || event.which;
    if (window.TVBroPlatformAdapters && typeof window.TVBroPlatformAdapters.normalizeKey === 'function') key = window.TVBroPlatformAdapters.normalizeKey(key);
    if (seekHold && seekHold.key === key) stopSeekHold();
  }
  function flushSeekIntent() {
    seekTimer = null;
    if (seekFlight || !seekIntent) return;
    var intent = seekIntent, target = intent.target;
    if (intent.request !== view.playbackRequest || !view.player) { cancelSeekIntent(); return; }
    seekFlight = platform.seek(target);
    seekFlight.then(function () {
      if (seekIntent !== intent || intent.request !== view.playbackRequest) return;
      if (intent.target === target) seekIntent = null;
      updatePlayer(platform.getState());
    }, function (error) {
      if (seekIntent !== intent || intent.request !== view.playbackRequest) return;
      stopSeekHold();
      seekIntent = null; text(byId('player-status'), message(error, t('Could not perform this action.'))); showChrome(true);
    }).then(function () {
      seekFlight = null;
      if (seekIntent && seekIntent.request === view.playbackRequest) flushSeekIntent();
    });
  }
  function seek(delta) {
    var state = platform.getState(), duration = seekDuration(state); if (!duration) { showChrome(true); return; }
    if (view.chrome) showChrome(true);
    if (!seekIntent || seekIntent.request !== view.playbackRequest) seekIntent = {request:view.playbackRequest,target:Number(state.position) || 0};
    seekIntent.target = Math.max(0, Math.min(duration, seekIntent.target + delta));
    window.clearTimeout(seekTimer);
    seekTimer = window.setTimeout(flushSeekIntent, 120);
  }
  function playerChannels() {
    return view.channel && view.playingState.isLive && view.source && view.source.id === view.sourceId ? view.channels : [];
  }
  function rememberReadyPlayer(channel, sourceId) {
    var profileId = view.profile && view.profile.id;
    if (readyPlayer && readyPlayer.sourceId === sourceId && readyPlayer.profileId === profileId) {
      if (String(readyPlayer.channel.id) !== String(channel.id)) previousPlayer = readyPlayer;
    } else previousPlayer = null;
    readyPlayer = { channel: channel, sourceId: sourceId, profileId: profileId };
  }
  function channelIndex(channels, channel) {
    for (var i = 0; i < channels.length; i++) if (channel && String(channels[i].id) === String(channel.id)) return i;
    return -1;
  }
  function showPlayerZap(label) {
    window.clearTimeout(playerZapFeedbackTimer); playerZapFeedbackTimer = null;
    text(byId('player-zap-status'), label); byId('player-zap-status').hidden = !label;
  }
  function cancelPlayerZap() {
    window.clearTimeout(playerZapTimer); playerZapTimer = null;
    playerZapPending = null; playerZapDigits = ''; showPlayerZap('');
  }
  function commitZap() {
    var channels = playerChannels(), channel = playerZapPending, digits = playerZapDigits;
    if (digits) channel = channels[Number(digits) - 1];
    var keepChromeHidden = !view.chrome, sourceId = view.sourceId;
    cancelPlayerZap();
    if (channel && channelIndex(channels, channel) >= 0) playContent({ channel: channel, sourceId: sourceId, keepChromeHidden: keepChromeHidden });
    else if (digits) {
      showPlayerZap(t('No channel {number}', { number: digits }));
      playerZapFeedbackTimer = window.setTimeout(function () { showPlayerZap(''); }, 1500);
    }
  }
  function zap(delta) {
    var all = playerChannels(); if (!all.length) return;
    var current = playerZapPending || view.channel, channels = view.filtered.length ? view.filtered : all;
    var index = channelIndex(channels, current);
    if (index < 0) { channels = all; index = channelIndex(channels, current); }
    if (index < 0 || channels.length < 2) return;
    playerZapDigits = ''; playerZapPending = channels[(index + delta + channels.length) % channels.length];
    showPlayerZap((channelIndex(all, playerZapPending) + 1) + ' · ' + playerZapPending.name);
    window.clearTimeout(playerZapTimer); playerZapTimer = window.setTimeout(commitZap, 600);
  }
  function zapDigit(digit) {
    var channels = playerChannels(); if (!channels.length) return;
    if (playerZapDigits.length >= String(channels.length).length) playerZapDigits = '';
    playerZapDigits += String(digit); playerZapPending = null;
    var channel = channels[Number(playerZapDigits) - 1];
    showPlayerZap(playerZapDigits + (channel ? ' · ' + channel.name : ''));
    window.clearTimeout(playerZapTimer); playerZapTimer = window.setTimeout(commitZap, 1200);
  }
  function previousPlayerChannel() {
    var channels = playerChannels(), previous = previousPlayer;
    cancelPlayerZap();
    if (!previous || previous.sourceId !== view.sourceId || previous.profileId !== (view.profile && view.profile.id) || channelIndex(channels, previous.channel) < 0) return;
    playContent({ channel: previous.channel, sourceId: view.sourceId, keepChromeHidden: !view.chrome });
  }
  function openPlayerChannels() {
    var all = playerChannels(); if (!all.length) return;
    cancelPlayerZap();
    var channels = view.filtered.length && channelIndex(view.filtered, view.channel) >= 0 ? view.filtered : all;
    var selected = Math.max(0, channelIndex(channels, view.channel)), first = Math.max(0, selected - 10);
    var record = dialog(t('Channel list')), list = element('div', 'dialog-list'); record.playerChannels = true; record.body.appendChild(list);
    function render() {
      clear(list); clear(record.actions);
      var end = Math.min(channels.length, first + 21), current = null;
      for (var i = first; i < end; i++) (function (index) {
        var channel = channels[index], row = button((channelIndex(all, channel) + 1) + ' · ' + channel.name, 'button' + (String(channel.id) === String(view.channel.id) ? ' selected-option' : ''), function () {
          closeDialog(false, record); playContent({ channel: channel, sourceId: view.sourceId, keepChromeHidden: true });
        });
        row.id = 'player-channel-' + index; list.appendChild(row); if (index === selected) current = row;
      }(i));
      if (first > 0) dialogButton(record, t('Previous channels'), function () { first = Math.max(0, first - 21); render(); });
      if (end < channels.length) dialogButton(record, t('Next channels'), function () { first = end; render(); });
      dialogButton(record, t('Back'), function () { closeDialog(true); }); focus(current || list.firstChild);
    }
    render();
  }
  function updatePlayerTimeline(state) {
    state = state || {};
    text(byId('player-clock'), clock(Date.now()));
    var duration = seekDuration(state), position = Number(state.position);
    if (!isFinite(position)) position = 0;
    position = Math.max(0, Math.min(duration, position));
    if (!duration || scrub && scrub.request !== view.playbackRequest) scrub = null;
    if (scrub && scrub.request === view.playbackRequest) position = Math.max(0, Math.min(duration, scrub.target));
    else if (seekIntent && seekIntent.request === view.playbackRequest) position = Math.max(0, Math.min(duration, seekIntent.target));
    var progress = byId('player-progress'), track = byId('player-progress-track'); progress.hidden = !duration;
    track.disabled = !duration; track.tabIndex = duration ? 0 : -1;
    track.setAttribute('aria-disabled', duration ? 'false' : 'true');
    track.setAttribute('aria-valuemin', '0'); track.setAttribute('aria-valuemax', String(duration));
    track.setAttribute('aria-valuenow', String(position)); track.setAttribute('aria-valuetext', duration ? time(position) + ' / ' + time(duration) : '');
    byId('player-progress-fill').style.width = (duration ? position * 100 / duration : 0) + '%';
    text(byId('player-time'), duration ? time(position) + ' / ' + time(duration) : '');
    byId('player-channels').hidden = !state.isLive || !playerChannels().length;
    byId('player-previous').hidden = !state.isLive || !playerChannels().length;
    byId('player-previous').disabled = !previousPlayer || previousPlayer.sourceId !== view.sourceId || previousPlayer.profileId !== (view.profile && view.profile.id) || channelIndex(playerChannels(), previousPlayer.channel) < 0;
    byId('player-audio').hidden = !cap('tracks'); byId('player-subtitles').hidden = !cap('tracks');
  }
  function updatePlayerHint(state) {
    var onSlider = scrub || document.activeElement === byId('player-progress-track');
    text(byId('player-hint'), state.isLive ? t('OK — controls · ↑ / ↓ — channel · ← — channels · → — previous · 0–9 — channel number') :
      onSlider ? t('← / → — adjust · OK — seek · Back — cancel') : t('OK — controls · Back — hide controls · Hold seek — keep seeking'));
  }
  function time(seconds) { var n = Math.max(0, Math.floor(Number(seconds) || 0)), m = Math.floor(n / 60); return m + ':' + (n % 60 < 10 ? '0' : '') + (n % 60); }
  function clock(value) { var d = new Date(value); return isNaN(d.getTime()) ? '' : ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2); }
  function updatePlayer(state) {
    if (state && typeof state.catalogRevision === 'number' && state.catalogRevision !== view.catalogRevision) {
      var changedCatalog = view.catalogRevision != null; view.catalogRevision = state.catalogRevision;
      if (changedCatalog) refreshLibraryPresentation(true);
    }
    if (state && typeof state.guideRevision === 'number' && state.guideRevision !== view.guideRevision) {
      view.guideRevision = state.guideRevision;
      if (state.guideRevision > 0 && view.screen === 'catalog') {
        view.nowNextAt = Object.create(null);
        if (usesLiveGuide()) fetchGuide(true);
        else loadNowNext(view.filtered.slice(view.page * pageSize, (view.page + 1) * pageSize));
      }
    }
    if (state && typeof state.libraryRevision === 'number' && state.libraryRevision !== view.libraryRevision) {
      var changedLibrary = view.libraryRevision != null; view.libraryRevision = state.libraryRevision;
      if (changedLibrary) refreshLibraryPresentation();
    }
    var stages = { 'profile-prepare': 'Preparing your profile…', 'profile-download': 'Downloading your profile…',
      'profile-save': 'Saving your profile…', 'source-connect': 'Connecting to source…',
      'source-channels': 'Loading channels and categories…', 'guide-download': 'Loading guide…',
      'catalog-read': 'Reading saved channel list…', 'catalog-save': 'Saving channel list…',
      'catalog-live': 'Preparing live TV…', 'catalog-movie': 'Preparing movies…',
      'catalog-series': 'Preparing series…', 'catalog-guide': 'Loading guide…', 'catalog-persist': 'Saving your library…' };
    if (state && (view.busy || view.pairingDownloading) && typeof state.loadingStage === 'string' && Object.prototype.hasOwnProperty.call(stages, state.loadingStage)) {
      var progress = t(stages[state.loadingStage]);
      if (view.screen === 'pairing' && view.pairingDownloading) { view.pairingStage = progress; text(byId('pairing-status'), progress); }
      status(progress, false, true);
      view.statusStage = state.loadingStage;
    } else if (state && state.loadingStage === null && view.statusStage === 'guide-download') {
      status('');
    }
    var warnings = state && state.catalogPreparation && state.catalogPreparation.warnings || [];
    var warningKey = warnings.length ? JSON.stringify(warnings) : '';
    if (!view.busy && !view.player && warningKey && view.catalogPreparationWarningKey !== warningKey) {
      view.catalogPreparationWarningKey = warningKey;
      status(t('Some sections could not be loaded: {sections}. Available sections remain usable.', {
        sections:warnings.map(function (warning) { return warning.label && t(warning.label); }).filter(Boolean).join(', ')}));
    } else if (!warningKey) view.catalogPreparationWarningKey = '';
    var previousState = view.playingState || {};
    state = state || {}; view.playingState = state; text(byId('play-pause'), state.playing ? t("Pause") : t("Play"));
    var duration = seekDuration(state);
    byId('seek-back').hidden = !!state.isLive; byId('seek-forward').hidden = !!state.isLive;
    byId('seek-back').disabled = !duration; byId('seek-forward').disabled = !duration; byId('player-live-badge').hidden = !state.isLive;
    updatePlayerHint(state);
    updatePlayerTimeline(state);
    var label = state.error ? message(state.error, t("Playback failed.")) : state.buffering ? t("Buffering…") : duration ? time(state.position) + ' / ' + time(duration) : state.playing ? t("Live") : t("Paused");
    if (view.playerReady) text(byId('player-status'), label); text(byId('preview-status'), label);
    // Loading and rebuffering must preserve the viewer's choice: hidden live
    // controls keep the arrows available for the next channel change.
    var needsControls = !state.playing && (state.error || view.playerReady && (state.nativeState === 'PAUSED' || !state.isLive && !state.buffering));
    var changedStatus = previousState.playing || previousState.buffering || previousState.nativeState !== state.nativeState ||
      !!previousState.error !== !!state.error || previousState.error && state.error && previousState.error.message !== state.error.message;
    if (view.player && needsControls && changedStatus) showChrome(true); else if (view.player && view.chrome && !hideTimer) showChrome(true);
    syncPreviewIdleTimer();
    advanceCompletedEpisode(state);
  }
  function refreshLibraryPresentation(catalogOnly) {
    if (!view.profile) return;
    var request = view.request, profileId = view.profile.id, sourceId = view.source && view.source.id;
    Promise.all([query('sources.catalog'),query('sources.list'),query('favorites.list')]).then(function (data) {
      if (request !== view.request || !view.profile || view.profile.id !== profileId || sourceId !== (view.source && view.source.id)) return;
      view.sources = array(data[1]); view.favorites = array(data[2]);
      var catalog = data[0];
      if (catalog && catalog.source && catalog.source.id === sourceId) {
        if (JSON.stringify(view.source) !== JSON.stringify(catalog.source)) view.source = catalog.source;
        view.channels = array(catalog.channels); view.categories = array(catalog.categories);
        if (catalog.capabilities) view.caps = catalog.capabilities;
        if (view.category !== null && !view.categories.some(function (category) {return category.id === view.category;})) view.category = null;
        if (!view.player && view.screen === 'catalog') {
          var retained = document.activeElement, attribute = retained && retained.classList && retained.classList.contains('channel-row') ? 'data-channel-id' : 'data-category-id';
          var retainedId = retained && retained.getAttribute && retained.getAttribute(attribute);
          var list = byId('channel-list'), scroll = list.scrollTop;
          renderCategories(); renderChannels(true);
          if (retainedId && !dialogs.length && document.activeElement !== retained) {
            var rows = document.querySelectorAll('[' + attribute + ']');
            for (var i = 0; i < rows.length; i++) if (rows[i].getAttribute(attribute) === retainedId && visible(rows[i])) { focus(rows[i]); break; }
          }
          list.scrollTop = scroll;
        }
        text(byId('home-source'),sourceName(view.source));
      }
      if (!catalogOnly && !view.player && !dialogs.length && view.screen === 'media') {
        if (view.mediaKind === 'favorites') renderFavoriteItems();
        else {
          var kind = view.mediaKind;
          query('catalog.categories',{kind:kind}).then(function (categories) {
            if (request !== view.request || view.screen !== 'media' || view.mediaKind !== kind || view.player || dialogs.length) return;
            view.mediaCategories = array(categories);
            if (view.mediaCategory !== null && !view.mediaCategories.some(function (category) {return category.id === view.mediaCategory;})) view.mediaCategory = null;
            renderMediaCategories(); if (kind === 'series') {seriesList = null;view.mediaPage = 1;view.mediaSlice = 0;} fetchMedia();
          }).catch(report);
        }
      }
      if (view.screen === 'sources') renderSources();
      dialogs.forEach(function (record) { if (record.mediaDetails) updateSeriesProgress(record); });
    }).catch(report);
  }
  function renderEpisodeControls() {
    var enabled = view.item && view.item.kind === 'episode';
    byId('previous-episode').hidden = byId('next-episode').hidden = !enabled;
    byId('previous-episode').disabled = !episodeNavigation || !episodeNavigation.previous;
    byId('next-episode').disabled = !episodeNavigation || !episodeNavigation.next;
    byId('player-episodes').hidden = !enabled || !view.episodes;
  }
  function changeEpisode(delta) {
    var item = episodeNavigation && (delta < 0 ? episodeNavigation.previous : episodeNavigation.next);
    if (!item || !view.player) return;
    playContent({item:item,sourceId:view.sourceId,resumeMode:'beginning'});
  }
  function advanceCompletedEpisode(state) {
    if (!view.player || !view.playerReady || !state.completed || state.error || !view.item || view.item.kind !== 'episode' ||
        !state.currentItem || state.currentItem.id !== view.item.id || !episodeNavigation || completedEpisodeRequest === view.playbackRequest) return;
    completedEpisodeRequest = view.playbackRequest;
    if (episodeNavigation.next) changeEpisode(1);
  }
  function contentArgs(entry) {
    if (entry.channel || entry.item) return { channel: entry.channel || undefined, item: entry.item || undefined, sourceId: entry.sourceId };
    return entry.kind && entry.kind !== 'live' ? { item: entry, sourceId: entry.sourceId || view.source && view.source.id } : { channel: entry, sourceId: entry.sourceId || view.source && view.source.id };
  }
  function renderHistory(parent, entries) { clear(parent); entries.slice(0, 12).forEach(function (entry) { parent.appendChild(mediaCard(entry)); }); }
  function mediaCard(entry) {
    var args = contentArgs(entry), item = args.item || args.channel, node = button('', 'media-card', function () { openEntry(entry); });
    if (item.poster || item.logo) image(item.poster || item.logo, 'media-poster', node); else node.appendChild(element('span', 'poster-placeholder', args.channel ? 'TV' : '▶'));
    node.appendChild(element('span', 'media-card-title', item.title || item.name));
    if (item.year || item.rating) node.appendChild(element('span', 'media-card-meta', [item.year, item.rating].filter(function (value) { return value != null && value !== ''; }).join(' · ')));
    return node;
  }
  function showMedia(kind) {
    if (!view.source && kind !== 'favorites' || view.screen === 'media' && view.mediaKind === kind) return;
    window.clearTimeout(mediaSearchTimer); mediaSearchTimer = null;
    var request = ++view.mediaRequest, sourceRequest = view.request;
    function current() { return request === view.mediaRequest && sourceRequest === view.request && view.mediaKind === kind && view.screen === 'media'; }
    view.mediaKind = kind; view.mediaCategory = null; view.mediaPage = 1; view.mediaSlice = 0; byId('media-search').value = '';
    byId('media-view').setAttribute('data-kind', kind);
    byId('media-view').querySelector('.category-panel').hidden = kind === 'favorites';
    text(byId('media-title'), kind === 'movie' ? t("Movies") : kind === 'series' ? t("Series") : t("Favorites")); text(byId('media-kind-label'), kind === 'favorites' ? t("Your library") : t("On demand"));
    showScreen('media'); clear(byId('media-items')); clear(byId('media-categories')); byId('media-history').hidden = true;
    byId('media-pagination').hidden = kind === 'series'; byId('media-loading').hidden = true; byId('media-retry').hidden = true; seriesList = null;
    byId('media-previous').disabled = true; byId('media-next').disabled = true;
    if (kind === 'favorites') query('favorites.list').then(function (data) { if (current()) { view.favorites = array(data); renderFavoriteItems(); } }).catch(function (error) { if (current()) report(error); });
    else {
      query('catalog.categories', { kind: kind }).then(function (data) {
        if (!current()) return;
        view.mediaCategories = array(data); renderMediaCategories(); fetchMedia();
      }).catch(function (error) { if (current()) report(error); });
    }
  }
  function renderMediaCategories() {
    var parent = byId('media-categories'); clear(parent);
    function add(id, title) { parent.appendChild(button(title, 'button category-button' + (id === view.mediaCategory ? ' is-active' : ''), function () {
      if (id === view.mediaCategory && (view.mediaKind === 'series' || view.mediaPage === 1 && view.mediaSlice === 0) && !mediaSearchTimer) { focus(byId('media-items').querySelector('button') || byId('media-search')); return; }
      view.mediaCategory = id; view.mediaPage = 1; view.mediaSlice = 0; renderMediaCategories(); fetchMedia();
    })); }
    add(null, t("All")); view.mediaCategories.forEach(function (row) { add(row.id, row.title); }); updateLockButtons();
  }
  function fetchMedia() {
    window.clearTimeout(mediaSearchTimer); mediaSearchTimer = null;
    var args = { kind: view.mediaKind, categoryId: view.mediaCategory, page: view.mediaPage, query: byId('media-search').value }, source = view.source;
    var key = JSON.stringify([view.request, source && source.id, args]);
    if (mediaStart && mediaStart.key === key && mediaStart.request === view.mediaRequest) return mediaStart.promise;
    var request = ++view.mediaRequest, start = { key: key, request: request }; mediaStart = start;
    function current() { return request === view.mediaRequest && source === view.source && view.screen === 'media' && args.kind === view.mediaKind && args.categoryId === view.mediaCategory && args.page === view.mediaPage && args.query === byId('media-search').value; }
    if (args.kind === 'series') {
      seriesList = {request:request,source:source,categoryId:args.categoryId,query:args.query,shown:0,keys:Object.create(null),ready:false,loading:true,failed:false,paused:false};
      view.mediaItems = []; view.mediaHasMore = false; clear(byId('media-items')); byId('media-view').querySelector('.media-panel').scrollTop = 0;
      byId('media-loading').hidden = false; byId('media-retry').hidden = true; byId('media-empty').hidden = true;
    }
    status(t("Loading…"), false, true);
    start.promise = query('catalog.items', args).then(function (data) {
      if (!current()) return;
      view.mediaItems = array(data); view.mediaPage = data.page || view.mediaPage; view.mediaHasMore = !!data.hasMore;
      if (args.kind === 'series') { seriesList.loading = false; seriesList.ready = true; }
      if (view.mediaSlice < 0) view.mediaSlice = Math.max(0, Math.ceil(view.mediaItems.length / pageSize) - 1);
      renderMediaBuffer(); status(''); if (!(document.activeElement === byId('media-search') && !byId('media-search').readOnly)) focus(byId('media-items').querySelector('button') || byId('media-search'));
    }).catch(function (error) { if (current()) { if (args.kind === 'series') { seriesList.loading = false; seriesList.failed = true; renderSeriesLoading(); } report(error); } }).then(function () { if (mediaStart === start) mediaStart = null; });
    return start.promise;
  }
  function renderMediaItems(items) {
    var parent = byId('media-items'); clear(parent); items.forEach(function (entry) { parent.appendChild(mediaCard(entry)); });
    byId('media-empty').hidden = !!items.length; byId('clear-media-search').hidden = !byId('media-search').value;
  }
  function renderMediaBuffer() {
    if (view.mediaKind === 'series') { appendSeriesItems(); scheduleSeriesScroll(); return; }
    var parts = Math.max(1, Math.ceil(view.mediaItems.length / pageSize)); view.mediaSlice = Math.max(0, Math.min(view.mediaSlice, parts - 1));
    renderMediaItems(view.mediaItems.slice(view.mediaSlice * pageSize, (view.mediaSlice + 1) * pageSize));
    byId('media-previous').disabled = view.mediaPage <= 1 && view.mediaSlice === 0;
    byId('media-next').disabled = !view.mediaHasMore && view.mediaSlice + 1 >= parts;
    text(byId('media-page'), t('Page {page}', { page: view.mediaPage }) + (parts > 1 ? ' · ' + (view.mediaSlice + 1) + ' / ' + parts : ''));
  }
  function seriesCurrent(list) {
    return list && list === seriesList && list.request === view.mediaRequest && list.source === view.source && view.screen === 'media' && view.mediaKind === 'series' && list.categoryId === view.mediaCategory && list.query === byId('media-search').value;
  }
  function renderSeriesLoading() {
    var list = seriesList; if (!seriesCurrent(list)) return;
    byId('media-loading').hidden = !list.loading; byId('media-retry').hidden = !list.failed && !list.paused;
    text(byId('media-retry'), t(list.failed ? 'Retry' : 'Load more'));
    byId('media-empty').hidden = !!(list.items && list.items.length) || list.loading || list.failed || view.mediaHasMore;
  }
  function appendSeriesItems() {
    var list = seriesList; if (!seriesCurrent(list)) return;
    var end = Math.min(view.mediaItems.length, list.shown + pageSize); if (!list.items) list.items = [];
    for (var i = list.shown; i < end; i++) {
      var item = view.mediaItems[i], key = JSON.stringify([item.kind,item.id]);
      if (!list.keys[key]) { list.items.push(item); list.keys[key] = true; }
    }
    list.shown = end; renderSeriesWindow(); renderSeriesLoading(); byId('clear-media-search').hidden = !byId('media-search').value;
  }
  function seriesNode(index) { return byId('media-items').querySelector('[data-series-index="' + index + '"]'); }
  function renderSeriesWindow(target) {
    var list = seriesList; if (!seriesCurrent(list) || !list.items || !list.items.length || dialogs.length || view.player) return;
    var parent = byId('media-items'), panel = byId('media-view').querySelector('.media-panel'), scroll = panel.scrollTop;
    var sample = parent.querySelector('.media-card');
    if (!sample) { sample = mediaCard(list.items[0]); sample.setAttribute('data-series-index', '0'); parent.appendChild(sample); }
    var layout = list.layout;
    if (!layout || layout.width !== parent.clientWidth) {
      var cardStyle = window.getComputedStyle(sample), gridStyle = window.getComputedStyle(parent);
      var poster = sample.querySelector('.media-poster, .poster-placeholder'), title = sample.querySelector('.media-card-title');
      var meta = sample.querySelector('.media-card-meta'), probe = !meta;
      if (probe) { meta = element('span', 'media-card-meta', '0'); sample.appendChild(meta); }
      var metaHeight = parseFloat(window.getComputedStyle(meta).height); if (probe) sample.removeChild(meta);
      var base = parseFloat(window.getComputedStyle(poster).height) + parseFloat(window.getComputedStyle(title).height) +
        parseFloat(cardStyle.paddingTop) + parseFloat(cardStyle.paddingBottom) + parseFloat(cardStyle.borderTopWidth) + parseFloat(cardStyle.borderBottomWidth);
      var columns = Math.max(1, Math.floor((parent.clientWidth - parseFloat(gridStyle.paddingLeft) - parseFloat(gridStyle.paddingRight) + .01) /
        (sample.offsetWidth + parseFloat(cardStyle.marginRight))));
      layout = list.layout = {width:parent.clientWidth,columns:columns,base:base,meta:metaHeight,margin:parseFloat(cardStyle.marginBottom),padding:parseFloat(gridStyle.paddingTop),offsets:[0],count:0};
    }
    var offsets = layout.offsets, rows = Math.ceil(list.items.length / layout.columns);
    // Only the last partial row and newly appended rows need new measurements.
    for (var row = Math.floor(layout.count / layout.columns); row < rows; row++) {
      var height = layout.base;
      for (var cell = row * layout.columns; cell < Math.min(list.items.length, (row + 1) * layout.columns); cell++) {
        var item = list.items[cell]; if (item.year || item.rating) { height += layout.meta; break; }
      }
      offsets[row + 1] = offsets[row] + Math.round(height * 64) / 64 + layout.margin;
    }
    layout.count = list.items.length;
    var panelRect = panel.getBoundingClientRect(), gridRect = parent.getBoundingClientRect();
    var viewport = byId('ui-viewport'), scale = Number(viewport && viewport.getAttribute('data-ui-scale')) || panelRect.height / panel.offsetHeight || 1;
    var local = Math.max(0, -(gridRect.top - panelRect.top) / scale - layout.padding);
    var first = 0, high = rows;
    while (first < high) { var middle = Math.floor((first + high) / 2); if (offsets[middle + 1] <= local) first = middle + 1; else high = middle; }
    if (typeof target === 'number') first = Math.floor(target / layout.columns);
    var windowRows = Math.ceil(panel.clientHeight / (layout.base + layout.margin)) + 4;
    var start = Math.max(0, Math.min(rows - windowRows, first - 2)), end = Math.min(rows, start + windowRows);
    var active = document.activeElement, pinned = active && parent.contains(active) ? Number(active.getAttribute('data-series-index')) : -1;
    var pinnedRow = pinned >= 0 ? Math.floor(pinned / layout.columns) : -1;
    var pin = pinnedRow < start || pinnedRow >= end ? pinnedRow : -1, cached = list.window;
    if (cached && cached.layout === layout && cached.start === start && cached.end === end && cached.pin === pin && cached.count === list.items.length) return;
    var desired = [], retained = Object.create(null), previous = 0;
    for (var nextRow = 0; nextRow < rows;) {
      if (nextRow < start && nextRow !== pinnedRow) { nextRow = pinnedRow >= nextRow && pinnedRow < start ? pinnedRow : start; continue; }
      if (nextRow >= end && nextRow !== pinnedRow) { if (pinnedRow >= nextRow) { nextRow = pinnedRow; continue; } break; }
      if (nextRow > previous) { var gap = element('div', 'series-spacer'); gap.setAttribute('aria-hidden', 'true'); gap.style.height = (offsets[nextRow] - offsets[previous]) + 'px'; desired.push(gap); }
      for (var index = nextRow * layout.columns; index < Math.min(list.items.length, (nextRow + 1) * layout.columns); index++) {
        var node = seriesNode(index) || mediaCard(list.items[index]); node.setAttribute('data-series-index', String(index)); retained[index] = true; desired.push(node);
      }
      previous = ++nextRow;
    }
    if (previous < rows) { var tail = element('div', 'series-spacer'); tail.setAttribute('aria-hidden', 'true'); tail.style.height = (offsets[rows] - offsets[previous]) + 'px'; desired.push(tail); }
    // Retain overlapping cards (especially the focused card) in place: moving a
    // focused node through a fragment would blur it on older TV Chromium builds.
    for (var child = parent.firstChild; child;) {
      var following = child.nextSibling, value = child.getAttribute('data-series-index');
      if (value === null || !retained[value]) parent.removeChild(child); child = following;
    }
    var before = null;
    for (var position = desired.length - 1; position >= 0; position--) { if (desired[position].parentNode !== parent) parent.insertBefore(desired[position], before); before = desired[position]; }
    parent.setAttribute('data-series-count', String(list.items.length)); panel.scrollTop = scroll;
    list.window = {layout:layout,start:start,end:end,pin:pin,count:list.items.length};
  }
  function loadSeriesMore() {
    var list = seriesList;
    if (!seriesCurrent(list) || dialogs.length || view.player || mediaSearchTimer) return Promise.resolve();
    if (list.loading) return list.promise || Promise.resolve();
    if (!list.ready) return fetchMedia();
    if (list.failed) status('');
    var restoreFocus = document.activeElement === byId('media-retry');
    list.failed = false; list.paused = false; byId('media-retry').hidden = true;
    if (list.shown < view.mediaItems.length) { appendSeriesItems(); scheduleSeriesScroll(); return Promise.resolve(); }
    if (!view.mediaHasMore) return Promise.resolve();
    var page = view.mediaPage + 1, before = list.items.length;
    list.loading = true; renderSeriesLoading();
    list.promise = query('catalog.items', {kind:'series',categoryId:list.categoryId,page:page,query:list.query}).then(function (data) {
      if (!seriesCurrent(list)) return;
      view.mediaItems = view.mediaItems.concat(array(data)); view.mediaPage = data.page || page; view.mediaHasMore = !!data.hasMore;
      list.loading = false; appendSeriesItems();
      // Empty/duplicate filtered pages may still have later provider pages.
      // Leave an explicit continuation instead of draining them automatically.
      list.paused = list.items.length === before && view.mediaHasMore; renderSeriesLoading();
      if (!list.paused) scheduleSeriesScroll();
    }).catch(function (error) {
      if (!seriesCurrent(list)) return; list.loading = false; list.failed = true; renderSeriesLoading(); report(error);
    }).then(function () {
      if (!seriesCurrent(list)) return; list.promise = null;
      if (restoreFocus && (document.activeElement === byId('media-retry') || document.activeElement === document.body)) {
        if (list.failed || list.paused) focus(byId('media-retry'));
        else { var index = Math.min(before, list.items.length - 1); renderSeriesWindow(index); focus(seriesNode(index)); }
      }
    });
    return list.promise;
  }
  function scheduleSeriesScroll() {
    if (seriesScrollScheduled || !seriesCurrent(seriesList)) return; seriesScrollScheduled = true;
    afterLoadingPaint().then(function () {
      seriesScrollScheduled = false; var list = seriesList;
      if (!seriesCurrent(list) || dialogs.length || view.player) return;
      renderSeriesWindow();
      if (list.loading || list.failed || list.paused) return;
      var panel = byId('media-view').querySelector('.media-panel');
      if (panel.scrollTop + panel.clientHeight >= panel.scrollHeight - Math.max(120, panel.clientHeight / 2)) loadSeriesMore();
    });
  }
  function moveSeries(key, active) {
    if (dialogs.length || view.player || !seriesCurrent(seriesList) || !active || active.getAttribute('data-series-index') === null) return false;
    var list = seriesList, index = Number(active.getAttribute('data-series-index')), columns = list.layout.columns;
    var next = index + (key === 40 ? columns : key === 38 ? -columns : key === 37 ? -1 : 1);
    if (next < 0 || key === 37 && index % columns === 0 || key === 39 && index % columns === columns - 1 && next < list.items.length) return false;
    if (next < list.items.length) { if (seriesNode(next)) return false; renderSeriesWindow(next); focus(seriesNode(next)); return true; }
    if (key !== 39 && key !== 40 || !view.mediaHasMore && list.shown >= view.mediaItems.length) return false;
    loadSeriesMore().then(function () {
      if (seriesCurrent(list) && document.activeElement === active && !dialogs.length && !view.player) { var target = Math.min(next, list.items.length - 1); renderSeriesWindow(target); focus(seriesNode(target)); }
    });
    return true;
  }
  function mediaPage(delta) {
    if (mediaSearchTimer) { window.clearTimeout(mediaSearchTimer); mediaSearchTimer = null; view.mediaPage = 1; view.mediaSlice = 0; if (view.mediaKind === 'favorites') renderFavoriteItems(); else fetchMedia(); return; }
    if (view.mediaKind === 'favorites') { view.mediaPage += delta; renderFavoriteItems(); }
    else {
      var next = view.mediaSlice + delta, parts = Math.max(1, Math.ceil(view.mediaItems.length / pageSize));
      if (next >= 0 && next < parts) { view.mediaSlice = next; renderMediaBuffer(); focus(byId('media-items').querySelector('button')); }
      else { view.mediaPage += delta; view.mediaSlice = delta < 0 ? -1 : 0; fetchMedia(); }
    }
  }
  function renderFavoriteItems() {
    var term = byId('media-search').value.toLowerCase();
    var filtered = view.favorites.filter(function (entry) { var item = entry.item || entry.channel || entry; return !term || String(item.title || item.name).toLowerCase().indexOf(term) >= 0; });
    var pages = Math.max(1, Math.ceil(filtered.length / pageSize)); view.mediaPage = Math.max(1, Math.min(view.mediaPage, pages));
    renderMediaItems(filtered.slice((view.mediaPage - 1) * pageSize, view.mediaPage * pageSize));
    byId('media-previous').disabled = view.mediaPage <= 1; byId('media-next').disabled = view.mediaPage >= pages; text(byId('media-page'), view.mediaPage + ' / ' + pages);
    if (!(document.activeElement === byId('media-search') && !byId('media-search').readOnly)) focus(byId('media-items').querySelector('button') || byId('media-search'));
  }
  function contextFor(sourceId, current) {
    if (!sourceId || view.source && view.source.id === sourceId) return Promise.resolve();
    return query('sources.load', { id: sourceId }).then(function (catalog) { if (!current()) throw cancelled(); clearPlaybackPresentation(); setCatalog(catalog, catalog.source); });
  }
  function openEntry(entry) {
    var args = contentArgs(entry); if (args.channel && view.screen !== 'home') { playContent(args); return; }
    var key = JSON.stringify([args.sourceId, (args.item || args.channel).kind, (args.item || args.channel).id]);
    if (detailsStart && detailsStart.key === key && detailsStart.current()) return detailsStart.promise;
    var request = view.request, mediaRequest = view.mediaRequest, screen = view.screen, start = {key:key}; detailsStart = start;
    function current() { return detailsStart === start && request === view.request && mediaRequest === view.mediaRequest && screen === view.screen && !view.player; }
    start.current = current;
    if (args.channel) {
      start.promise = contextFor(args.sourceId, current).then(function () {
        if (!current()) throw cancelled();
        showLive();
        return playContent(args);
      }).catch(function (error) { if (current()) report(error); }).then(function () { if (detailsStart === start) detailsStart = null; });
      return start.promise;
    }
    status(t("Loading details…"), false, true);
    start.promise = contextFor(args.sourceId, current).then(function () { if (!current()) throw cancelled(); return query('media.details', { item: args.item }); }).then(function (item) { if (current()) { status(''); showDetails(item || args.item, args.sourceId, args.item); } }).catch(function (error) { if (current()) report(error); }).then(function () { if (detailsStart === start) detailsStart = null; });
    return start.promise;
  }
  function showDetails(item, sourceId, originalItem) {
    sourceId = sourceId || view.source && view.source.id;
    var record = dialog(item.title, true), scroll = element('div', 'details-scroll'), hero = element('div', 'details-hero');
    record.mediaDetails = true; record.item = item; record.sourceId = sourceId; record.request = view.request; record.profileId = view.profile && view.profile.id; record.seasons = [];
    record.node.classList.add('media-details'); record.node.setAttribute('data-kind', item.kind); record.scroll = scroll;
    var close = button('×', 'button details-close', function () { closeDialog(true, record); }); close.setAttribute('aria-label', t('Close details')); record.node.appendChild(close);
    var artwork = item.backdrop || item.poster;
    if (artwork) image(artwork, 'details-backdrop', hero);
    hero.appendChild(element('div', 'details-hero-shade'));
    var heroContent = element('div', 'details-hero-content'), copy = element('div', 'details-copy'), badges = element('div', 'details-badges'), actions = element('div', 'details-actions');
    copy.appendChild(element('p', 'details-kind', t(item.kind === 'series' ? 'Series' : item.kind === 'season' ? 'Season' : item.kind === 'episode' ? 'Episode' : 'Movie')));
    copy.appendChild(element('h1', 'details-title', item.title));
    [item.year, runtimeLabel(item.durationSeconds || item.info && item.info.durationSeconds), item.rating ? '★ ' + item.rating : ''].forEach(function (value) { if (value) badges.appendChild(element('span', 'details-badge', value)); });
    copy.appendChild(badges); copy.appendChild(actions); heroContent.appendChild(copy); hero.appendChild(heroContent); scroll.appendChild(hero);
    var content = element('div', 'details-content'); record.content = content; scroll.appendChild(content); record.body.appendChild(scroll);
    var primary;
    if (item.kind === 'series' || item.kind === 'season') {
      record.series = element('div', 'details-seasons'); record.series.appendChild(element('h2', '', t('Episodes'))); content.appendChild(record.series);
      primary = button(t('View episodes'), 'button button-primary details-primary', function () {
        if (record.seriesContinuation) chooseResume(record.seriesContinuation, record.sourceId, record);
        else focus(record.seasons.length ? record.seasons[0].header : close);
      });
      if (item.kind === 'series') {
        record.seriesProgressRevision = 0;
        record.seriesProgress = element('div', 'details-series-progress'); record.seriesProgress.hidden = true;
        record.seriesWatched = element('p', 'details-series-watched'); record.seriesLatest = element('p', 'details-series-latest'); record.seriesNext = element('p', 'details-series-next');
        record.seriesProgress.appendChild(record.seriesWatched); record.seriesProgress.appendChild(record.seriesLatest); record.seriesProgress.appendChild(record.seriesNext);
        copy.appendChild(record.seriesProgress); copy.appendChild(actions);
        record.browseEpisodes = button(t('View episodes'), 'button details-browse-episodes', function () { focus(record.seasons.length ? record.seasons[0].header : close); });
        record.browseEpisodes.hidden = true;
      }
      loadDetailsSeasons(record);
    } else {
      primary = button(t('Play'), 'button button-primary', function () { startDetailsPlayback(record, item, primary.resumeMode || 'beginning'); });
      var fromStart = button(t('From start'), 'button', function () { startDetailsPlayback(record, item, 'beginning'); }); fromStart.hidden = true;
      actions.appendChild(primary); actions.appendChild(fromStart);
      query('media.progress', {items:[item],sourceId:sourceId}).then(function (data) {
        if (!detailsCurrent(record)) return;
        var saved = data.positions && data.positions[item.id];
        if (saved && data.resumeAllowed && saved.position > 0 && !saved.finished) {
          primary.resumeMode = 'resume'; text(primary, t('Resume from {position}', {position:time(saved.position)})); fromStart.hidden = false;
        }
      }).catch(function () {});
    }
    record.primary = primary;
    if (!primary.parentNode) actions.appendChild(primary);
    if (record.browseEpisodes) actions.appendChild(record.browseEpisodes);
    var refresh = button(t('Refresh details'), 'button', function () {
      refresh.disabled = true;
      query('media.refresh', {item:originalItem || item}).then(function (updated) {
        if (!detailsCurrent(record)) return;
        closeDialog(false, record); showDetails(updated || item, sourceId, originalItem || item);
      }).catch(function (error) { if (detailsCurrent(record)) text(record.error, message(error, t('Could not refresh details.'))); }).then(function () { refresh.disabled = false; });
    }); actions.appendChild(refresh);
    if (item.trailerUrl && cap('trailer')) actions.appendChild(button(t('Watch trailer'), 'button', function () { query('media.trailer', {item:item}).catch(function (error) { if (detailsCurrent(record)) text(record.error, message(error, t('Could not open the trailer or YouTube.'))); }); }));
    if (cap('favorites')) {
      record.favoriteRevision = 0;
      var favorite = button(t('♡ Favorites'), 'button', function () {
        var revision = ++record.favoriteRevision; favorite.disabled = true;
        query('favorites.toggle', {item:item,sourceId:sourceId}).then(function (data) { if (detailsCurrent(record) && revision === record.favoriteRevision) text(favorite, data.favorite ? t('♥ Favorites') : t('♡ Favorites')); }).catch(function (error) { if (detailsCurrent(record)) text(record.error, message(error)); }).then(function () { favorite.disabled = false; });
      }); actions.appendChild(favorite);
      query('favorites.list').then(function (rows) {
        if (!detailsCurrent(record) || record.favoriteRevision) return;
        var saved = array(rows).some(function (row) { var entry = row.item || {}; return row.sourceId === sourceId && entry.id === item.id && entry.kind === item.kind; });
        text(favorite, saved ? t('♥ Favorites') : t('♡ Favorites'));
      }).catch(function () {});
    }
    if (view.parental && view.parental.enabled && (item.kind === 'movie' || item.kind === 'series')) actions.appendChild(button(t('Lock / unlock item'), 'button', function () { parentalToggle('channel', item.id, item.kind, record); }));
    if (item.description) { var description = element('p', 'details-description', item.description); description.tabIndex = 0; description.setAttribute('data-nav', ''); content.appendChild(description); }
    renderDetailsInformation(content, item);
    if (item.sourceHints && item.sourceHints.length) content.appendChild(element('p', 'muted details-source-hints', item.sourceHints.join(' · ')));
    if (item.sourceTitle && item.sourceTitle !== item.title) content.appendChild(element('p', 'muted', t('Source title: {title}', {title:item.sourceTitle})));
    var metadataStatus = element('p', 'muted details-metadata-status'); content.appendChild(metadataStatus);
    query('media.metadataStatus').then(function (data) {
      if (!detailsCurrent(record)) return;
      var savedMetadata = item.extra && item.extra.metadata;
      text(metadataStatus, t(savedMetadata && (savedMetadata.tmdb || savedMetadata.tvdb) ? 'Details from your provider and saved metadata.' : 'Details from your provider.'));
    }).catch(function () { if (detailsCurrent(record)) text(metadataStatus, t('Details from your provider.')); });
    focus(primary); return record;
  }
  function runtimeLabel(seconds) { return Number(seconds) > 0 ? Math.max(1, Math.round(Number(seconds) / 60)) + ' min' : ''; }
  function episodeNumberLabel(item) {
    return item.seasonNumber != null && item.episodeNumber != null
      ? t('S{season}E{episode}', {season:item.seasonNumber,episode:item.episodeNumber}) : item.title;
  }
  function episodeSummaryLabel(item) {
    var number = episodeNumberLabel(item); return number === item.title ? item.title : number + ', ' + item.title;
  }
  function updateSeriesProgress(record) {
    if (!record.seriesProgress || !detailsCurrent(record)) return Promise.resolve();
    var revision = ++record.seriesProgressRevision;
    return query('media.seriesProgress', {item:record.item,sourceId:record.sourceId}).then(function (data) {
      if (!detailsCurrent(record) || revision !== record.seriesProgressRevision || record.sourceId !== (view.source && view.source.id)) return;
      var latest = data.latestEpisode, position = data.latestPosition, next = data.complete ? null : data.nextEpisode;
      var scroll = record.scroll.scrollTop;
      record.seriesContinuation = next || null;
      record.seriesProgress.hidden = !latest || !position;
      text(record.seriesWatched, t('Watched episodes: {count}', {count:data.watchedCount || 0}));
      text(record.seriesLatest, latest ? t('Last watched: {episode}', {episode:episodeSummaryLabel(latest)}) : '');
      record.seriesNext.hidden = !data.complete && !next;
      text(record.seriesNext, data.complete ? t('All available episodes watched') : next
        ? position && !position.finished ? t('Resume from {position}', {position:time(position.position)})
          : t('Next episode: {episode}', {episode:episodeSummaryLabel(next)}) : '');
      text(record.primary, next ? t(position && !position.finished ? 'Resume {episode}' : 'Play {episode}', {episode:episodeNumberLabel(next)}) : t('View episodes'));
      if (!next && document.activeElement === record.browseEpisodes) focus(record.primary);
      record.browseEpisodes.hidden = !next;
      record.scroll.scrollTop = scroll;
    }).catch(function () {});
  }
  function detailsCurrent(record) {
    return !record.closed && record.request === view.request && record.profileId === (view.profile && view.profile.id) && (dialogs.indexOf(record) >= 0 || suspendedDetails && suspendedDetails.records.indexOf(record) >= 0);
  }
  function renderDetailsInformation(parent, item) {
    var info = item.info || {}, rows = element('div', 'details-info-grid'), section = element('section', 'details-section');
    function row(label, value) {
      if (Array.isArray(value)) value = value.join(', ');
      if (!value) return;
      var node = element('div', 'details-info-row'); node.tabIndex = 0; node.setAttribute('data-nav', '');
      node.appendChild(element('span', 'details-info-label', t(label))); node.appendChild(element('span', 'details-info-value', value)); rows.appendChild(node);
    }
    row('Original title', info.originalTitle); row('Genres', info.genres); row('Director', info.directors); row('Creators', info.creators); row('Country', info.countries); row('Release date', info.releaseDate); row('Duration', runtimeLabel(info.durationSeconds || item.durationSeconds));
    if (rows.children.length) { section.appendChild(element('h2', '', t('Information'))); section.appendChild(rows); parent.appendChild(section); }
    if (info.cast && info.cast.length) {
      var castSection = element('section', 'details-section'), cast = element('div', 'details-cast'); castSection.appendChild(element('h2', '', t('Cast')));
      info.cast.forEach(function (person) {
        var node = element('div', 'details-person'); node.tabIndex = 0; node.setAttribute('data-nav', '');
        if (person.photoUrl) image(person.photoUrl, 'details-person-photo', node);
        node.appendChild(element('span', 'details-person-name', person.name)); if (person.role) node.appendChild(element('span', 'details-person-role', person.role)); cast.appendChild(node);
      }); castSection.appendChild(cast); parent.appendChild(castSection);
    }
  }
  function loadDetailsSeasons(record) {
    var loading = element('p', 'details-loading', t('Loading…')); record.series.appendChild(loading);
    var ready = record.item.kind === 'season' ? Promise.resolve({items:[record.item]}) : query('media.children', {item:record.item});
    ready.then(function (data) {
      if (!detailsCurrent(record)) return; loading.parentNode.removeChild(loading);
      var items = array(data);
      updateSeriesProgress(record);
      if (!items.length) { record.series.appendChild(element('p', 'details-empty', t('No episodes found'))); return; }
      items.forEach(function (season) {
        var section = {record:record,item:season,items:null,cursor:0,start:0,positions:Object.create(null),progressLoaded:Object.create(null),progressRevision:0};
        section.node = element('div', 'season-section'); section.header = button(season.title, 'button season-button', function () { toggleDetailsSeason(section); }); section.header.detailsSeason = section;
        section.header.setAttribute('aria-expanded', 'false'); section.rail = element('div', 'episode-rail'); section.rail.hidden = true;
        section.node.appendChild(section.header); section.node.appendChild(section.rail); record.series.appendChild(section.node); record.seasons.push(section);
        section.rail.addEventListener('scroll', function () {
          if (!section.items || section.paintScheduled) return; section.paintScheduled = true;
          afterLoadingPaint().then(function () {
            section.paintScheduled = false; if (!detailsCurrent(record) || section.rail.hidden) return;
            var first = Math.floor(section.rail.scrollLeft / 252);
            if (first < section.start || first + 5 > section.start + 12) renderEpisodeWindow(section, first, false);
          });
        });
      });
    }).catch(function (error) { if (detailsCurrent(record)) { loading.className = 'details-empty'; text(loading, message(error, t('No episodes found'))); } });
  }
  function toggleDetailsSeason(section) {
    var expanded = section.header.getAttribute('aria-expanded') !== 'true';
    section.header.setAttribute('aria-expanded', expanded ? 'true' : 'false'); section.rail.hidden = !expanded;
    if (!expanded) { section.savedScroll = section.rail.scrollLeft; clear(section.rail); return; }
    if (section.items) { renderEpisodeWindow(section, section.cursor, false); section.rail.scrollLeft = section.savedScroll || 0; return; }
    if (section.loading) return;
    section.loading = true; var loading = element('p', 'details-loading', t('Loading…')); section.rail.appendChild(loading);
    query('media.children', {item:section.item}).then(function (data) {
      section.loading = false; if (!detailsCurrent(section.record)) return;
      section.items = array(data); renderEpisodeWindow(section, 0, false);
      updateSeriesProgress(section.record);
    }).catch(function (error) { section.loading = false; if (detailsCurrent(section.record)) { text(loading, message(error, t('No episodes found'))); } });
  }
  function renderEpisodeWindow(section, index, select) {
    var items = section.items || [], rail = section.rail, retained = document.activeElement, retainedIndex = retained && retained.detailsSeason === section ? retained.episodeIndex : null;
    section.start = Math.max(0, Math.min(Math.max(0, items.length - 12), index - 2)); clear(rail);
    function spacer(count) { var node = element('span', 'episode-spacer'); node.style.width = count * 252 + 'px'; node.style.minWidth = count * 252 + 'px'; node.style.flexShrink = '0'; rail.appendChild(node); }
    spacer(section.start);
    items.slice(section.start, section.start + 12).forEach(function (item, offset) {
      var itemIndex = section.start + offset;
      var card = button('', 'episode-card', function () { section.cursor = itemIndex; view.episodes = {parent:section.item,sourceId:section.record.sourceId}; chooseResume(item, section.record.sourceId, section.record); });
      card.setAttribute('data-episode-index', String(itemIndex)); card.detailsSeason = section; card.episodeIndex = itemIndex;
      card.addEventListener('focus', function () { section.cursor = itemIndex; });
      var thumb = element('div', 'episode-thumb'), artwork = item.backdrop || item.poster || section.record.item.backdrop || section.record.item.poster;
      if (artwork) image(artwork, 'episode-image', thumb); thumb.appendChild(element('span', 'episode-play', '▶'));
      var duration = item.durationSeconds || item.info && item.info.durationSeconds; if (duration) thumb.appendChild(element('span', 'episode-runtime', runtimeLabel(duration))); card.appendChild(thumb);
      card.appendChild(element('span', 'episode-title', (item.episodeNumber ? item.episodeNumber + '. ' : '') + item.title));
      if (item.year) card.appendChild(element('span', 'episode-meta', item.year)); if (item.description) card.appendChild(element('span', 'episode-description', item.description));
      rail.appendChild(card); updateEpisodeProgress(card, section.positions[item.id]);
    }); spacer(Math.max(0, items.length - section.start - 12));
    if (!items.length) rail.appendChild(element('p', 'details-empty', t('No episodes found')));
    if (select || retainedIndex !== null) {
      var targetIndex = select ? index : retainedIndex, target = rail.querySelector('[data-episode-index="' + targetIndex + '"]');
      if (target) focus(target);
    }
    var pending = items.slice(section.start, section.start + 12).filter(function (item) { return !section.progressLoaded[item.id]; });
    if (!pending.length) return;
    var progressRevision = section.progressRevision;
    pending.forEach(function (item) { section.progressLoaded[item.id] = true; });
    query('media.progress', {items:pending,sourceId:section.record.sourceId}).then(function (data) {
      if (!detailsCurrent(section.record) || progressRevision !== section.progressRevision) return;
      Object.keys(data.positions || {}).forEach(function (id) { section.positions[id] = data.positions[id]; });
      var cards = rail.querySelectorAll('.episode-card');
      for (var i = 0; i < cards.length; i++) updateEpisodeProgress(cards[i], section.positions[items[cards[i].episodeIndex].id]);
    }).catch(function () {});
  }
  function updateEpisodeProgress(card, saved) {
    var old = card.querySelector('.episode-progress'); if (old) old.parentNode.removeChild(old); old = card.querySelector('.episode-position'); if (old) old.parentNode.removeChild(old);
    if (!saved || !(saved.position > 0)) return;
    var progress = element('span', 'episode-progress'), fill = element('span', 'episode-progress-fill'); fill.style.width = Math.min(100, saved.progress == null ? saved.duration > 0 ? saved.position * 100 / saved.duration : 0 : saved.progress * 100) + '%'; progress.appendChild(fill); card.appendChild(progress);
    card.appendChild(element('span', 'episode-position', saved.finished ? t('Watched') : t('Resume from {position}', {position:time(saved.position)})));
  }
  function startDetailsPlayback(record, item, mode) {
    if (!detailsCurrent(record) || suspendedDetails) return;
    while (dialogs.length && dialogs[dialogs.length - 1] !== record) closeDialog(false);
    suspendedDetails = {records:dialogs.splice(0),focus:document.activeElement,screen:view.screen,request:view.request,profileId:view.profile && view.profile.id,scroll:record.scroll.scrollTop,rails:record.seasons.map(function (season) { return {season:season,offset:season.rail.scrollLeft}; })};
    suspendedDetails.records.forEach(function (entry) { entry.node.hidden = true; });
    byId('modal-layer').hidden = true; document.body.classList.remove('dialog-open');
    playContent({item:item,sourceId:record.sourceId,resumeMode:mode});
  }
  function discardDetails() {
    if (!suspendedDetails) return;
    suspendedDetails.records.forEach(function (record) { record.closed = true; if (record.node.parentNode) record.node.parentNode.removeChild(record.node); }); suspendedDetails = null;
  }
  function restoreDetails() {
    if (!suspendedDetails) return false;
    var saved = suspendedDetails;
    if (saved.request !== view.request || saved.profileId !== (view.profile && view.profile.id)) { discardDetails(); return false; }
    // Player dialogs can still be settling when playback stops. Remove them
    // before replacing the stack so their nodes cannot outlive their records.
    while (dialogs.length) closeDialog(false);
    suspendedDetails = null; dialogs = saved.records;
    var record = dialogs[dialogs.length - 1]; record.node.hidden = false; byId('modal-layer').hidden = false; document.body.classList.add('dialog-open');
    focus(saved.focus); record.scroll.scrollTop = saved.scroll; saved.rails.forEach(function (entry) { entry.season.rail.scrollLeft = entry.offset; });
    record.seasons.forEach(function (season) { season.progressRevision++; season.progressLoaded = Object.create(null); if (season.items && !season.rail.hidden) renderEpisodeWindow(season, season.cursor, false); });
    updateSeriesProgress(record);
    record.scroll.scrollTop = saved.scroll; saved.rails.forEach(function (entry) { entry.season.rail.scrollLeft = entry.offset; }); return true;
  }
  function moveDetails(key, active) {
    var record = dialogs.length && dialogs[dialogs.length - 1], section = active && active.detailsSeason;
    if (!record || !record.mediaDetails || !section || key < 37 || key > 40) return false;
    var seasons = record.seasons, seasonIndex = seasons.indexOf(section);
    if (active.episodeIndex != null) {
      if (key === 37 || key === 39) {
        var next = Math.max(0, Math.min(section.items.length - 1, active.episodeIndex + (key === 37 ? -1 : 1)));
        section.cursor = next; var target = section.rail.querySelector('[data-episode-index="' + next + '"]'); if (target) focus(target); else renderEpisodeWindow(section, next, true); return true;
      }
      if (key === 38) { focus(section.header); return true; }
      if (seasonIndex + 1 < seasons.length) { focus(seasons[seasonIndex + 1].header); return true; }
    } else if (key === 40 && section.items && section.items.length && !section.rail.hidden) {
      renderEpisodeWindow(section, section.cursor, true); return true;
    }
    return false;
  }
  function showChildren(parent, sourceId) {
    if (dialogs.length && dialogs[dialogs.length - 1].mediaDetails) {
      var details = dialogs[dialogs.length - 1]; focus(details.seasons.length ? details.seasons[0].header : details.node.querySelector('.details-close')); return Promise.resolve();
    }
    var owner = dialogs.length ? dialogs[dialogs.length - 1] : null, request = view.request, screen = view.screen, player = view.player, playbackRequest = view.playbackRequest;
    var key = JSON.stringify([sourceId, parent.kind, parent.id]);
    if (childrenStart && childrenStart.key === key && childrenStart.current()) return childrenStart.promise;
    var start = { key: key }; childrenStart = start;
    function current() { return childrenStart === start && request === view.request && screen === view.screen && player === view.player && playbackRequest === view.playbackRequest && owner === (dialogs.length ? dialogs[dialogs.length - 1] : null); }
    start.current = current;
    start.promise = query('media.children', { item: parent }).then(function (data) {
      if (!current()) return;
      var items = array(data), record = dialog(parent.title), list = element('div', 'dialog-list'), page = 0;
      record.body.appendChild(list);
      function render() {
        clear(list); items.slice(page * pageSize, (page + 1) * pageSize).forEach(function (item) {
          list.appendChild(button((item.episodeNumber ? item.episodeNumber + '. ' : '') + item.title, 'button', function () {
            if (item.kind === 'season' || item.kind === 'series') showChildren(item, sourceId);
            else { view.episodes = { parent: parent, sourceId: sourceId }; chooseResume(item, sourceId); }
          }));
        });
        if (!items.length) list.appendChild(element('p', 'muted', t("No episodes found")));
        previous.disabled = page === 0; next.disabled = (page + 1) * pageSize >= items.length;
        focus(list.querySelector('button') || record.actions.lastChild);
      }
      var previous = dialogButton(record, t("Previous"), function () { page--; render(); });
      var next = dialogButton(record, t("Next"), function () { page++; render(); });
      previous.hidden = next.hidden = items.length <= pageSize;
      dialogButton(record, t("Back"), function () { closeDialog(true); }); render();
    }).catch(function (error) { if (current()) report(error); }).then(function () { if (childrenStart === start) childrenStart = null; });
    return start.promise;
  }
  function chooseResume(item, sourceId, details) {
    var ready = cap('resume') ? query('resume.get', { item: item, sourceId: sourceId }) : Promise.resolve({ allowed: false, position: 0 });
    ready.then(function (resume) {
      if (details && !detailsCurrent(details)) return;
      function start(mode) { if (details) startDetailsPlayback(details, item, mode); else { closeAllDialogs(); playContent({ item: item, sourceId: sourceId, resumeMode: mode }); } }
      if (resume.allowed && resume.position > 0) {
        optionDialog(t("Continue watching?"), [{ value: 'resume', label: t('Resume from {position}', { position: time(resume.position) }) }, { value: 'beginning', label: t("From start") }], 'resume', function (mode) {
          window.setTimeout(function () { start(mode); }, 0);
        });
      } else start('beginning');
    }).catch(report);
  }
  function toggleFavorite(args, record) {
    return query('favorites.toggle', args).then(function (data) {
      var label = data.favorite ? t("Added to favorites.") : t("Removed from favorites."); if (record) text(record.error, label); else status(label);
      if (view.player) text(byId('player-favorite'), data.favorite ? t("♥ Favorites") : t("♡ Favorites"));
      if (view.screen === 'media' && view.mediaKind === 'favorites') query('favorites.list').then(function (rows) { view.favorites = array(rows); renderFavoriteItems(); }).catch(report);
    }).catch(function (error) { if (record) text(record.error, message(error, t("Could not update favorites."))); else report(error); });
  }
  function showGuide() {
    view.guideVisible = !usesLiveGuide();
    if (usesLiveGuide()) syncLiveGuide(); else renderChannels();
    focus(firstLiveChannel() || byId('show-guide'));
    if (!usesLiveGuide()) loadNowNext(view.filtered.slice(view.page * pageSize, (view.page + 1) * pageSize));
  }
  function syncLiveGuide() {
    var visible = usesLiveGuide(); byId('guide-panel').hidden = !visible; byId('channel-panel').hidden = visible;
    text(byId('show-guide'), t(visible ? 'Channel list' : 'TV guide')); byId('show-guide').setAttribute('aria-pressed', visible ? 'true' : 'false');
    if (visible && view.screen === 'catalog') {
      if (!view.guideFrom) view.guideFrom = Date.now() - Date.now() % 1800000;
      fetchGuide();
    } else ++view.guideRequest;
  }
  function guideWindowChannels() {
    var grid = byId('guide-grid'), firstVisible = Math.floor(grid.scrollTop / guideRowHeight);
    var visibleCount = Math.max(1, Math.ceil(grid.clientHeight / guideRowHeight)), start = view.guideStartIndex;
    if (firstVisible < start + 2 && start > 0 || firstVisible + visibleCount > start + guideWindowSize - 2) {
      view.guideStartIndex = Math.max(0, Math.min(Math.max(0, view.filtered.length - guideWindowSize), firstVisible - 6));
    }
    return view.filtered.slice(view.guideStartIndex, view.guideStartIndex + guideWindowSize);
  }
  function cachedGuideProgrammes(channels) {
    var programmes = [];
    channels.forEach(function (channel) { if (view.guideData[channel.id]) programmes = programmes.concat(view.guideData[channel.id]); });
    return programmes;
  }
  function rememberGuideProgrammes(channels, programmes) {
    var grouped = groupGuideProgrammes(programmes);
    channels.forEach(function (channel) {
      var key = channel.id, old = view.guideDataOrder.indexOf(key);
      if (old >= 0) view.guideDataOrder.splice(old, 1);
      view.guideDataOrder.push(key); view.guideData[key] = grouped[key] || [];
    });
    while (view.guideDataOrder.length > 240) delete view.guideData[view.guideDataOrder.shift()];
  }
  function groupGuideProgrammes(programmes) {
    var grouped = Object.create(null);
    programmes.forEach(function (programme) {
      var key = programme.channelId;
      if (!grouped[key]) grouped[key] = [];
      grouped[key].push(programme);
    });
    return grouped;
  }
  function onGuideScroll() {
    if (view.screen !== 'catalog' || !usesLiveGuide()) return;
    var row = Math.floor(byId('guide-grid').scrollTop / guideRowHeight);
    if (row === view.guideScrollRow) return;
    view.guideScrollRow = row;
    if (!guidePaintScheduled) {
      guidePaintScheduled = true;
      var paint = function () {
        guidePaintScheduled = false;
        if (view.screen !== 'catalog' || !usesLiveGuide()) return;
        var previousStart = view.guideStartIndex, channels = guideWindowChannels();
        if (previousStart !== view.guideStartIndex) renderGuide(channels, cachedGuideProgrammes(channels), view.guideFrom, view.guideFrom + 2 * 3600000);
      };
      if (window.requestAnimationFrame) window.requestAnimationFrame(paint); else window.setTimeout(paint, 16);
    }
    window.clearTimeout(guideScrollTimer);
    guideScrollTimer = window.setTimeout(function () { guideScrollTimer = null; fetchGuide(); }, 180);
  }
  function fetchGuide(forceRefresh) {
    if (view.screen !== 'catalog' || !usesLiveGuide()) return Promise.resolve();
    var source = view.source, selected = guideWindowChannels(), from = view.guideFrom, to = from + 2 * 3600000;
    var range = JSON.stringify([view.request, source && source.id, from, to]);
    if (range !== view.guideDataRange) { view.guideDataRange = range; view.guideData = Object.create(null); view.guideDataOrder = []; }
    renderGuide(selected, cachedGuideProgrammes(selected), from, to);
    // Fetch programmes for visible rows only; DOM overscan must not trigger
    // per-channel provider requests for forty off-screen guide rows.
    var firstVisible = Math.floor(byId('guide-grid').scrollTop / guideRowHeight);
    var visibleCount = Math.max(1, Math.min(12, Math.ceil(byId('guide-grid').clientHeight / guideRowHeight) + 1));
    selected = view.filtered.slice(firstVisible, firstVisible + visibleCount);
    if (!selected.length) { ++view.guideRequest; status(''); return Promise.resolve(); }
    if (!forceRefresh) selected = selected.filter(function (channel) { return !Object.prototype.hasOwnProperty.call(view.guideData, channel.id); });
    if (!selected.length) return Promise.resolve();
    var key = JSON.stringify([view.request, source && source.id, selected.map(function (channel) { return channel.id; }), from, to]);
    if (guideStart && guideStart.key === key && guideStart.request === view.guideRequest) return guideStart.promise;
    var request = ++view.guideRequest, start = { key: key, request: request }; guideStart = start;
    status(t("Loading guide…"), false, true);
    start.promise = query('guide', { channels: selected, from: new Date(from).toISOString(), to: new Date(to).toISOString() }).then(function (data) {
      if (request !== view.guideRequest || source !== view.source || view.screen !== 'catalog' || !usesLiveGuide()) return;
      var programmes = array(data.programmes); rememberGuideProgrammes(selected, programmes);
      view.nowNext = Object.assign({}, view.nowNext);
      selected.forEach(function (channel) { delete view.nowNext[channel.id]; });
      Object.assign(view.nowNext, data.nowNext || {});
      var current = guideWindowChannels(); renderGuide(current, cachedGuideProgrammes(current), from, to); renderNowNext(); status('');
    }).catch(function (error) { if (request === view.guideRequest && view.screen === 'catalog' && usesLiveGuide()) report(error, t('Could not load TV guide.')); }).then(function () { if (guideStart === start) guideStart = null; });
    return start.promise;
  }
  function renderGuide(channels, programmes, from, to) {
    var grid = byId('guide-grid'), active = document.activeElement, retained = grid.contains(active) && active.getAttribute('data-channel-id'), retainedStart = retained && active.getAttribute('data-programme-start');
    var rows = byId('guide-rows'); if (!rows) { rows = element('div', 'guide-rows'); rows.id = 'guide-rows'; grid.appendChild(rows); }
    rows.style.height = view.filtered.length * guideRowHeight + 'px';
    var owner = JSON.stringify([view.request, view.source && view.source.id, view.guideFilter, from, to, uiLanguage]);
    if (!guideRenderState || guideRenderState.rows !== rows || guideRenderState.owner !== owner) {
      clear(rows); clear(byId('guide-times'));
      guideRenderState = { owner: owner, rows: rows, records: Object.create(null) };
      text(byId('guide-date'), new Date(from).toLocaleDateString(uiLanguage) + ' · ' + clock(from) + ' – ' + clock(to));
      var ticks = element('div', 'guide-row guide-time-row'); ticks.appendChild(element('div', 'guide-channel')); var header = element('div', 'guide-timeline');
      for (var tickTime = from; tickTime < to; tickTime += 1800000) { var tick = element('span', 'guide-tick', clock(tickTime)); tick.style.left = (tickTime - from) / (to - from) * 100 + '%'; header.appendChild(tick); }
      ticks.appendChild(header); byId('guide-times').appendChild(ticks);
    }
    var grouped = groupGuideProgrammes(programmes), records = Object.create(null), now = Date.now(), wanted = Object.create(null);
    channels.forEach(function (channel) { wanted[String(channel.id)] = true; });
    // Remove departing rows first. Moving a retained ancestor with insertBefore
    // blurs its focused button on Chromium, even though that node stays mounted.
    Object.keys(guideRenderState.records).forEach(function (key) {
      var old = guideRenderState.records[key]; if (!wanted[key] && old.row.parentNode === rows) rows.removeChild(old.row);
    });
    channels.forEach(function (channel, index) {
      var key = String(channel.id), channelIndex = view.guideStartIndex + index, matches = grouped[key] || [];
      var record = guideRenderState.records[key];
      if (!record || record.channel !== channel || record.index !== channelIndex || !sameGuideProgrammes(record.programmes, matches)) {
        if (record && record.row.parentNode === rows) rows.removeChild(record.row);
        record = createGuideRow(channel, channelIndex, matches, from, to);
      }
      records[key] = record;
      record.programmeNodes.forEach(function (entry) { entry.node.classList.toggle('is-current', entry.start <= now && entry.end > now); });
      if (now >= from && now < to) {
        if (!record.line) { record.line = element('span', 'guide-now-line'); record.timeline.appendChild(record.line); }
        record.line.style.left = (now - from) / (to - from) * 100 + '%';
      } else if (record.line) { record.timeline.removeChild(record.line); record.line = null; }
      if (rows.children[index] !== record.row) rows.insertBefore(record.row, rows.children[index] || null);
    }); byId('guide-empty').hidden = !!view.filtered.length; refreshChannelRows();
    guideRenderState.records = records;
    if (retained && (!grid.contains(active) || document.activeElement !== active)) {
      var candidates = grid.querySelectorAll('[data-channel-id]'), target = null;
      for (var i = 0; i < candidates.length; i++) if (candidates[i].getAttribute('data-channel-id') === retained) {
        if (!target || retainedStart && candidates[i].getAttribute('data-programme-start') === retainedStart) target = candidates[i];
      }
      if (!target) target = grid.querySelector('.guide-channel[data-guide-index="' + Math.floor(grid.scrollTop / guideRowHeight) + '"]');
      focus(target);
    }
  }
  function sameGuideProgrammes(previous, current) {
    if (previous.length !== current.length) return false;
    for (var i = 0; i < previous.length; i++) if (previous[i] !== current[i]) return false;
    return true;
  }
  function createGuideRow(channel, index, programmes, from, to) {
    var row = element('div', 'guide-row'), timeline = element('div', 'guide-timeline'), programmeNodes = [];
    row.style.top = index * guideRowHeight + 'px';
    var channelButton = button('', 'guide-channel', function () { activateChannel(channel); }); channelButton.setAttribute('data-channel-id', channel.id);
    channelButton.setAttribute('data-guide-index', String(index));
    channelButton.appendChild(element('span', 'channel-number', channel.number || index + 1));
    if (channel.logo) image(channel.logo, 'guide-channel-logo', channelButton);
    channelButton.appendChild(element('span', 'guide-channel-name', channel.name)); row.appendChild(channelButton);
    programmes.forEach(function (p) {
      var start = Date.parse(p.start), end = Date.parse(p.stop); if (!(end > from && start < to)) return;
      var node = button(clock(p.start) + ' ' + p.title, 'guide-programme' + (p.canCatchup ? ' is-catchup' : ''), function () { if (start <= Date.now() && end > Date.now()) activateChannel(channel); else showProgramme(p, channel); });
      node.setAttribute('data-channel-id', channel.id); node.setAttribute('data-programme-start', p.start); node.setAttribute('data-guide-index', String(index));
      node.style.left = (Math.max(start, from) - from) / (to - from) * 100 + '%'; node.style.width = (Math.min(end, to) - Math.max(start, from)) / (to - from) * 100 + '%'; timeline.appendChild(node);
      programmeNodes.push({ node: node, start: start, end: end });
    });
    if (!programmeNodes.length) {
      var empty = button(t('No programme information'), 'guide-programme is-empty', function () { activateChannel(channel); }); empty.setAttribute('data-channel-id', channel.id); empty.setAttribute('data-guide-index', String(index)); timeline.appendChild(empty);
    }
    row.appendChild(timeline);
    return { channel: channel, index: index, programmes: programmes, row: row, timeline: timeline, programmeNodes: programmeNodes, line: null };
  }
  function showProgramme(programme, channel) {
    var record = dialog(programme.title); record.body.appendChild(element('p', 'details-meta', channel.name + ' · ' + clock(programme.start) + ' – ' + clock(programme.stop)));
    record.body.appendChild(element('p', 'details-description', programme.description || ''));
    if (programme.canCatchup) dialogButton(record, t("Watch catch-up"), function () { closeAllDialogs(); playContent({ channel: channel, programme: programme, sourceId: view.source.id }); }, true);
    dialogButton(record, t("Play live"), function () { closeAllDialogs(); playContent({ channel: channel, sourceId: view.source.id }); }, !programme.canCatchup);
    if (cap('favorites')) dialogButton(record, t("♡ Favorite channel"), function () { toggleFavorite({ channel: channel, sourceId: view.source.id }, record); });
    dialogButton(record, t("Back"), function () { closeDialog(true); }); focus(record.actions.firstChild);
  }
  function refreshParental() { return query('parental.get').then(function (data) { view.parental = data; updateLockButtons(); return data; }); }
  function updateLockButtons() {
    var enabled = !!(view.parental && view.parental.enabled);
    byId('live-lock-category').hidden = !enabled || view.category === null;
    byId('live-lock-channel').hidden = !enabled || !view.channel;
    byId('media-lock-category').hidden = !enabled || view.mediaCategory === null || view.mediaKind === 'favorites';
  }
  function parentalToggle(type, id, kind, record) {
    return query('parental.toggle', { type: type, id: id, kind: kind, sourceId: view.source.id }).then(function () {
      if (record) text(record.error, t("Protection updated.")); else status(t("Protection updated."));
    }).catch(function (error) { if (record) text(record.error, message(error, t("Could not update protection."))); else report(error); });
  }
  function parentalForm() {
    refreshParental().then(function (data) {
      var record = dialog(t("Parental controls")), lockSettings = !!data.lockSettings;
      record.body.appendChild(element('p', 'muted', data.enabled ? t("Protection is enabled. Enter the current PIN to make changes.") : t("Set a four-digit PIN to protect selected channels and categories.")));
      var input = editableInput(record.body, t("New PIN"), 'password', '', 4); input.setAttribute('inputmode', 'numeric');
      var protect = button('', 'setting-row', function () { lockSettings = !lockSettings; text(protect, t("Protect settings: {value}", { value: lockSettings ? t("Yes") : t("No") })); });
      text(protect, t("Protect settings: {value}", { value: lockSettings ? t("Yes") : t("No") })); record.body.appendChild(protect);
      var save = dialogButton(record, t("Save PIN and settings protection"), function () {
        query('parental.setPin', { newPin: input.value, lockSettings: lockSettings }).then(function () { closeDialog(false, record); showSettings(); }).catch(function (error) { text(record.error, message(error, t("Could not save parental controls."))); });
      }, true); save.disabled = true; input.addEventListener('input', function () { save.disabled = !input.value; });
      if (data.enabled) dialogButton(record, t("Disable parental controls"), function () { query('parental.setPin', { newPin: '' }).then(function () { closeDialog(false, record); showSettings(); }).catch(function (error) { text(record.error, message(error, t("Could not disable parental controls."))); }); });
      dialogButton(record, t("Back"), function () { closeDialog(true); }); focus(input);
    }).catch(report);
  }
  function showSettings() {
    showScreen('settings'); byId('settings-view').tabIndex = -1; focus(byId('settings-view'));
    var request = view.request;
    clear(byId('settings-list')); text(byId('settings-profile'), view.profile ? view.profile.name : ''); status(t("Loading settings…"));
    Promise.all([query('settings.get'), refreshParental()]).then(function (data) { if (view.screen !== 'settings' || request !== view.request) return; renderSettings(data[0]); status(''); }).catch(function (error) { if (view.screen === 'settings' && request === view.request) report(error); });
  }
  function renderSettings(data) {
    view.settings = data.settings || {}; var parent = byId('settings-list'); clear(parent);
    parent.appendChild(button(t('Help & connection'), 'setting-row', connectionHelp));
    var language = button('', 'setting-row', function () { showLanguage(true); });
    language.appendChild(element('span', 'setting-label', t('Language')));
    var selectedLanguage = (view.languages.length ? view.languages : JSON.parse(core.appLanguages())).filter(function (row) { return row.code === view.languageCode; })[0];
    language.appendChild(element('span', 'setting-value', selectedLanguage ? selectedLanguage.name : view.languageCode)); parent.appendChild(language);
    array(data.fields).forEach(function (field) {
      if (field.type !== 'select' || !Array.isArray(field.options)) return;
      var choices = field.options.map(function (option) {
        var labels = { auto: 'Auto', always: 'Always', off: 'Never' };
        return { value: option.value, label: field.key === 'profilePickerStartup' ? t(labels[option.value] || option.label) : uiLabel(option.label) };
      });
      var current = view.settings[field.key], selected = choices.filter(function (option) { return option.value === current; })[0];
      var row = button('', 'setting-row', function () {
        optionDialog(uiLabel(field.label), choices, current, function (value) { var settings = {}; settings[field.key] = value; return query('settings.set', { settings: settings }).then(renderSettings); });
      }); row.appendChild(element('span', 'setting-label', uiLabel(field.label))); row.appendChild(element('span', 'setting-value', selected ? selected.label : t("Default"))); parent.appendChild(row);
    });
    var parental = button('', 'setting-row', parentalForm); parental.appendChild(element('span', 'setting-label', t("Parental controls"))); parental.appendChild(element('span', 'setting-value', view.parental && view.parental.enabled ? t("On") : t("Off"))); parent.appendChild(parental);
    if (view.source) parent.appendChild(button(t('Source settings') + ' · ' + sourceName(view.source), 'setting-row', function () { sourceTools(view.source); }));
    if (view.parental && view.parental.enabled) parent.appendChild(button(t(view.parental.unlocked ? 'Hide protected content' : 'Show protected content'), 'setting-row', function () {
      query(view.parental.unlocked ? 'parental.lock' : 'parental.unlock').then(function () {
        return refreshBootstrap();
      }).then(function () { return refreshParental(); }).then(function () {
        if (view.source) return query('organization.get', {sourceId:view.source.id}).then(applyEditedCatalog);
      }).then(function () { showSettings(); }).catch(report);
    }));
    if (cap('backupExport')) parent.appendChild(button(t('Export encrypted backup'), 'setting-row', function () { backupFlow(true); }));
    if (cap('backupImport')) parent.appendChild(button(t('Import encrypted backup'), 'setting-row', function () { backupFlow(false); }));
    byId('settings-pairing').hidden = !cap('pairing'); focus(parent.querySelector('button') || byId('settings-pairing'));
  }
  function connectionHelp() {
    var record = dialog(t('Help & connection'));
    record.body.appendChild(element('p', 'muted', t('TVBro sends provider requests directly from this TV.')));
    if (view.caps.requiresHttpsProvider === true) {
      record.body.appendChild(element('p', '', t('On Titan OS, this TV version requires HTTPS. HTTP provider and media addresses are blocked before a request or playback.')));
      record.body.appendChild(element('p', '', t('The provider must allow TVBro to connect from this app. Ask them to enable access for TVBro.')));
    } else record.body.appendChild(element('p', '', t('On native Samsung and LG apps, HTTP and required cookies or headers depend on the TV transport.')));
    record.body.appendChild(element('p', '', t('TVBro does not automatically rewrite provider URLs or use a generic proxy. Stalker relay is used only when explicitly configured.')));
    dialogButton(record, t('Done'), function () { closeDialog(false, record); }); focus(record.actions.firstChild);
  }
  function playerSettings() {
    var record = dialog(t("Playback settings")), list = element('div', 'dialog-list'); record.body.appendChild(list);
    if (cap('tracks')) {
      list.appendChild(button(t("Audio track"), 'button', function () { trackOptions('audio'); }));
      list.appendChild(button(t("Subtitles"), 'button', function () { trackOptions('subtitle'); }));
    }
    if (cap('rate') && !view.playingState.isLive) list.appendChild(button(t("Playback speed"), 'button', function () {
      optionDialog(t("Playback speed"), (view.caps.playbackRates || []).map(function (rate) { return { value: rate, label: rate + '×' }; }), view.playingState.speed || view.playingState.rate || 1, function (rate) { return query('player.rate', { rate: rate }); });
    }));
    if (cap('aspect')) list.appendChild(button(t("Aspect ratio"), 'button', function () {
      var nativeMode = view.playingState.displayMode, selected = nativeMode === 'PLAYER_DISPLAY_MODE_FULL_SCREEN' ? 'fill' : nativeMode === 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO' ? 'auto' : nativeMode === 'PLAYER_DISPLAY_MODE_LETTER_BOX' ? 'fit' : view.playingState.aspect;
      optionDialog(t("Aspect ratio"), (view.caps.aspectModes || []).map(function (mode) { return { value: mode.id, label: uiLabel(mode.label) }; }), selected, function (fit) { return query('player.aspect', { fit: fit }); });
    }));
    dialogButton(record, t("Back"), function () { closeDialog(true); }); focus(list.querySelector('button') || record.actions.firstChild);
  }
  function trackOptions(type) {
    query('player.tracks').then(function (tracks) {
      var rows = Array.isArray(tracks) ? tracks.filter(function (row) { return row.type === (type === 'audio' ? 'AUDIO' : 'TEXT'); }) : array(tracks[type]);
      var selected, options = rows.map(function (row) {
        var id = row.id == null ? row.index : row.id, extra = row.extraInfo || {};
        if (row.selected) selected = id;
        return { value: id, label: row.title || row.label || row.language || extra.language || extra.lang || extra.track_lang || String(id) };
      });
      if (!Array.isArray(tracks) && tracks.selected) selected = tracks.selected[type];
      if (type === 'subtitle') options.unshift({ value: 'off', label: t("Subtitles off") });
      optionDialog(type === 'audio' ? t("Audio track") : t("Subtitles"), options, selected, function (id) { return query('player.selectTrack', { type: type, id: id }); });
    }).catch(report);
  }
  function stopPairingWatch() { window.clearTimeout(pairingTimer); pairingTimer = null; }
  function schedulePairingWatch() {
    stopPairingWatch();
    if (view.screen !== 'pairing' || document.hidden || view.pairingPaired || !view.pairingCode && !view.pairingRetryAt) return;
    var request = view.pairingRequest, code = view.pairingCode;
    pairingTimer = window.setTimeout(function () {
      pairingTimer = null;
      if (request !== view.pairingRequest || view.screen !== 'pairing' || document.hidden || code !== view.pairingCode) return;
      if (view.pairingBusy || dialogs.length) { schedulePairingWatch(); return; }
      if (!code || view.pairingExpiresAt && Date.now() >= view.pairingExpiresAt) { pairingAction('start'); return; }
      query('pairing.status', { code: code }).then(function (claimed) {
        if (request !== view.pairingRequest || view.screen !== 'pairing' || document.hidden || code !== view.pairingCode) return;
        if (claimed === true) { renderPairing({ paired: true }); return chooseCloudProfile(); }
      }).catch(function (error) {
        if (request !== view.pairingRequest || view.screen !== 'pairing' || code !== view.pairingCode) return;
        view.pairingRetryAt = Number(error.retryAt) || Date.now() + 5000;
      }).then(function () {
        if (request === view.pairingRequest && view.screen === 'pairing') schedulePairingWatch();
      });
    }, Math.max(3000, view.pairingRetryAt - Date.now()));
  }
  function showPairing(onboarding, returnScreen) {
    if (!cap('pairing')) return;
    stopPairingWatch();
    ++view.pairingRequest; view.pairingOnboarding = onboarding === true;
    view.pairingReturn = returnScreen || 'settings'; view.pairingReady = false;
    view.pairingPaired = false; view.pairingBusy = false; view.pairingDownloading = false;
    view.cloudProfile = null; view.pairingCode = null; view.pairingUrl = ''; view.pairingState = {};
    view.pairingExpiresAt = 0; view.pairingRetryAt = 0; view.pairingQrLink = ''; view.pairingQrData = ''; view.pairingStage = '';
    text(byId('pairing-title'), view.pairingOnboarding ? t("Download from cloud") : t("TVBro account"));
    text(byId('pairing-profile'), ''); showScreen('pairing'); pairingAction('get');
  }
  function chooseCloudProfile() {
    if (view.pairingBusy) return Promise.resolve();
    stopPairingWatch();
    var request = ++view.pairingRequest;
    view.pairingBusy = true; view.pairingStage = t('Loading cloud profiles…'); renderPairing(view.pairingState || {}); status(view.pairingStage);
    return afterLoadingPaint().then(function () {
      if (request !== view.pairingRequest || view.screen !== 'pairing') throw cancelled();
      return query('pairing.profiles');
    }).then(function (data) {
      if (request !== view.pairingRequest || view.screen !== 'pairing') return;
      view.pairingBusy = false; status(''); renderPairing(view.pairingState || {});
      var rows = array(data);
      function selectProfile(profile, record) {
        var selected = view.pairingOnboarding ? Promise.resolve() : query('pairing.selectProfile', { profileId: profile.id });
        return selected.then(function () {
          if (request !== view.pairingRequest || view.screen !== 'pairing') return;
          view.cloudProfile = profile; view.pairingReady = false;
          text(byId('pairing-profile'), t('From panel: {profile}', { profile: profile.name })); if (record) closeDialog(false, record); renderPairing({ paired: true });
          if (view.pairingOnboarding) return pairingAction('pull');
        }).catch(function (error) { if (request === view.pairingRequest) { if (record) text(record.error, message(error, t("Could not select the profile."))); else report(error); } });
      }
      if (view.pairingOnboarding && rows.length === 1) return selectProfile(rows[0]);
      var record = dialog(t("Panel profiles"), false, function () { ++view.pairingRequest; }), list = element('div', 'dialog-list'); record.body.appendChild(list);
      rows.forEach(function (profile) { list.appendChild(button(profile.name + (profile.pinSet ? ' · PIN' : ''), 'button', function () { selectProfile(profile, record); })); });
      if (!rows.length) list.appendChild(element('p', 'muted', t("No account profiles yet. Create one in the panel, then refresh profiles.")));
      dialogButton(record, t("Back"), function () { closeDialog(true); }); focus(list.querySelector('button') || record.actions.firstChild);
    }).catch(function (error) {
      if (request !== view.pairingRequest || view.screen !== 'pairing') return;
      view.pairingBusy = false; renderPairing(view.pairingState || {}); report(error);
    });
  }
  function pairingAction(action) {
    if (view.pairingBusy) return Promise.resolve();
    if ((action === 'pull' || action === 'push') && !view.cloudProfile) { chooseCloudProfile(); return Promise.resolve(); }
    stopPairingWatch();
    var request = ++view.pairingRequest, onboarding = view.pairingOnboarding, wasWaiting = !!view.pairingCode;
    view.pairingBusy = true; view.pairingDownloading = onboarding && action === 'pull';
    view.pairingStage = action === 'pull' ? onboarding ? t('Downloading your profile…') : t('Downloading from panel…')
      : action === 'push' ? t('Uploading to panel…') : action === 'start' ? t('Generating pairing code…') : t('Checking pairing…');
    renderPairing(view.pairingState || {});
    status(view.pairingStage);
    var ready = afterLoadingPaint().then(function () {
      if (request !== view.pairingRequest || view.screen !== 'pairing') throw cancelled();
      return onboarding && action === 'pull' ? query('pairing.download', { profileId: view.cloudProfile.id })
        : action === 'check' && view.pairingCode ? query('pairing.status', { code: view.pairingCode }).then(function (claimed) { return { paired: claimed === true }; }) : query('pairing.' + (action === 'check' ? 'get' : action));
    });
    return ready.then(function (data) {
      if (request !== view.pairingRequest || view.screen !== 'pairing') return;
      view.pairingBusy = false; view.pairingDownloading = false;
      view.pairingRetryAt = 0;
      if (action === 'get' && data && data.paired === false && !view.sources.length) {
        view.pairingOnboarding = onboarding = true;
        text(byId('pairing-title'), t("Download from cloud"));
      }
      if (onboarding && action === 'pull') {
        if (!data || data.onboardingReady !== true) throw new Error(t("Waiting for a playlist. Add a source in the panel or unlock its credentials, then refresh."));
        applyBootstrap(data); view.pairingReady = true;
      }
      status(''); renderPairing(data || {});
      if (onboarding && action === 'pull') return continuePairing();
      if (!onboarding && (action === 'pull' || action === 'unpair')) return refreshBootstrap().then(function () { renderSources(); });
      if (view.pairingPaired && !view.cloudProfile && (onboarding || action === 'check' || wasWaiting)) return chooseCloudProfile();
      if (onboarding && action === 'get' && !view.pairingPaired && !view.pairingCode && !data.error) return pairingAction('start');
    }).catch(function (error) {
      if (request !== view.pairingRequest || view.screen !== 'pairing') return;
      view.pairingBusy = false; view.pairingDownloading = false;
      view.pairingRetryAt = Number(error.retryAt) || Date.now() + 5000;
      renderPairing(view.pairingState || {}); report(error);
    });
  }
  function renderPairing(data) {
    view.pairingState = data;
    if (typeof data.paired === 'boolean') view.pairingPaired = data.paired;
    else if (data.code || data.state === 'waiting') view.pairingPaired = false;
    var linked = view.pairingPaired, onboarding = view.pairingOnboarding;
    if (data.code) view.pairingCode = data.code;
    if (data.expiresAt) { var expiry = Date.parse(data.expiresAt); view.pairingExpiresAt = isNaN(expiry) ? 0 : expiry; }
    if (data.panelLink || data.panelUrl || data.url) view.pairingUrl = data.panelLink || data.panelUrl || data.url;
    if (linked) { view.pairingCode = null; view.pairingExpiresAt = 0; view.pairingUrl = ''; }
    var pairingStatus = byId('pairing-status');
    pairingStatus.className = 'muted' + (view.pairingBusy ? ' pairing-loading' : ''); pairingStatus.setAttribute('aria-busy', view.pairingBusy ? 'true' : 'false');
    text(pairingStatus, view.pairingBusy ? view.pairingStage : view.pairingReady ? t("Your profile, playlists and settings are downloaded. Continue to open your library.") : data.message ? uiLabel(data.message) : (linked ? onboarding ? t("Choose the profile you want to download.") : t("This device is paired") : view.pairingCode ? t("Enter this code in the TVBro panel, then check the connection.") : t("Pair this device")));
    text(byId('pairing-code'), view.pairingCode || ''); text(byId('pairing-url'), view.pairingUrl || '');
    if (view.pairingCode && view.pairingUrl && view.pairingQrLink !== view.pairingUrl) {
      view.pairingQrLink = view.pairingUrl; view.pairingQrData = '';
      try { if (typeof core.pairingQrDataUri === 'function') view.pairingQrData = core.pairingQrDataUri(view.pairingUrl); } catch (_) {}
    }
    var qr = byId('pairing-qr'), qrData = view.pairingCode && view.pairingQrData;
    qr.hidden = !qrData;
    if (qrData) { if (qr.getAttribute('src') !== qrData) qr.src = qrData; } else qr.removeAttribute('src');
    byId('pairing-start').hidden = linked; text(byId('pairing-start'), view.pairingCode ? t("New pairing code") : t("Generate pairing code"));
    byId('pairing-check').hidden = view.pairingReady; byId('pairing-choose-profile').hidden = !linked || view.pairingReady;
    byId('pairing-pull').hidden = !linked || view.pairingReady || onboarding && !view.cloudProfile;
    byId('pairing-continue').hidden = !onboarding || !view.pairingReady;
    byId('pairing-push').hidden = !linked || onboarding; byId('pairing-unpair').hidden = !linked || onboarding;
    var controls = byId('pairing-view').querySelectorAll('button');
    for (var i = 0; i < controls.length; i++) controls[i].disabled = view.pairingBusy && (controls[i].id !== 'pairing-back' || view.pairingDownloading);
    if (data.error) status(uiLabel(data.error), true);
    if (!view.pairingBusy) focus(view.pairingReady ? byId('pairing-continue') : linked ? view.cloudProfile ? byId('pairing-pull') : byId('pairing-choose-profile') : view.pairingCode ? byId('pairing-check') : byId('pairing-start'));
    schedulePairingWatch();
  }
  function leavePairing() {
    if (view.pairingDownloading) { status(t("Downloading your profile…")); return; }
    stopPairingWatch();
    var target = view.pairingReady ? 'profiles' : view.pairingReturn;
    ++view.pairingRequest; view.pairingBusy = false; view.pairingOnboarding = false; view.pairingReady = false;
    if (target === 'profiles') showProfiles(); else if (target === 'setup' && view.profile && !view.sources.length) showSetup(); else showSettings();
  }
  function continuePairing() {
    if (!view.pairingReady || view.pairingBusy) return;
    var request = ++view.pairingRequest;
    view.pairingBusy = true; view.pairingStage = t('Preparing your library…'); renderPairing(view.pairingState || {}); status(view.pairingStage);
    return afterLoadingPaint().then(function () {
      if (request !== view.pairingRequest || view.screen !== 'pairing') throw cancelled();
      return refreshBootstrap();
    }).then(function () {
      if (request !== view.pairingRequest || view.screen !== 'pairing') return;
      view.pairingBusy = false;
      var config = view.sources.filter(function (row) { return row.id === view.activeSourceId; })[0] || view.sources[0];
      if (!config) throw new Error(t("This profile has no usable playlists."));
      view.pairingOnboarding = false; view.pairingReady = false; showSources(); return loadSource(config);
    }).catch(function (error) {
      if (request !== view.pairingRequest || view.screen !== 'pairing') return;
      view.pairingBusy = false; renderPairing(view.pairingState || {}); report(error);
    });
  }
  function move(key) {
    var active = document.activeElement;
    if (moveSeries(key, active)) return;
    if (moveDetails(key, active)) return;
    if (moveGuideRow(key, active)) return;
    var root = dialogs.length ? dialogs[dialogs.length - 1].node : view.player ? byId('player-chrome') : byId('app-shell');
    var nodes = root.querySelectorAll('[data-nav]');
    // The TV action row can wrap with translated labels. Left/right must still
    // reach every action in reading order, including the next visual row.
    if (!dialogs.length && view.player && (key === 37 || key === 39)) {
      var controls = root.querySelector('.player-controls');
      if (controls && controls.contains(active)) {
        var actions = Array.prototype.filter.call(controls.querySelectorAll('[data-nav]'), visible);
        var actionIndex = actions.indexOf(active), nextIndex = actionIndex + (key === 37 ? -1 : 1);
        if (actionIndex >= 0) { if (nextIndex >= 0 && nextIndex < actions.length) focus(actions[nextIndex]); return; }
      }
    }
    if (!active || !visible(active) || !root.contains(active)) { for (var first = 0; first < nodes.length; first++) if (visible(nodes[first])) { focus(nodes[first]); break; } return; }
    var origin = active.getBoundingClientRect(), best = null, score = Infinity;
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]; if (node === active || !visible(node)) continue;
      var rect = node.getBoundingClientRect(), dx = (rect.left + rect.right - origin.left - origin.right) / 2, dy = (rect.top + rect.bottom - origin.top - origin.bottom) / 2;
      var primary = key === 37 ? -dx : key === 39 ? dx : key === 38 ? -dy : dy;
      var secondary = key === 37 || key === 39 ? Math.abs(dy) : Math.abs(dx), next = primary + secondary * 3;
      if (primary > 2 && next < score) { best = node; score = next; }
    } focus(best);
  }
  function moveGuideRow(key, active) {
    if (dialogs.length || view.player || view.screen !== 'catalog' || !usesLiveGuide() || key !== 38 && key !== 40) return false;
    var grid = byId('guide-grid');
    if (!active || !grid.contains(active) || active.getAttribute('data-guide-index') === null) return false;
    var index = Number(active.getAttribute('data-guide-index')) + (key === 38 ? -1 : 1);
    if (index < 0) return false;
    if (index >= view.filtered.length) return true;
    var channel = view.filtered[index], record = guideRenderState && guideRenderState.records[String(channel.id)];
    if (!record || record.index !== index) {
      view.guideStartIndex = Math.max(0, Math.min(Math.max(0, view.filtered.length - guideWindowSize), index - 6));
      var channels = view.filtered.slice(view.guideStartIndex, view.guideStartIndex + guideWindowSize);
      renderGuide(channels, cachedGuideProgrammes(channels), view.guideFrom, view.guideFrom + 2 * 3600000);
      record = guideRenderState.records[String(channel.id)];
    }
    var target = record.row.firstChild;
    if ((' ' + active.className + ' ').indexOf(' guide-channel ') < 0) {
      var origin = active.getBoundingClientRect(), center = (origin.left + origin.right) / 2, distance = Infinity;
      var programmes = record.timeline.querySelectorAll('.guide-programme');
      for (var i = 0; i < programmes.length; i++) {
        var rect = programmes[i].getBoundingClientRect(), delta = Math.abs((rect.left + rect.right) / 2 - center);
        if (delta < distance) { target = programmes[i]; distance = delta; }
      }
    }
    focus(target); return true;
  }
  function endEditing(input) { input.readOnly = true; input.classList.remove('is-editing'); input.blur(); focus(input); }
  function clearMediaSearch() { window.clearTimeout(mediaSearchTimer); mediaSearchTimer = null; byId('media-search').value = ''; view.mediaPage = 1; view.mediaSlice = 0; if (view.mediaKind === 'favorites') renderFavoriteItems(); else fetchMedia(); focus(byId('media-search')); }
  function back() {
    stopSeekHold();
    if (dialogs.length) { closeDialog(true); return; }
    if (view.screen === 'language') { leaveLanguage(); return; }
    if (view.screen === 'pairing') { leavePairing(); return; }
    if (view.profileSelecting) {
      ++view.request; profileSelectionBusy(false); status('');
      var cancelledRequest = view.request;
      query('sources.cancel').catch(function (error) { if (cancelledRequest === view.request && view.screen === 'profiles') report(error); }); return;
    }
    if (view.busy) {
      ++view.request; ++view.playbackRequest; busy(false);
      var request = view.request; showSources();
      query('sources.cancel').then(function () { return query('sources.list'); }).then(function (sources) {
        if (request === view.request && view.screen === 'sources') { view.sources = array(sources); renderSources(); }
      }).catch(function (error) { if (request === view.request) report(error); }); return;
    }
    if (view.player) { if (playerZapPending || playerZapDigits) cancelPlayerZap(); else if (!view.playerReady) returnFromPlayer(); else if (view.chrome) showChrome(false); else returnFromPlayer(); return; }
    if (view.screen === 'catalog' && byId('channel-search').value) { window.clearTimeout(searchTimer); searchTimer = null; byId('channel-search').value = ''; view.page = 0; renderChannels(); focus(byId('channel-search')); return; }
    if (view.screen === 'media' && byId('media-search').value) { clearMediaSearch(); return; }
    if (view.screen === 'catalog' || view.screen === 'media') { showHome(); return; }
    if (view.screen === 'settings') { if (view.source) showHome(); else showSources(); return; }
    if (view.screen === 'sources' && view.editSource) { cancelSourceEdit(); focus(byId('kind-' + view.kind)); return; }
    if (view.screen === 'sources' && view.sourceSetup) { showSetup(); return; }
    if (view.screen === 'setup') { showProfiles(); return; }
    if (view.screen === 'profiles' && view.manageProfiles) { view.manageProfiles = false; renderProfiles(); focus(byId('manage-profiles')); return; }
    requestExit();
  }
  function onKey(event) {
    var key = event.keyCode || event.which, active = document.activeElement;
    if (typeof window !== 'undefined' && window.TVBroPlatformAdapters && typeof window.TVBroPlatformAdapters.normalizeKey === 'function') key = window.TVBroPlatformAdapters.normalizeKey(key);
    if (seekHold && seekHold.key !== key) stopSeekHold();
    var editable = active && active.hasAttribute && active.hasAttribute('data-editable'), isBack = key === 10009 || key === 27 || key === 8;
    if (editable && !active.readOnly) { if (key === 13 || key === 65376 || isBack && key !== 8) { event.preventDefault(); endEditing(active); } return; }
    if (isBack) {
      event.preventDefault();
      if (!dialogs.length && view.player && scrub) { cancelScrub(); return; }
      back(); return;
    }
    if (!dialogs.length && view.player && view.chrome && active === byId('player-progress-track') && !active.disabled) {
      if (key === 37 || key === 39) { event.preventDefault(); adjustScrub(key === 37 ? -10 : 10); return; }
      if (key === 13 || key === 65376) { event.preventDefault(); if (!event.repeat) commitScrub(); return; }
    }
    if (!dialogs.length && view.player && key === 457) { event.preventDefault(); if (!event.repeat) { showChrome(true); focus(byId('play-pause')); } return; }
    if (view.player && playerChannels().length && (key === 458 || key === 10073) && (!dialogs.length || dialogs[dialogs.length - 1].playerChannels)) {
      event.preventDefault(); if (!event.repeat) { if (dialogs.length) closeDialog(true); else openPlayerChannels(); } return;
    }
    if (!dialogs.length && view.player && playerChannels().length && key === 10190) { event.preventDefault(); if (!event.repeat) previousPlayerChannel(); return; }
    if (!dialogs.length && view.player && playerChannels().length && (key >= 48 && key <= 57 || key >= 96 && key <= 105)) {
      event.preventDefault(); if (!event.repeat) zapDigit(key >= 96 ? key - 96 : key - 48); return;
    }
    if (!dialogs.length && view.player && view.channel && view.playingState.isLive && (key === 427 || key === 428 || key === 33 || key === 34)) {
      event.preventDefault(); zap(key === 427 || key === 33 ? 1 : -1); return;
    }
    if (!dialogs.length && view.player && (key === 10252 || key === 415 || key === 19)) {
      event.preventDefault(); var playing = platform.getState().playing;
      if (key === 10252 || key === 415 && !playing || key === 19 && playing) control(playPause); return;
    }
    if (!dialogs.length && view.player && key === 413) { event.preventDefault(); stopPlayback(true); return; }
    if (!dialogs.length && view.player && (key === 412 || key === 417)) { event.preventDefault(); if (!event.repeat) startSeekHold(key, key === 412 ? -10 : 10); return; }
    if (key === 13 || key === 65376) {
      if (!dialogs.length && view.player && (playerZapPending || playerZapDigits)) { event.preventDefault(); if (!event.repeat) commitZap(); return; }
      event.preventDefault(); if (!dialogs.length && view.player && !view.chrome) { showChrome(true); focus(byId('play-pause')); return; }
      if (!dialogs.length && view.player && view.chrome && visible(active) && (active === byId('seek-back') || active === byId('seek-forward'))) {
        if (!event.repeat) startSeekHold(key, active === byId('seek-back') ? -10 : 10); return;
      }
      if (editable) { active.blur(); active.readOnly = false; active.classList.add('is-editing'); active.focus(); return; }
      if (visible(active) && active.click) active.click(); return;
    }
    if (key >= 37 && key <= 40) {
      event.preventDefault();
      if (!dialogs.length && view.player && !view.chrome) {
        if (playerChannels().length) {
          if (key === 38 || key === 40) zap(key === 38 ? 1 : -1);
          else if (!event.repeat) { if (key === 37) openPlayerChannels(); else previousPlayerChannel(); }
        } else if (key === 37 || key === 39) { if (!event.repeat) startSeekHold(key, key === 37 ? -10 : 10); }
        else { showChrome(true); focus(byId('play-pause')); }
      }
      else { if (view.player && !dialogs.length) showChrome(true); move(key); }
    }
    if (key === 9 && dialogs.length) {
      var nodes = dialogs[dialogs.length - 1].node.querySelectorAll('[data-nav]'), candidates = [];
      for (var i = 0; i < nodes.length; i++) if (visible(nodes[i])) candidates.push(nodes[i]);
      event.preventDefault(); if (candidates.length) focus(candidates[(candidates.indexOf(active) + (event.shiftKey ? -1 : 1) + candidates.length) % candidates.length]);
    }
  }
  function bind(id, action) { byId(id).addEventListener('click', action); }
  captureStaticUi(document.body); applyUiLanguage('en');
  byId('brand-logo').addEventListener('error', function () { this.hidden = true; }); byId('pairing-qr').addEventListener('error', function () { this.hidden = true; });
  document.addEventListener('keydown', onKey);
  document.addEventListener('keyup', onKeyUp);
  window.addEventListener('blur', stopSeekHold);
  ['keydown', 'keyup', 'focusin', 'input', 'pointerdown', 'pointerup', 'pointermove', 'mousedown', 'mouseup', 'mousemove', 'touchstart', 'touchend', 'wheel'].forEach(function (name) {
    document.addEventListener(name, resetPreviewIdleTimer, true);
  });
  document.addEventListener('scroll', scheduleArtwork, true); document.addEventListener('focusin', scheduleArtwork);
  document.addEventListener('visibilitychange', function () {
    stopPairingWatch();
    if (document.hidden) { stopSeekHold(); cancelPlayerZap(); window.clearTimeout(channelNowNextTimer); channelNowNextTimer = null; }
    resetPreviewIdleTimer();
    if (!document.hidden) scheduleArtwork();
    if (!document.hidden && view.screen === 'pairing' && !view.pairingBusy && !dialogs.length) pairingAction('get');
  });
  window.addEventListener('pagehide', function () { stopPairingWatch(); cancelPreviewIdleTimer(); cancelPlayerZap(); window.clearTimeout(channelNowNextTimer); channelNowNextTimer = null; });
  document.addEventListener('blur', function (event) { if (event.target.hasAttribute && event.target.hasAttribute('data-editable')) { event.target.readOnly = true; event.target.classList.remove('is-editing'); } }, true);
  bind('show-home', showHome); bind('show-sources', showSources); bind('show-settings', showSettings);
  bind('language-continue', function () { saveLanguage(uiLanguage); }); bind('language-back', leaveLanguage);
  bind('show-profiles', function () { query('profiles.list').then(function (data) { view.profiles = array(data.profiles); view.profile = data.profile; showProfiles(); }).catch(report); });
  bind('add-profile', function () { profileForm(null); }); bind('manage-profiles', function () { view.manageProfiles = !view.manageProfiles; renderProfiles(); focus(byId('profile-list').querySelector('button')); });
  bind('download-cloud', function () { showPairing(true, 'profiles'); });
  bind('setup-source', function () { showSources(true); }); bind('setup-cloud', function () { showPairing(true, 'setup'); });
  bind('setup-demo', useDemo); bind('setup-back', showProfiles);
  bind('skip-profile', function () { if (view.profile) selectExistingProfile(view.profile); });
  ['m3u', 'xtream', 'stalker'].forEach(function (kind) { bind('kind-' + kind, function () { view.kind = kind; renderFields(); focus(byId('source-label')); }); });
  bind('cancel-source-edit', function () { cancelSourceEdit(); focus(byId('kind-' + view.kind)); });
  ['live', 'movie', 'series', 'favorites'].forEach(function (kind) { bind('home-' + kind, function () { if (kind === 'live') showLive(); else showMedia(kind); }); });
  bind('previous-page', function () { page(-1); }); bind('next-page', function () { page(1); });
  byId('channel-search').addEventListener('input', function () { window.clearTimeout(searchTimer); var request = view.request; searchTimer = window.setTimeout(function () { searchTimer = null; if (request !== view.request || view.screen !== 'catalog') return; view.page = 0; renderChannels(); }, 180); });
  bind('clear-channel-search', function () { window.clearTimeout(searchTimer); searchTimer = null; byId('channel-search').value = ''; view.page = 0; focus(byId('channel-search')); renderChannels(); });
  byId('media-search').addEventListener('input', function () { window.clearTimeout(mediaSearchTimer); var request = view.request, kind = view.mediaKind; mediaSearchTimer = window.setTimeout(function () { mediaSearchTimer = null; if (request !== view.request || kind !== view.mediaKind || view.screen !== 'media') return; view.mediaPage = 1; view.mediaSlice = 0; if (view.mediaKind === 'favorites') renderFavoriteItems(); else fetchMedia(); }, 250); });
  bind('clear-media-search', clearMediaSearch); bind('media-previous', function () { mediaPage(-1); }); bind('media-next', function () { mediaPage(1); });
  byId('media-view').querySelector('.media-panel').addEventListener('scroll', scheduleSeriesScroll);
  byId('media-items').addEventListener('focusin', scheduleSeriesScroll); bind('media-retry', loadSeriesMore);
  bind('return-catalog', returnFromPlayer); bind('stop-player', function () { stopPlayback(true); }); bind('play-pause', function () { control(playPause); });
  bind('seek-back', function () { seek(-10); }); bind('seek-forward', function () { seek(10); });
  bind('player-progress-track', seekBarClick);
  bind('hide-player-controls', function () { stopSeekHold(); showChrome(false); });
  bind('previous-episode', function () { changeEpisode(-1); }); bind('next-episode', function () { changeEpisode(1); });
  bind('player-favorite', function () { toggleFavorite({ channel: view.channel || undefined, item: view.item || undefined, sourceId: view.sourceId }); });
  bind('player-settings', playerSettings); bind('player-episodes', function () { if (view.episodes) showChildren(view.episodes.parent, view.episodes.sourceId); });
  bind('player-channels', openPlayerChannels); bind('player-previous', previousPlayerChannel);
  bind('player-audio', function () { trackOptions('audio'); }); bind('player-subtitles', function () { trackOptions('subtitle'); });
  bind('show-guide', showGuide); bind('guide-search', searchProgrammes); bind('guide-earlier', function () { view.guideFrom -= 3600000; fetchGuide(); }); bind('guide-later', function () { view.guideFrom += 3600000; fetchGuide(); });
  bind('live-lock-category', function () { parentalToggle('category', view.category, 'live'); }); bind('live-lock-channel', function () { if (view.channel) parentalToggle('channel', view.channel.id, 'live'); }); bind('media-lock-category', function () { parentalToggle('category', view.mediaCategory, view.mediaKind); });
  bind('guide-now', function () { view.guideFrom = Date.now() - Date.now() % 1800000; fetchGuide(); });
  byId('guide-grid').addEventListener('scroll', onGuideScroll);
  byId('channel-list').addEventListener('scroll', onChannelListScroll);
  bind('settings-pairing', function () { showPairing(false, 'settings'); }); bind('pairing-choose-profile', chooseCloudProfile);
  bind('pairing-continue', continuePairing); bind('pairing-back', leavePairing); ['start', 'check', 'pull', 'push', 'unpair'].forEach(function (action) {
    bind('pairing-' + action, function () { if (action === 'unpair') confirmAction(t("Unpair this device?"), t("Downloaded sources and favorites will stay on this TV."), function () { return query('pairing.unpair').then(function (data) { view.pairingCode = null; view.cloudProfile = null; text(byId('pairing-profile'), ''); renderPairing(data || {}); return refreshBootstrap(); }); }); else pairingAction(action); });
  });
  byId('source-form').addEventListener('submit', function (event) {
    event.preventDefault(); if (view.busy) return;
    var request = ++view.request, profileId = view.profile && view.profile.id;
    var config = { kind: view.kind, label: byId('source-label').value, fields: {}, settings: {} };
    if (view.editSource) config.id = view.editSource.id;
    Object.keys(fieldInputs).forEach(function (key) { config.fields[key] = fieldInputs[key].value; });
    busy(true); status(t("Saving source…"));
    query(view.editSource ? 'sources.update' : 'sources.add', { config: config }).then(function (sources) {
      if (request !== view.request) { if (view.profile && view.profile.id === profileId && view.screen === 'sources') { view.sources = array(sources); renderSources(); } return; }
      view.sources = array(sources); view.sourceSetup = false; cancelSourceEdit(); renderSources(); busy(false);
      var saved = config.id ? view.sources.filter(function (row) { return row.id === config.id; })[0] : view.sources[view.sources.length - 1]; if (saved) return loadSource(saved);
    }).catch(function (error) { if (request === view.request) { busy(false); report(error, t("Could not save the source.")); } });
  });
  window.addEventListener('resize', function () { scheduleArtwork(); if (seriesList) seriesList.layout = null; scheduleSeriesScroll(); var rect = view.player && view.playerReady ? fullRect() : view.preview ? previewRect() : null; if (rect) { nativeRect(rect); query('player.rect', { rect: rect }).catch(report); } });
  if (!platform || typeof platform.query !== 'function' || !validation || !validation.KIND_FIELDS) { busy(true); status(t("Could not start the app."), true); return; }
  busy(true); status(t("Starting TVBro…")); platform.onState(updatePlayer); updatePlayer(platform.getState());
  refreshBootstrap().then(function () { busy(false); if (!view.languageSelected) showLanguage(false); else routeAfterLanguage(); }).catch(function (error) { busy(false); status(bootFailureMessage(error), true); });
}());
