class SubscriptionInfo {
  final DateTime? expiresAt;

  SubscriptionInfo({this.expiresAt});

  int get daysLeft {
    final expiry = expiresAt;
    if (expiry == null) {
      return 0;
    }
    final now = DateTime.now();
    final diff = expiry.difference(now).inDays;
    return diff < 0 ? 0 : diff;
  }

  bool get isKnown => expiresAt != null;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now());

  String get label {
    final expiry = expiresAt;
    if (expiry == null) {
      return 'Subscription expiry unknown';
    }

    final now = DateTime.now();

    if (!expiry.isAfter(now)) {
      return 'Expired';
    }

    if (daysLeft == 0) {
      return 'Expires today';
    }

    return 'Expires in $daysLeft days';
  }

  String get dateLabel {
    final expiry = expiresAt;
    if (expiry == null) {
      return 'Subscription expiry unknown';
    }
    return 'Subscription active until: '
        '${expiry.day.toString().padLeft(2, '0')}.'
        '${expiry.month.toString().padLeft(2, '0')}.'
        '${expiry.year}';
  }
}
