/// Which language a track is in, from whatever the source said about it.
///
/// Sources describe a track's language every way there is: ISO 639-1 (`en`),
/// ISO 639-2 in both its forms (`ger`, `deu`), a region on either (`pt-BR`),
/// or only a name - libVLC names a subtitle track `Track 1 - [English]` and
/// leaves its language field empty on Android. Choosing a track in the
/// viewer's language needs all of them to mean the same thing.
library;

/// A language: its ISO 639-1 code, the other codes sources use for it - ISO
/// 639-2 in both forms, retired ones, OpenSubtitles' own - and its English name,
/// with the names it goes by in its own script where releases use them.
typedef _Language = ({
  String code,
  List<String> codes,
  String name,
  List<String> aliases,
});

/// The languages streams are realistically in, and every language the app
/// itself is translated into.
///
/// Not complete on purpose: an unknown code is shown as the source gave it,
/// which is honest, whereas a half-remembered mapping is not.
const List<_Language> _languages = [
  (code: 'af', codes: ['afr'], name: 'Afrikaans', aliases: []),
  (code: 'am', codes: ['amh'], name: 'Amharic', aliases: []),
  (code: 'ar', codes: ['ara'], name: 'Arabic', aliases: ['العربية']),
  (code: 'as', codes: ['asm'], name: 'Assamese', aliases: []),
  (code: 'az', codes: ['aze'], name: 'Azerbaijani', aliases: []),
  (code: 'be', codes: ['bel'], name: 'Belarusian', aliases: []),
  (code: 'bg', codes: ['bul'], name: 'Bulgarian', aliases: []),
  (code: 'bn', codes: ['ben'], name: 'Bengali', aliases: ['bangla']),
  (code: 'bs', codes: ['bos'], name: 'Bosnian', aliases: []),
  (code: 'ca', codes: ['cat'], name: 'Catalan', aliases: []),
  (code: 'cs', codes: ['cze', 'ces'], name: 'Czech', aliases: []),
  (code: 'da', codes: ['dan'], name: 'Danish', aliases: ['dansk']),
  (code: 'de', codes: ['ger', 'deu'], name: 'German', aliases: ['deutsch']),
  (code: 'el', codes: ['gre', 'ell'], name: 'Greek', aliases: []),
  (code: 'en', codes: ['eng'], name: 'English', aliases: []),
  (
    code: 'es',
    codes: ['spa', 'spl'],
    name: 'Spanish',
    aliases: ['español', 'espanol', 'castellano'],
  ),
  (code: 'et', codes: ['est'], name: 'Estonian', aliases: []),
  (code: 'eu', codes: ['baq', 'eus'], name: 'Basque', aliases: []),
  (code: 'fa', codes: ['per', 'fas'], name: 'Persian', aliases: ['farsi']),
  (code: 'fi', codes: ['fin'], name: 'Finnish', aliases: ['suomi']),
  (
    code: 'fil',
    codes: ['fil', 'tgl', 'tl'],
    name: 'Filipino',
    aliases: ['tagalog'],
  ),
  (
    code: 'fr',
    codes: ['fre', 'fra'],
    name: 'French',
    aliases: ['français', 'francais'],
  ),
  (code: 'gl', codes: ['glg'], name: 'Galician', aliases: []),
  (code: 'gu', codes: ['guj'], name: 'Gujarati', aliases: []),
  (code: 'he', codes: ['heb', 'iw'], name: 'Hebrew', aliases: ['עברית']),
  (code: 'hi', codes: ['hin'], name: 'Hindi', aliases: ['हिन्दी', 'हिंदी']),
  (code: 'hr', codes: ['hrv'], name: 'Croatian', aliases: ['hrvatski']),
  (code: 'hu', codes: ['hun'], name: 'Hungarian', aliases: ['magyar']),
  (code: 'hy', codes: ['arm', 'hye'], name: 'Armenian', aliases: []),
  (code: 'id', codes: ['ind', 'in'], name: 'Indonesian', aliases: ['bahasa']),
  (code: 'is', codes: ['ice', 'isl'], name: 'Icelandic', aliases: []),
  (code: 'it', codes: ['ita'], name: 'Italian', aliases: ['italiano']),
  (code: 'ja', codes: ['jpn'], name: 'Japanese', aliases: ['日本語']),
  (code: 'ka', codes: ['geo', 'kat'], name: 'Georgian', aliases: []),
  (code: 'kk', codes: ['kaz'], name: 'Kazakh', aliases: []),
  (code: 'km', codes: ['khm'], name: 'Khmer', aliases: []),
  (code: 'kn', codes: ['kan'], name: 'Kannada', aliases: []),
  (code: 'ko', codes: ['kor'], name: 'Korean', aliases: ['한국어']),
  (code: 'lo', codes: ['lao'], name: 'Lao', aliases: []),
  (code: 'lt', codes: ['lit'], name: 'Lithuanian', aliases: []),
  (code: 'lv', codes: ['lav'], name: 'Latvian', aliases: []),
  (code: 'mk', codes: ['mac', 'mkd'], name: 'Macedonian', aliases: []),
  (code: 'ml', codes: ['mal'], name: 'Malayalam', aliases: []),
  (code: 'mn', codes: ['mon'], name: 'Mongolian', aliases: []),
  (code: 'mr', codes: ['mar'], name: 'Marathi', aliases: []),
  (code: 'ms', codes: ['may', 'msa'], name: 'Malay', aliases: ['melayu']),
  (code: 'my', codes: ['bur', 'mya'], name: 'Burmese', aliases: []),
  (code: 'nb', codes: ['nob'], name: 'Norwegian Bokmål', aliases: []),
  (code: 'ne', codes: ['nep'], name: 'Nepali', aliases: []),
  (
    code: 'nl',
    codes: ['dut', 'nld'],
    name: 'Dutch',
    aliases: ['nederlands', 'flemish'],
  ),
  (code: 'no', codes: ['nor'], name: 'Norwegian', aliases: ['norsk']),
  (code: 'pa', codes: ['pan'], name: 'Punjabi', aliases: []),
  (code: 'pl', codes: ['pol'], name: 'Polish', aliases: ['polski']),
  (code: 'ps', codes: ['pus'], name: 'Pashto', aliases: []),
  (
    code: 'pt',
    codes: ['por', 'pob'],
    name: 'Portuguese',
    aliases: ['português', 'portugues'],
  ),
  (
    code: 'ro',
    codes: ['rum', 'ron'],
    name: 'Romanian',
    aliases: ['română', 'romana'],
  ),
  (code: 'ru', codes: ['rus'], name: 'Russian', aliases: ['русский']),
  (code: 'si', codes: ['sin'], name: 'Sinhala', aliases: []),
  (code: 'sk', codes: ['slo', 'slk'], name: 'Slovak', aliases: []),
  (code: 'sl', codes: ['slv'], name: 'Slovenian', aliases: []),
  (code: 'sq', codes: ['alb', 'sqi'], name: 'Albanian', aliases: []),
  (code: 'sr', codes: ['srp', 'scc'], name: 'Serbian', aliases: ['srpski']),
  (code: 'sv', codes: ['swe'], name: 'Swedish', aliases: ['svenska']),
  (code: 'sw', codes: ['swa'], name: 'Swahili', aliases: []),
  (code: 'ta', codes: ['tam'], name: 'Tamil', aliases: ['தமிழ்']),
  (code: 'te', codes: ['tel'], name: 'Telugu', aliases: ['తెలుగు']),
  (code: 'th', codes: ['tha'], name: 'Thai', aliases: ['ไทย']),
  (code: 'tr', codes: ['tur'], name: 'Turkish', aliases: ['türkçe', 'turkce']),
  (code: 'uk', codes: ['ukr'], name: 'Ukrainian', aliases: ['українська']),
  (code: 'ur', codes: ['urd'], name: 'Urdu', aliases: ['اردو']),
  (code: 'uz', codes: ['uzb'], name: 'Uzbek', aliases: []),
  (code: 'vi', codes: ['vie'], name: 'Vietnamese', aliases: ['tiếng việt']),
  (
    code: 'zh',
    codes: ['chi', 'zho'],
    name: 'Chinese',
    aliases: ['中文', 'mandarin', 'cantonese'],
  ),
];

final Map<String, _Language> _byCode = {
  for (final language in _languages) ...{
    language.code: language,
    for (final code in language.codes) code: language,
  },
};

final Map<String, _Language> _byName = {
  for (final language in _languages) ...{
    language.name.toLowerCase(): language,
    for (final alias in language.aliases) alias: language,
  },
};

final RegExp _codeTag = RegExp(r'^([a-zA-Z]{2,3})(?:[-_][a-zA-Z0-9]+)*$');
final RegExp _words = RegExp(r'[\p{L}\p{M}]+', unicode: true);

/// The English name of the language coded [code] - ISO 639-1 or 639-2, as
/// is, with no region - or null for a code not known here.
String? languageNameForCode(String code) =>
    _byCode[code.trim().toLowerCase()]?.name;

/// The ISO 639-1 code - or, for Filipino, the ISO 639-2 one - of the
/// language [tag] stands for, or null when it names none known here.
///
/// [tag] may be a code, with or without a region, or text naming the
/// language: `Track 1 - [English]`, `Brazilian Portuguese`, `Español`. `und`,
/// the code sources give an unknown language, is null.
String? languageCodeOf(String? tag) {
  final value = tag?.trim();
  if (value == null || value.isEmpty) return null;
  final code = _codeTag.firstMatch(value);
  if (code != null) return _byCode[code[1]!.toLowerCase()]?.code;
  final lowered = value.toLowerCase();
  final whole = _byName[lowered];
  if (whole != null) return whole.code;
  for (final word in _words.allMatches(lowered)) {
    final named = _byName[word[0]!];
    if (named != null) return named.code;
  }
  // A two-word alias, which the word scan cannot see.
  for (final entry in _byName.entries) {
    if (entry.key.contains(' ') && lowered.contains(entry.key)) {
      return entry.value.code;
    }
  }
  return null;
}

/// Whether [tag] is in the language [preferred] names - both read by
/// [languageCodeOf], so `eng`, `en-GB` and `English` all answer `en`.
bool isLanguage(String? tag, String? preferred) {
  final want = languageCodeOf(preferred);
  return want != null && languageCodeOf(tag) == want;
}
