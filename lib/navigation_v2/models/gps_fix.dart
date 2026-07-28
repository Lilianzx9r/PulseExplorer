/// A single GPS fix, decoupled from the `geolocator` package's `Position`
/// type so this model stays trivially testable and reusable (e.g. by a
/// future GPX-replay or simulator engine).
class GpsFix {
  const GpsFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracyM,
    this.speedMps,
    this.headingDeg,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;

  /// Horizontal accuracy in meters, if provided by the platform.
  final double? accuracyM;

  /// Ground speed in meters/second, if provided by the platform.
  final double? speedMps;

  /// Compass heading in degrees (0-360), if provided by the platform.
  final double? headingDeg;

  @override
  String toString() =>
      'GpsFix($latitude, $longitude @ $timestamp, acc: $accuracyM m)';
}
