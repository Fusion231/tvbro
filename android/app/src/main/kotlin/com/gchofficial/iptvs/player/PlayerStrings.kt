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
