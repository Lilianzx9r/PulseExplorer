/// Snapshot of navigation progress along an active route.
class RouteProgress {
  const RouteProgress({
    required this.currentStepIndex,
    required this.distanceRemainingM,
    required this.durationRemainingS,
    required this.arrived,
  });

  /// Index of the step (target waypoint) currently being approached.
  final int currentStepIndex;

  /// Estimated remaining distance to the destination, in meters.
  final double distanceRemainingM;

  /// Estimated remaining duration to the destination, in seconds.
  final double durationRemainingS;

  /// True once the last step's location has been reached.
  final bool arrived;

  @override
  String toString() =>
      'RouteProgress(step $currentStepIndex, ${distanceRemainingM.round()} m, arrived: $arrived)';
}
