import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/engine_exception.dart';
import '../core/engine_health.dart';
import '../core/navigation_engine.dart';
import '../core/navigation_engine_state.dart';
import '../models/gps_fix.dart';

// Abstracted signatures so tests can supply fakes instead of driving the
// real platform channel behind `geolocator`.
typedef LocationServiceEnabledChecker = Future<bool> Function();
typedef LocationPermissionChecker = Future<LocationPermission> Function();
typedef LocationPermissionRequester = Future<LocationPermission> Function();
typedef GpsFixStreamFactory = Stream<GpsFix> Function();

GpsFix _fixFromPosition(Position position) => GpsFix(
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: position.timestamp,
      accuracyM: position.accuracy,
      speedMps: position.speed,
      headingDeg: position.heading,
    );

/// [NavigationEngine] wrapping the device GPS via `geolocator`.
///
/// - `initialize()` checks that the location service is enabled and that
///   permission is granted (requesting it once if merely `denied`).
/// - `start()` opens a live position stream and publishes each fix on
///   [fixes]; `stop()` closes it. Registering the engine's `id` (e.g.
///   `'gps'`) in an `EngineRegistry` lets `NavigationCore` orchestrate it
///   alongside other engines (compass, map, ...).
class GpsEngine implements NavigationEngine {
  GpsEngine({
    LocationServiceEnabledChecker? isServiceEnabled,
    LocationPermissionChecker? checkPermission,
    LocationPermissionRequester? requestPermission,
    GpsFixStreamFactory? fixStream,
    LocationSettings? locationSettings,
  })  : _isServiceEnabled = isServiceEnabled ?? Geolocator.isLocationServiceEnabled,
        _checkPermission = checkPermission ?? Geolocator.checkPermission,
        _requestPermission = requestPermission ?? Geolocator.requestPermission,
        _fixStreamFactory = fixStream ??
            (() => Geolocator.getPositionStream(
                  locationSettings: locationSettings ??
                      const LocationSettings(
                        accuracy: LocationAccuracy.best,
                        distanceFilter: 3,
                      ),
                ).map(_fixFromPosition));

  final LocationServiceEnabledChecker _isServiceEnabled;
  final LocationPermissionChecker _checkPermission;
  final LocationPermissionRequester _requestPermission;
  final GpsFixStreamFactory _fixStreamFactory;

  NavigationEngineState _state = NavigationEngineState.created;
  EngineHealthReport _health = const EngineHealthReport(EngineHealthStatus.healthy);
  StreamSubscription<GpsFix>? _subscription;
  final _fixesController = StreamController<GpsFix>.broadcast();
  GpsFix? _currentFix;

  @override
  NavigationEngineState get state => _state;

  @override
  EngineHealthReport get health => _health;

  /// Latest known fix, if any has been received yet.
  GpsFix? get currentFix => _currentFix;

  /// Broadcast stream of GPS fixes received while running.
  Stream<GpsFix> get fixes => _fixesController.stream;

  @override
  Future<void> initialize() async {
    _state = NavigationEngineState.initializing;
    try {
      final serviceEnabled = await _isServiceEnabled();
      if (!serviceEnabled) {
        _fail('Service de localisation désactivé.');
        return;
      }

      var permission = await _checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _fail('Permission de localisation refusée.');
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
      throw EngineStateException('GpsEngine cannot start: ${_health.message}');
    }
    _state = NavigationEngineState.starting;
    await _subscription?.cancel();
    _subscription = _fixStreamFactory().listen(_onFix, onError: _onError);
    _state = NavigationEngineState.running;
  }

  void _onFix(GpsFix fix) {
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
