import Foundation

enum PlayerStrings {
  private(set) static var language = "en"

  static var locale: Locale {
    Locale(identifier: language == "pl" ? "pl_PL" : "en_US_POSIX")
  }

  static func setLanguage(_ value: String?) {
    language = value == "pl" ? "pl" : "en"
  }

  static func text(_ english: String, _ parameters: [String: String] = [:]) -> String {
    var message = language == "pl" ? polish[english] ?? english : english
    guard !parameters.isEmpty else { return message }
    guard let placeholders = try? NSRegularExpression(pattern: "\\{(\\w+)\\}") else {
      return message
    }
    let matches = placeholders.matches(in: message, range: NSRange(message.startIndex..., in: message))
    for match in matches.reversed() {
      guard let range = Range(match.range, in: message),
        let nameRange = Range(match.range(at: 1), in: message),
        let value = parameters[String(message[nameRange])]
      else { continue }
      message.replaceSubrange(range, with: value)
    }
    return message
  }

  private static let polish: [String: String] = [
    "Close player": "Zamknij odtwarzacz",
    "Close": "Zamknij",
    "Play": "Odtwórz",
    "Pause": "Pauza",
    "Back 10 seconds": "Cofnij o 10 sekund",
    "Forward 10 seconds": "Przewiń o 10 sekund",
    "Previous episode": "Poprzedni odcinek",
    "Next episode": "Następny odcinek",
    "Episodes": "Odcinki",
    "Close episodes": "Zamknij odcinki",
    "Mute": "Wycisz",
    "Unmute": "Włącz dźwięk",
    "Go to live": "Przejdź na żywo",
    "Channel list": "Lista kanałów",
    "Channels": "Kanały",
    "Previous channel": "Poprzedni kanał",
    "Next channel": "Następny kanał",
    "Nothing here": "Brak elementów",
    "Open schedule": "Otwórz program",
    "Timeshift": "Pauza na żywo",
    "Start local timeshift": "Włącz lokalne przesunięcie",
    "Record": "Nagrywaj",
    "Stop recording": "Zatrzymaj nagrywanie",
    "Toggle recording": "Przełącz nagrywanie",
    "Return to the live edge": "Wróć do bieżącej transmisji",
    "Add to favorites": "Dodaj do ulubionych",
    "Remove from favorites": "Usuń z ulubionych",
    "Fav": "Ulub.",
    "Unfav": "Usuń",
    "Playback speed": "Prędkość odtwarzania",
    "Playback settings": "Ustawienia odtwarzania",
    "Settings": "Ustawienia",
    "Audio track": "Ścieżka dźwiękowa",
    "Audio": "Dźwięk",
    "Subtitles": "Napisy",
    "Off": "Wyłączone",
    "Aspect ratio": "Proporcje obrazu",
    "Fit": "Dopasuj",
    "Fill": "Wypełnij",
    "Stretch": "Rozciągnij",
    "Picture in picture": "Obraz w obrazie",
    "Stream info": "Informacje o strumieniu",
    "Info": "Informacje",
    "Reconnecting…": "Ponowne łączenie…",
    "Loading stream…": "Ładowanie strumienia…",
    "Buffering…": "Buforowanie…",
    "Seeking…": "Wczytywanie po przewinięciu…",
    "LIVE": "NA ŻYWO",
    "Resolution": "Rozdzielczość",
    "Frame rate": "Liczba klatek",
    "Dynamic range": "Zakres dynamiki",
    "Video": "Obraz",
    "Next · {range} · {title}": "Następnie · {range} · {title}",
    "Track {number}": "Ścieżka {number}",
    "Back": "Wstecz",
    "Retry": "Spróbuj ponownie",
    "Seek": "Przewiń",
    "Playback stopped and couldn't be resumed.": "Odtwarzanie zostało przerwane i nie można go wznowić.",
    "Couldn't play this stream.": "Nie udało się odtworzyć tego strumienia.",
  ]
}
