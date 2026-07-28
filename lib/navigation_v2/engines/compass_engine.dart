import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';

import '../core/engine_exception.dart';
import '../core/engine_health.dart';
import '../core/navigation_engine.dart';
import '../core/navigation_engine_state.dart';
import '../models/compass_fix.dart';

// Abstracted signatures so tests can supply fakes instead of driving the
// real platform sensor stream behind `flutter_compass`.
typedef CompassAvailabilityChecker = bool Function();
typedef CompassFixStreamFactory = Stream<CompassFix> Function();

/// [NavigationEngine] wrapping the device compass via `flutter_compass`.
///
/// - `initialize()` checks that a compass sensor is available on this
///   device (`FlutterCompass.events != null`); if not, the engine fails
///   with an explanatory [EngineHealthReport] rather than throwing, so a
///   missing compass doesn't prevent other engines (e.g. GPS) from
///   starting when orchestrated by `NavigationCore`.
/// - `start()` opens the heading stream and publishes each reading on
///   [fixes]; `stop()` closes it. Readings with a `null` heading (which
///   `flutter_compass` can emit before the sensor settles) are skipped.
class CompassEngine implements NavigationEngine {
  CompassEngine({
    CompassAvailabilityChecker? isAvailable,
    CompassFixStreamFactory? fixStream,
  })  : _isAvailable = isAvailable ?? (() => FlutterCompass.events != null),
        _fixStreamFactory = fixStream ?? _defaultFixStream;

  final CompassAvailabilityChecker _isAvailable;
  final CompassFixStreamFactory _fixStreamFactory;

  NavigationEngineState _state = NavigationEngineState.created;
  EngineHealthReport _health = const EngineHealthReport(EngineHealthStatus.healthy);
  StreamSubscription<CompassFix>? _subscription;
  final _fixesController = StreamController<CompassFix>.broadcast();
  CompassFix? _currentFix;

  @override
  NavigationEngineState get state => _state;

  @override
  EngineHealthReport get health => _health;

  /// Latest known heading, if any has been received yet.
  CompassFix? get currentFix => _currentFix;

  /// Broadcast stream of compass readings received while running.
  Stream<CompassFix> get fixes => _fixesController.stream;

  static Stream<CompassFix> _defaultFixStream() {
    final events = FlutterCompass.events;
    if (events == null) return const Stream.empty();
    return events
        .where((e) => e.heading != null)
        .map((e) => CompassFix(
              headingDeg: e.heading!,
              timestamp: DateTime.now(),
              accuracy: e.accuracy,
            ));
  }

  @override
  Future<void> initialize() async {
    _state = NavigationEngineState.initializing;
    try {
      if (!_isAvailable()) {
        _fail('Capteur boussole indisponible sur cet appareil.');
        return;
      }
      _health = const EngineHealthReport(EngineHealthStatus.healthy);
      _state = NavigationEngineState.initialized;
    } catch (e) {
      _fail('$e');
    }
  }

  @override
  Future<void> start() async {
    if (_state == NavigationEngineState.failed) {
      throw EngineStateException('CompassEngine cannot start: ${_health.message}');
    }
    _state = NavigationEngineState.starting;
    await _subscription?.cancel();
    _subscription = _fixStreamFactory().listen(_onFix, onError: _onError);
    _state = NavigationEngineState.running;
  }

  void _onFix(CompassFix fix) {
    _currentFix = fix;
    _fixesController.add(fix);
  }

  void _onError(Object error) {
    _health = EngineHealthReport(EngineHealthStatus.warning, message: '$error');
  }

  @override
  Future<void> stop() async {
    _state = NavigationEngineState.stopping;
    await _subscription?.cancel();
    _subscription = null;
    _state = NavigationEngineState.stopped;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _fixesController.close();
    _state = NavigationEngineState.disposed;
  }

  void _fail(String message) {
    _health = EngineHealthReport(EngineHealthStatus.error, message: message);
    _state = NavigationEngineState.failed;
  }
}
