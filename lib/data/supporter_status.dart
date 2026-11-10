/// Server-issued supporter state. It never gates basic playback.
class SupporterStatus {
  final String status;
  final bool supported;
  final int deviceLimit;
  final DateTime? validUntil;

  const SupporterStatus({
    this.status = 'free',
    this.supported = false,
    this.deviceLimit = 0,
    this.validUntil,
  });

  static const free = SupporterStatus();

  factory SupporterStatus.fromJson(Map<String, dynamic> json) {
    final limit = json['device_limit'];
    return SupporterStatus(
      status: json['status'] is String ? json['status'] as String : 'free',
      supported: json['supported'] == true,
      deviceLimit: limit is int && limit >= 0 && limit <= 100 ? limit : 0,
      validUntil: DateTime.tryParse('${json['valid_until'] ?? ''}'),
    );
  }

  bool isActiveAt(DateTime time) =>
      supported && validUntil != null && time.isBefore(validUntil!);
}
