import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_event.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_event_bus.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_observer.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_observer_registry.dart';

class _RecordingObserver implements EngineObserver {
  final List<EngineEvent> received = [];

  @override
  void onEngineEvent(EngineEvent event) => received.add(event);
}

void main() {
  group('EngineObserverRegistry', () {
    test('notifies registered observers of published events', () async {
      final bus = EngineEventBus();
      final registry = EngineObserverRegistry(bus);
      final observer = _RecordingObserver();

      registry.add(observer);
      bus.publish(EngineEvent(
        engineId: 'gps',
        type: EngineEventType.started,
        timestamp: DateTime.now(),
      ));

      await Future<void>.delayed(Duration.zero);
      expect(observer.received, hasLength(1));
      expect(observer.received.single.engineId, 'gps');

      await registry.dispose();
      await bus.dispose();
    });

    test('does not add the same observer twice', () {
      final bus = EngineEventBus();
      final registry = EngineObserverRegistry(bus);
      final observer = _RecordingObserver();

      registry.add(observer);
      registry.add(observer);

      expect(registry.count, 1);
    });

    test('remove() stops notifying the observer', () async {
      final bus = EngineEventBus();
      final registry = EngineObserverRegistry(bus);
      final observer = _RecordingObserver();

      registry.add(observer);
      registry.remove(observer);
      bus.publish(EngineEvent(
        engineId: 'gps',
        type: EngineEventType.started,
        timestamp: DateTime.now(),
      ));

      await Future<void>.delayed(Duration.zero);
      expect(observer.received, isEmpty);

      await registry.dispose();
      await bus.dispose();
    });

    test('dispose() clears observers and cancels subscription', () async {
      final bus = EngineEventBus();
      final registry = EngineObserverRegistry(bus);
      final observer = _RecordingObserver();

      registry.add(observer);
      await registry.dispose();

      expect(registry.count, 0);
    });
  });
}
