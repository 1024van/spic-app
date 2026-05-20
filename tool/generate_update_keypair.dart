import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/generate_update_keypair.dart <private> <public>',
    );
    exitCode = 64;
    return;
  }

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final privateBytes = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();

  await File(args[0]).writeAsString(base64Encode(privateBytes));
  await File(args[1]).writeAsString(base64Encode(publicKey.bytes));
  stdout.write(base64Encode(publicKey.bytes));
}
