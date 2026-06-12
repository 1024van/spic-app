import 'package:flutter/material.dart';

import '../../core/deeplink/deeplink_decoder.dart';
import '../../core/deeplink/deeplink_model.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final TextEditingController controller = TextEditingController();

  TTConfig? config;
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void decodeLink() {
    setState(() {
      error = null;
      config = null;
    });

    try {
      final result = TTDecoder.decode(controller.text.trim());

      if (!result.isValid) {
        throw Exception('Invalid config');
      }

      setState(() {
        config = result;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
      });
    }
  }

  void connect() {
    if (config == null) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Connecting to ${config!.server}')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import access link')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Access link',
                hintText: 'tt://?...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: decodeLink,
              child: const Text('Check link'),
            ),
            const SizedBox(height: 20),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (config != null) ...[
              Text('Server: ${config!.server}'),
              const Text('Access credentials are stored securely.'),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: connect, child: const Text('Connect')),
            ],
          ],
        ),
      ),
    );
  }
}
