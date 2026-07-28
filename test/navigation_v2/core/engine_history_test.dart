import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_event.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_event_bus.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_history.dart';

EngineEvent _event(String engineId, EngineEventType type) => EngineEvent(
      engineId: engineId,
      type: type,
      timestamp: DateTime.now(),
    );

void main() {
  group('EngineHistory (manual record)', () {
    test('starts empty', () {
      final history = EngineHistory();
      expect(history.length, 0);
      expect(history.entries, isEmpty);
    });

    test('records events in chronological order', () {
      final history = EngineHistory();
      history.record(_event('gps', EngineEventType.registered));
      history.record(_event('gps', EngineEventType.started));

      expect(history.length, 2);
      expect(history.entries.first.type, EngineEventType.registered);
      expect(history.entries.last.type, EngineEventType.started);
    });

    test('evicts oldest entry once maxEntries is exceeded', () {
      final history = EngineHistory(maxEntries: 2);
      history.record(_event('gps', EngineEventType.registered));
      history.record(_event('gps', EngineEventType.started));
      history.record(_event('gps', EngineEventType.stopped));

      expect(history.length, 2);
      expect(history.entries.first.type, EngineEventType.started);
      expect(history.entries.last.type, EngineEventType.stopped);
    });

    test('forEngine filters by engine id', () {
      final history = EngineHistory();
      history.record(_event('gps', EngineEventType.registered));
      history.record(_event('compass', EngineEventType.registered));

      final gpsOnly = history.forEngine('gps');
      expect(gpsOnly, hasLength(1));
      expect(gpsOnly.single.engineId, 'gps');
    });

    test('clear() empties the history', () {
      final history = EngineHistory();
      history.record(_event('gps', EngineEventType.registered));
      history.clear();
      expect(history.length, 0);
    });
  });

  group('EngineHistory (attached to a bus)', () {
    test('records events published on the bus automatically', () async {
      final bus = EngineEventBus();
      final history = EngineHistory();
      history.attach(bus);

      bus.publish(_event('gps', EngineEventType.registered));
      await Future<void>.delayed(Duration.zero);

      expect(history.length, 1);
      expect(history.entries.single.engineId, 'gps');

      await history.detach();
      await bus.dispose();
    });

    test('detach() stops recording new events', () async {
      final bus = EngineEventBus();
      final history = EngineHistory();
      history.attach(bus);
      await history.detach();

      bus.publish(_event('gps', EngineEventType.registered));
      await Future<void>.delayed(Duration.zero);

      expect(history.length, 0);
      await bus.dispose();
    });

    test('attach() replaces a previous subscription', () async {
      final busA = EngineEventBus();
      final busB = EngineEventBus();
      final history = EngineHistory();

      history.attach(busA);
      history.attach(busB);
      busA.publish(_event('gps', EngineEventType.registered));
      busB.publish(_event('compass', EngineEventType.registered));
      await Future<void>.delayed(Duration.zero);

      expect(history.length, 1);
      expect(history.entries.single.engineId, 'compass');

      await history.detach();
      await busA.dispose();
      await busB.dispose();
    });
  });
}
