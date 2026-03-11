import 'dart:async';

/// Статус VPN-соединения
enum SpicVpnStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// Результат операции с VPN
class SpicVpnResult {
  final SpicVpnStatus status;
  final String? errorMessage;

  const SpicVpnResult(this.status, {this.errorMessage});

  static const disconnected = SpicVpnResult(SpicVpnStatus.disconnected);
  static const connected = SpicVpnResult(SpicVpnStatus.connected);
}

/// Абстракция поверх конкретной реализации TrustTunnel-клиента
abstract class SpicVpnClient {
  Future<void> init();

  Future<SpicVpnResult> connect(String deeplink);

  Future<SpicVpnResult> disconnect();

  SpicVpnStatus get status;

  Stream<SpicVpnStatus> get statusStream;
}

/// Заглушка для разработки UI.
/// TODO: заменить на реальную интеграцию с TrustTunnel Flutter Client.
class TrustTunnelSpicClient implements SpicVpnClient {
  SpicVpnStatus _status = SpicVpnStatus.disconnected;
  final _statusController = StreamController<SpicVpnStatus>.broadcast();

  @override
  SpicVpnStatus get status => _status;

  @override
  Stream<SpicVpnStatus> get statusStream => _statusController.stream;

  void _setStatus(SpicVpnStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  @override
  Future<void> init() async {
    // TODO: инициализировать TrustTunnel Flutter Client (если требуется)
    _setStatus(SpicVpnStatus.disconnected);
  }

  @override
  Future<SpicVpnResult> connect(String deeplink) async {
    // Простейшая проверка deeplink
    if (!deeplink.toLowerCase().startsWith('tt://')) {
      _setStatus(SpicVpnStatus.error);
      return SpicVpnResult(
        SpicVpnStatus.error,
        errorMessage: 'Некорректная ссылка TrustTunnel (ожидается tt://)',
      );
    }

    _setStatus(SpicVpnStatus.connecting);

    // TODO: вызвать реальный TrustTunnel Flutter Client:
    // 1) передать deeplink в его API
    // 2) дождаться события CONNECTED/FAILED
    // 3) в зависимости от результата вернуть connected / error

    // Пока заглушка: ждём 1 секунду и считаем, что подключились
    await Future.delayed(const Duration(seconds: 1));

    _setStatus(SpicVpnStatus.connected);
    return SpicVpnResult.connected;
  }

  @override
  Future<SpicVpnResult> disconnect() async {
    if (_status == SpicVpnStatus.disconnected) {
      return SpicVpnResult.disconnected;
    }

    _setStatus(SpicVpnStatus.connecting);

    // TODO: вызвать disconnect в TrustTunnel Flutter Client
    await Future.delayed(const Duration(milliseconds: 500));

    _setStatus(SpicVpnStatus.disconnected);
    return SpicVpnResult.disconnected;
  }

  Future<void> dispose() async {
    await _statusController.close();
  }
}
