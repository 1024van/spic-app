import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tool/sign_json_manifest.dart <input.json> <private.b64> <output.json>',
    );
    exitCode = 64;
    return;
  }

  final input = File(args[0]);
  final privateKeyFile = File(args[1]);
  final output = File(args[2]);

  final decoded = jsonDecode(await input.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Manifest must be a JSON object');
  }

  final privateKeyBytes = base64Decode(
    (await privateKeyFile.readAsString()).trim(),
  );
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(privateKeyBytes);
  final payload = utf8.encode(
    _canonicalJson(Map<String, dynamic>.from(decoded)..remove('signature')),
  );
  final signature = await algorithm.sign(payload, keyPair: keyPair);
  final signed = Map<String, dynamic>.from(decoded)
    ..['signature'] = base64Encode(signature.bytes);

  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(signed),
  );
}

String _canonicalJson(Object? value) {
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value);
  if (value is num || value is bool) return jsonEncode(value);
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry('${entry.key}', entry.value))
            .toList(growable: false)
          ..sort((left, right) => left.key.compareTo(right.key));
    return '{${entries.map((entry) => '${jsonEncode(entry.key)}:${_canonicalJson(entry.value)}').join(',')}}';
  }
  return jsonEncode('$value');
}
