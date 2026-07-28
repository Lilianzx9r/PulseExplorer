import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_health.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_registration.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_registry.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_core.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine_state.dart';

class _SpyEngine implements NavigationEngine {
  _SpyEngine({this.failOn});

  /// Which lifecycle call should throw, if any: 'initialize'/'start'/'stop'.
  final String? failOn;

  final calls = <String>[];

  @override
  NavigationEngineState get state => NavigationEngineState.created;
  @override
  EngineHealthReport get health => const EngineHealthReport(EngineHealthStatus.healthy);

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    if (failOn == 'initialize') throw Exception('boom');
  }

  @override
  Future<void> start() async {
    calls.add('start');
    if (failOn == 'start') throw Exception('boom');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failOn == 'stop') throw Exception('boom');
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

void main() {
  group('NavigationCore', () {
    test('is not initialized before initialize() is called', () {
      final core = NavigationCore();
      expect(core.initialized, isFalse);
    });

    test('initialize() with no registered engine succeeds and sets initialized', () async {
      final core = NavigationCore();
      final result = await core.initialize();
      expect(result.ok, isTrue);
      expect(core.initialized, isTrue);
    });

    test('initialize()/start()/stop() propagate to every registered engine', () async {
      final core = NavigationCore();
      final gps = _SpyEngine();
      final compass = _SpyEngine();
      core.registry.register(EngineRegistration(id: 'gps', engine: gps));
      core.registry.register(EngineRegistration(id: 'compass', engine: compass));

      await core.initialize();
      await core.start();
      await core.stop();

      expect(gps.calls, ['initialize', 'start', 'stop']);
      expect(compass.calls, ['initialize', 'start', 'stop']);
    });

    test('a failing engine does not block the others (best effort)', () async {
      final core = NavigationCore();
      final failing = _SpyEngine(failOn: 'start');
      final healthy = _SpyEngine();
      core.registry.register(EngineRegistration(id: 'failing', engine: failing));
      core.registry.register(EngineRegistration(id: 'healthy', engine: healthy));

      final result = await core.start();

      expect(result.ok, isFalse);
      expect(result.message, contains('failing'));
      expect(healthy.calls, contains('start'));
    });

    test('an existing custom EngineRegistry can be supplied', () async {
      final registry = EngineRegistry();
      final engine = _SpyEngine();
      registry.register(EngineRegistration(id: 'gps', engine: engine));

      final core = NavigationCore(registry: registry);
      await core.start();

      expect(engine.calls, contains('start'));
      expect(core.registry, same(registry));
    });
  });
}
