import 'dart:async';

import 'package:latlong2/latlong.dart';

import '../../navigation_service.dart';
import '../core/engine_exception.dart';
import '../core/engine_health.dart';
import '../core/navigation_engine.dart';
import '../core/navigation_engine_state.dart';
import '../models/route_progress.dart';

/// [NavigationEngine] tracking progress along an active [NavRoute].
///
/// Unlike `GpsEngine`/`CompassEngine`, `ItineraryEngine` has no sensor of
/// its own: it is fed positions explicitly via [updatePosition] —
/// typically wired to `GpsEngine.fixes` by the caller. Engines stay
/// decoupled from each other on purpose (see Lot 4/5); wiring them
/// together is the orchestrating code's responsibility, not the engines'.
///
/// It reuses the app's existing routing logic ([NavRoute]/[NavStep] from
/// `navigation_service.dart`, already used by `TripNavigationScreen`)
/// rather than recomputing distances/geometry from scratch.
class ItineraryEngine implements NavigationEngine {
  ItineraryEngine({double proximityM = 40}) : _proximityM = proximityM;

  final double _proximityM;

  NavigationEngineState _state = NavigationEngineState.created;
  EngineHealthReport _health = const EngineHealthReport(EngineHealthStatus.healthy);
  final _progressController = StreamController<RouteProgress>.broadcast();

  NavRoute? _route;
  int _currentStepIndex = 0;
  RouteProgress? _currentProgress;

  @override
  NavigationEngineState get state => _state;

  @override
  EngineHealthReport get health => _health;

  /// The route currently being followed, if any.
  NavRoute? get activeRoute => _route;

  /// Latest computed progress, if any.
  RouteProgress? get currentProgress => _currentProgress;

  /// Broadcast stream of progress updates, published each time
  /// [updatePosition] is called while running.
  Stream<RouteProgress> get progress => _progressController.stream;

  /// Sets (or replaces) the route to follow, resetting progress to its
  /// start. Can be called before [start], or while running to react to a
  /// recalculation (e.g. after going off-route).
  void setRoute(NavRoute route) {
    _route = route;
    _currentStepIndex = 0;
    _currentProgress = null;
  }

  @override
  Future<void> initialize() async {
    _state = NavigationEngineState.initializing;
    _health = const EngineHealthReport(EngineHealthStatus.healthy);
    _state = NavigationEngineState.initialized;
  }

  @override
  Future<void> start() async {
    if (_route == null) {
      throw EngineStateException(
          'ItineraryEngine cannot start: no route set (call setRoute first).');
    }
    _state = NavigationEngineState.starting;
    // Step 0 is the "depart" step, located at the trip's starting point —
    // there is nothing to "reach" there, so tracking starts by targeting
    // the next step (the first real waypoint), if one exists.
    final steps = _route!.steps;
    _currentStepIndex = steps.length > 1 ? 1 : 0;
    _currentProgress = null;
    _state = NavigationEngineState.running;
  }

  /// Feeds a new position into the engine: advances the targeted step
  /// index past any step whose location is within [proximityM] (so a
  /// single update can skip several close-together steps), then publishes
  /// a new [RouteProgress] on [progress]. No-op if not currently
  /// `running` or if no route is set — safe to call unconditionally from
  /// a position listener.
  void updatePosition(LatLng position) {
    final route = _route;
    if (_state != NavigationEngineState.running || route == null) return;
    final steps = route.steps;
    if (steps.isEmpty) return;

    while (_currentStepIndex < steps.length - 1 &&
        NavigationService.distanceM(position, steps[_currentStepIndex].location) <=
            _proximityM) {
      _currentStepIndex++;
    }

    final target = steps[_currentStepIndex];
    final distanceToTarget = NavigationService.distanceM(position, target.location);

    var distanceRemaining = distanceToTarget;
    var durationRemaining = 0.0;
    for (var i = _currentStepIndex; i < steps.length - 1; i++) {
      distanceRemaining += steps[i].distanceM;
      durationRemaining += steps[i].durationS;
    }

    final arrived = _currentStepIndex == steps.length - 1 && distanceToTarget <= _proximityM;

    final progress = RouteProgress(
      currentStepIndex: _currentStepIndex,
      distanceRemainingM: distanceRemaining,
      durationRemainingS: durationRemaining,
      arrived: arrived,
    );
    _currentProgress = progress;
    _progressController.add(progress);
  }

  @override
  Future<void> stop() async {
    _state = NavigationEngineState.stopping;
    _state = NavigationEngineState.stopped;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _progressController.close();
    _state = NavigationEngineState.disposed;
  }
}
