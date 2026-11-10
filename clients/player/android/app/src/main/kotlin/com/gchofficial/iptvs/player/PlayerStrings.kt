package com.gchofficial.iptvs.player

import java.util.Locale

object PlayerStrings {
    var language: String = "en"

    val locale: Locale
        get() = if (language == "pl") Locale.forLanguageTag("pl-PL") else Locale.ENGLISH

    val polish = mapOf(
        "Back" to "Wstecz",
        "Timeshift on" to "Timeshift włączony",
        "Timeshift" to "Timeshift",
        "Start local timeshift" to "Włącz lokalne buforowanie na żywo",
        "Stop recording" to "Zatrzymaj nagrywanie",
        "Record" to "Nagrywaj",
        "Toggle recording" to "Włącz lub wyłącz nagrywanie",
        "Play/Pause" to "Odtwórz lub wstrzymaj",
        "Back 10s" to "Cofnij o 10 s",
        "Forward 10s" to "Przewiń o 10 s",
        "Previous episode" to "Poprzedni odcinek",
        "Next episode" to "Następny odcinek",
        "Could not play stream. Go back or choose an episode to retry." to "Nie można odtworzyć strumienia. Wróć lub wybierz odcinek, aby spróbować ponownie.",
        "The stream could not be started. Try again; if the problem persists, contact your provider." to "Nie udało się uruchomić strumienia. Spróbuj ponownie; jeśli problem się powtarza, skontaktuj się z dostawcą.",
        "The connection to the stream was lost. Automatic reconnection failed. Check your connection and try again." to "Utracono połączenie ze strumieniem. Automatyczne ponowne połączenie nie powiodło się. Sprawdź połączenie i spróbuj ponownie.",
        "The provider rejected access (HTTP {status}). Check your account or subscription with your provider." to "Dostawca odmówił dostępu (HTTP {status}). Sprawdź u dostawcy konto lub abonament.",
        "The provider could not find this stream (HTTP {status}). Try another channel or contact your provider." to "Dostawca nie znalazł tego strumienia (HTTP {status}). Spróbuj innego kanału lub skontaktuj się z dostawcą.",
        "The provider is limiting requests (HTTP {status}). Wait a few minutes before trying again." to "Dostawca ogranicza liczbę żądań (HTTP {status}). Poczekaj kilka minut przed ponowną próbą.",
        "The provider returned an error (HTTP {status}). Try again later or contact your provider." to "Dostawca zwrócił błąd (HTTP {status}). Spróbuj później lub skontaktuj się z dostawcą.",
        "The provider address could not be found. Check your connection and the source address." to "Nie znaleziono adresu dostawcy. Sprawdź połączenie i adres źródła.",
        "The provider did not respond in time. Check your connection and try again." to "Dostawca nie odpowiedział na czas. Sprawdź połączenie i spróbuj ponownie.",
        "A secure connection to the provider could not be established. Check the device date and the source HTTPS address." to "Nie udało się nawiązać bezpiecznego połączenia z dostawcą. Sprawdź datę urządzenia i adres HTTPS źródła.",
        "The provider refused the connection. Check the source address and port, or try another network." to "Dostawca odrzucił połączenie. Sprawdź adres i port źródła lub spróbuj w innej sieci.",
        "The connection to the provider was interrupted. Check your connection and try again." to "Połączenie z dostawcą zostało przerwane. Sprawdź połączenie i spróbuj ponownie.",
        "Episodes" to "Odcinki",
        "Close episodes" to "Zamknij odcinki",
        "Now playing" to "Teraz odtwarzane",
        "Mute" to "Wycisz",
        "Channel list" to "Lista kanałów",
        "Go to live" to "Przejdź na żywo",
        "Remove from favorites" to "Usuń z ulubionych",
        "Add to favorites" to "Dodaj do ulubionych",
        "Playback speed" to "Szybkość odtwarzania",
        "Audio track" to "Ścieżka dźwiękowa",
        "Subtitles" to "Napisy",
        "Aspect ratio" to "Proporcje obrazu",
        "Picture in picture" to "Obraz w obrazie",
        "Playback settings" to "Ustawienia odtwarzania",
        "Stream info" to "Informacje o strumieniu",
        "Audio is still playing." to "Dźwięk jest nadal odtwarzany.",
        "Reconnecting…" to "Ponowne łączenie…",
        "Loading stream…" to "Ładowanie strumienia…",
        "Buffering…" to "Buforowanie strumienia…",
        "Seeking…" to "Wczytywanie po przewinięciu…",
        "LIVE" to "NA ŻYWO",
        "Next" to "Następnie",
        "Audio" to "Dźwięk",
        "Subtitle" to "Napisy",
        "Off" to "Wyłączone",
        "Fit" to "Dopasuj",
        "Fill" to "Wypełnij",
        "Stretch" to "Rozciągnij",
        "Resolution" to "Rozdzielczość",
        "Frame rate" to "Liczba klatek na sekundę",
        "Dynamic range" to "Zakres dynamiki",
        "Video" to "Obraz",
        "fps" to "kl./s",
        "ch" to " kan.",
    )
}

fun playerText(english: String): String =
    if (PlayerStrings.language == "pl") PlayerStrings.polish[english] ?: english else english
