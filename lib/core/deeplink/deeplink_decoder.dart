import 'dart:convert';
import 'dart:typed_data';

import 'deeplink_model.dart';

class TTDecoder {
  static TTConfig decode(String link) {
    final uri = Uri.parse(link);

    if (uri.scheme != 'tt') {
      throw Exception('Invalid scheme');
    }

    // tt://?XXXX
    final encoded = uri.query;
    if (encoded.isEmpty) {
      throw Exception('Empty deeplink data');
    }

    // добавляем padding
    String normalized = encoded;
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }

    final Uint8List bytes = base64Url.decode(normalized);

    int i = 0;

    String? hostname;
    String? address;
    String? username;
    String? password;
    DateTime? expiresAt;
    String? subscriptionId;
    String? userId;

    while (i < bytes.length) {
      if (i + 1 >= bytes.length) {
        throw Exception('Malformed deeplink data');
      }
      final tag = bytes[i];
      final length = bytes[i + 1];
      if (i + 2 + length > bytes.length) {
        throw Exception('Malformed deeplink data');
      }

      final valueBytes = bytes.sublist(i + 2, i + 2 + length);
      final value = utf8.decode(valueBytes);

      switch (tag) {
        case 0x01:
          hostname = value;
          break;
        case 0x02:
          address = value;
          break;
        case 0x05:
          username = value;
          break;
        case 0x06:
          password = value;
          break;
        case 0x07:
          expiresAt = DateTime.tryParse(value)?.toLocal();
          break;
        case 0x08:
          subscriptionId = value;
          break;
        case 0x09:
          userId = value;
          break;
      }

      i += 2 + length;
    }

    return TTConfig(
      hostname: hostname,
      address: address,
      username: username,
      password: password,
      expiresAt: expiresAt,
      subscriptionId: subscriptionId,
      userId: userId,
    );
  }
}
