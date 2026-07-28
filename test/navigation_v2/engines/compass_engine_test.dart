import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_exception.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_health.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine_state.dart';
import 'package:pulse_explorer/navigation_v2/engines/compass_engine.dart';
import 'package:pulse_explorer/navigation_v2/models/compass_fix.dart';

CompassFix _fix(double heading) =>
    CompassFix(headingDeg: heading, timestamp: DateTime(2026, 1, 1));

void main() {
  group('CompassEngine.initialize', () {
    test('fails when no compass sensor is available', () async {
      final engine = CompassEngine(isAvailable: () => false);

      await engine.initialize();

      expect(engine.state, NavigationEngineState.failed);
      expect(engine.health.status, EngineHealthStatus.error);
    });

    test('succeeds when a compass sensor is available', () async {
      final engine = CompassEngine(isAvailable: () => true);

      await engine.initialize();

      expect(engine.state, NavigationEngineState.initialized);
      expect(engine.health.status, EngineHealthStatus.healthy);
    });
  });

  group('CompassEngine.start/stop', () {
    test('throws EngineStateException if initialize() failed', () async {
      final engine = CompassEngine(isAvailable: () => false);
      await engine.initialize();

      expect(() => engine.start(), throwsA(isA<EngineStateException>()));
    });

    test('publishes headings from the injected stream and tracks currentFix', () async {
      final engine = CompassEngine(
        isAvailable: () => true,
        fixStream: () => Stream.fromIterable([_fix(10), _fix(20)]),
      );
      await engine.initialize();

      final received = <CompassFix>[];
      final sub = engine.fixes.listen(received.add);

      await engine.start();
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(engine.currentFix?.headingDeg, 20);
      expect(engine.state, NavigationEngineState.running);

      await sub.cancel();
      await engine.dispose();
    });

    test('stop() cancels the subscription, no more headings received', () async {
      final controller = StreamController<CompassFix>();
      final engine = CompassEngine(
        isAvailable: () => true,
        fixStream: () => controller.stream,
      );
      await engine.initialize();
      await engine.start();

      final received = <CompassFix>[];
      final sub = engine.fixes.listen(received.add);

      controller.add(_fix(5));
      await Future<void>.delayed(Duration.zero);
      await engine.stop();
      controller.add(_fix(99));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(engine.state, NavigationEngineState.stopped);

      await sub.cancel();
      await controller.close();
      await engine.dispose();
    });

    test('dispose() closes the fixes stream', () async {
      final engine = CompassEngine(
        isAvailable: () => true,
        fixStream: () => const Stream.empty(),
      );
      await engine.initialize();
      await engine.start();
      await engine.dispose();

      expect(engine.state, NavigationEngineState.disposed);
      await expectLater(engine.fixes, emitsDone);
    });
  });
}
