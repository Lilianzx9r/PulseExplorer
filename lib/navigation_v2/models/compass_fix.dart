/// A single compass reading, decoupled from the `flutter_compass`
/// package's `CompassEvent` type so this model stays trivially testable.
class CompassFix {
  const CompassFix({
    required this.headingDeg,
    required this.timestamp,
    this.accuracy,
  });

  /// Compass heading in degrees (0-360, 0 = north).
  final double headingDeg;

  final DateTime timestamp;

  /// Sensor accuracy, if provided by the platform (unit and range are
  /// platform-dependent — treat as a relative confidence indicator only).
  final double? accuracy;

  @override
  String toString() => 'CompassFix($headingDeg° @ $timestamp)';
}
