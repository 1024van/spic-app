class TTConfig {
  final String? hostname;
  final String? address;
  final String? username;
  final String? password;
  final DateTime? expiresAt;
  final String? subscriptionId;
  final String? userId;

  TTConfig({
    this.hostname,
    this.address,
    this.username,
    this.password,
    this.expiresAt,
    this.subscriptionId,
    this.userId,
  });

  factory TTConfig.fromJson(Map<String, dynamic> json) {
    final expiresAtRaw = json['expiresAt'];
    return TTConfig(
      hostname: _readString(json['hostname']),
      address: _readString(json['address']),
      username: _readString(json['username']),
      password: _readString(json['password']),
      expiresAt: expiresAtRaw == null
          ? null
          : DateTime.tryParse('$expiresAtRaw')?.toLocal(),
      subscriptionId: _readString(json['subscriptionId']),
      userId: _readString(json['userId']),
    );
  }

  String get server => address ?? hostname ?? '';

  bool get isValid => server.isNotEmpty && username != null && password != null;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now());

  @override
  String toString() {
    return 'TTConfig(hostname: $hostname, address: $address, username: $username, expiresAt: $expiresAt)';
  }

  Map<String, dynamic> toJson() => {
    if (hostname != null) 'hostname': hostname,
    if (address != null) 'address': address,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    if (subscriptionId != null) 'subscriptionId': subscriptionId,
    if (userId != null) 'userId': userId,
  };

  static String? _readString(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}
