import 'package:flutter/material.dart';

void main() {
  runApp(const SpicApp());
}

class SpicApp extends StatelessWidget {
  const SpicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SPIC',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _enabled = false;

  String _accessString = '';
  String _paidUntil = '';
  String _server = 'fi'; // по умолчанию Финляндия

  @override
  Widget build(BuildContext context) {
    final statusText = _enabled ? 'SPIC включен' : 'SPIC выключен';
    final statusColor = _enabled ? Colors.green : Colors.red;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SPIC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final result = await Navigator.push<SettingsResult>(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    initialAccessString: _accessString,
                    initialPaidUntil: _paidUntil,
                    initialServer: _server,
                  ),
                ),
              );

              if (result != null) {
                setState(() {
                  _accessString = result.accessString;
                  _paidUntil = result.paidUntil;
                  _server = result.server;
                });
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              statusText,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  setState(() {
                    _enabled = !_enabled;
                  });
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  textStyle: const TextStyle(fontSize: 20),
                ),
                child: Text(_enabled ? 'Выключить' : 'Включить'),
              ),
            ),
            const SizedBox(height: 32),
            if (_server.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Сервер: $_server',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_accessString.isNotEmpty) ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Строка доступа:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _accessString,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
            ],
            if (_paidUntil.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Оплачено до: $_paidUntil',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsResult {
  final String accessString;
  final String paidUntil;
  final String server;

  SettingsResult({
    required this.accessString,
    required this.paidUntil,
    required this.server,
  });
}

class SettingsScreen extends StatefulWidget {
  final String initialAccessString;
  final String initialPaidUntil;
  final String initialServer;

  const SettingsScreen({
    super.key,
    this.initialAccessString = '',
    this.initialPaidUntil = '',
    this.initialServer = 'fi',
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _accessController;
  late TextEditingController _paidUntilController;

  bool _accessHasError = false; // <- добавили

  // список серверов: код + человекочитаемое имя
  final List<Map<String, String>> _servers = [
    {'code': 'fi', 'name': 'Финляндия'},
    // остальные добавим позже
  ];

  late String _selectedServerCode;

  @override
  void initState() {
    super.initState();
    _accessController =
        TextEditingController(text: widget.initialAccessString);
    _paidUntilController =
        TextEditingController(text: widget.initialPaidUntil);

    _selectedServerCode = widget.initialServer;
    if (!_servers.any((s) => s['code'] == _selectedServerCode)) {
      _selectedServerCode = _servers.first['code']!;
    }
  }

  @override
  void dispose() {
    _accessController.dispose();
    _paidUntilController.dispose();
    super.dispose();
  }

  void _saveAndClose() {
  final access = _accessController.text.trim();

  final hasError =
      access.isNotEmpty && !access.toLowerCase().startsWith('tt://');

  if (hasError) {
    setState(() {
      _accessHasError = true;
    });
    return; // не закрываем экран, пока строка не валидна
  }

  setState(() {
    _accessHasError = false;
  });

  Navigator.pop(
    context,
    SettingsResult(
      accessString: access,
      paidUntil: _paidUntilController.text.trim(),
      server: _selectedServerCode,
    ),
  );
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки SPIC'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Сервер',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedServerCode,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              items: _servers
                  .map(
                    (s) => DropdownMenuItem<String>(
                      value: s['code'],
                      child: Text(s['name']!),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _selectedServerCode = value;
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
				controller: _accessController,
				decoration: InputDecoration(
					labelText: 'Строка доступа (tt://)',
					hintText: 'Вставьте tt:// ссылку, выданную клиенту',
					border: const OutlineInputBorder(),
					errorText: _accessHasError
						? 'Ожидается ссылка TrustTunnel, начинающаяся с tt://'
						: null,
					),
				maxLines: 3,
				onChanged: (_) {
					if (_accessHasError) {
						setState(() {
							_accessHasError = false;
					});
				  }
			    },
			  ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveAndClose,
                child: const Text('Сохранить'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
