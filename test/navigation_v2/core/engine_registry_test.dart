import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_event.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_event_bus.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_exception.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_registration.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_registry.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_health.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine_state.dart';

class _FakeEngine implements NavigationEngine {
  @override
  NavigationEngineState get state => NavigationEngineState.created;
  @override
  EngineHealthReport get health => const EngineHealthReport(EngineHealthStatus.healthy);
  @override
  Future<void> initialize() async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

EngineRegistration _registration(String id) =>
    EngineRegistration(id: id, engine: _FakeEngine());

void main() {
  group('EngineRegistry (no bus)', () {
    test('register/byId/contains', () {
      final registry = EngineRegistry();
      registry.register(_registration('gps'));
      expect(registry.contains('gps'), isTrue);
      expect(registry.byId('gps').id, 'gps');
    });

    test('register throws on duplicate id', () {
      final registry = EngineRegistry();
      registry.register(_registration('gps'));
      expect(() => registry.register(_registration('gps')),
          throwsA(isA<EngineAlreadyRegisteredException>()));
    });

    test('byId throws when not found', () {
      final registry = EngineRegistry();
      expect(() => registry.byId('missing'), throwsA(isA<EngineNotFoundException>()));
    });

    test('unregister removes and returns true, false if absent', () {
      final registry = EngineRegistry();
      registry.register(_registration('gps'));
      expect(registry.unregister('gps'), isTrue);
      expect(registry.unregister('gps'), isFalse);
    });

    test('clear empties the registry', () {
      final registry = EngineRegistry();
      registry.register(_registration('gps'));
      registry.register(_registration('compass'));
      registry.clear();
      expect(registry.registrations, isEmpty);
    });
  });

  group('EngineRegistry (with bus)', () {
    test('publishes a registered event on register()', () async {
      final bus = EngineEventBus();
      final registry = EngineRegistry(eventBus: bus);
      final events = <EngineEvent>[];
      final sub = bus.stream.listen(events.add);

      registry.register(_registration('gps'));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.engineId, 'gps');
      expect(events.single.type, EngineEventType.registered);

      await sub.cancel();
      await bus.dispose();
    });

    test('publishes an unregistered event on unregister()', () async {
      final bus = EngineEventBus();
      final registry = EngineRegistry(eventBus: bus);
      registry.register(_registration('gps'));

      final events = <EngineEvent>[];
      final sub = bus.stream.listen(events.add);
      registry.unregister('gps');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.type, EngineEventType.unregistered);

      await sub.cancel();
      await bus.dispose();
    });

    test('clear() publishes an unregistered event per engine', () async {
      final bus = EngineEventBus();
      final registry = EngineRegistry(eventBus: bus);
      registry.register(_registration('gps'));
      registry.register(_registration('compass'));

      final events = <EngineEvent>[];
      final sub = bus.stream.listen(events.add);
      registry.clear();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events.every((e) => e.type == EngineEventType.unregistered), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('does not publish when no bus is supplied', () async {
      // Regression check: no bus means no crash, no events to observe.
      final registry = EngineRegistry();
      registry.register(_registration('gps'));
      registry.clear();
      expect(registry.registrations, isEmpty);
    });
  });
}
