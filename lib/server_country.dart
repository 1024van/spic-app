import 'package:trusttunnel/data/model/server.dart';

const String kUnknownCountryFlag = '\u{1F310}';

String countryCodeToEmojiFlag(String? countryCode) {
  final code = countryCode?.trim().toUpperCase();
  if (code == null || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
    return kUnknownCountryFlag;
  }

  final firstLetter = code.codeUnitAt(0) - 'A'.codeUnitAt(0) + 0x1F1E6;
  final secondLetter = code.codeUnitAt(1) - 'A'.codeUnitAt(0) + 0x1F1E6;

  return String.fromCharCodes([firstLetter, secondLetter]);
}

String flagForServer(Server server) {
  return countryCodeToEmojiFlag(countryCodeForServer(server));
}

String? countryCodeForServer(Server server) {
  final directCode = _normalizeCountryCode(server.countryCode);
  if (directCode != null) return directCode;

  final hostKey = server.domain.trim().toLowerCase();
  final ipKey = server.ipAddress.split(':').first.trim().toLowerCase();
  final mappedCode =
      _serverLocationCodes[hostKey] ?? _serverLocationCodes[ipKey];
  if (mappedCode != null) return mappedCode;

  final text = '${server.name} ${server.domain}'.toLowerCase();
  for (final entry in _countryNameCodes.entries) {
    if (text.contains(entry.key)) return entry.value;
  }

  return null;
}

String? _normalizeCountryCode(String? value) {
  final code = value?.trim().toUpperCase();
  if (code == null || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
    return null;
  }

  return code;
}

const Map<String, String> _serverLocationCodes = {
  'stop2virus.xyz': 'FI',
  '185.236.24.249': 'FI',
  'nl3.trutun.online': 'NL',
  '146.103.124.6': 'NL',
};

const Map<String, String> _countryNameCodes = {
  'finland': 'FI',
  'suomi': 'FI',
  'netherlands': 'NL',
  'nederland': 'NL',
  'holland': 'NL',
  'nl3': 'NL',
  'france': 'FR',
  'germany': 'DE',
  'deutschland': 'DE',
  'united states': 'US',
  'usa': 'US',
};
