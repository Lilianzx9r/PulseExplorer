import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_exception.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_health.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine_state.dart';
import 'package:pulse_explorer/navigation_v2/engines/gps_engine.dart';
import 'package:pulse_explorer/navigation_v2/models/gps_fix.dart';

GpsFix _fix({double lat = 45.0, double lon = 0.0}) => GpsFix(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime(2026, 1, 1),
    );

void main() {
  group('GpsEngine.initialize', () {
    test('fails when the location service is disabled', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => false,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
      );

      await engine.initialize();

      expect(engine.state, NavigationEngineState.failed);
      expect(engine.health.status, EngineHealthStatus.error);
    });

    test('requests permission once when initially denied, then succeeds', () async {
      var requested = false;
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        requestPermission: () async {
          requested = true;
          return LocationPermission.whileInUse;
        },
      );

      await engine.initialize();

      expect(requested, isTrue);
      expect(engine.state, NavigationEngineState.initialized);
      expect(engine.health.status, EngineHealthStatus.healthy);
    });

    test('fails when permission stays denied after requesting it', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        requestPermission: () async => LocationPermission.denied,
      );

      await engine.initialize();

      expect(engine.state, NavigationEngineState.failed);
    });

    test('fails when permission is deniedForever', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.deniedForever,
        requestPermission: () async => LocationPermission.deniedForever,
      );

      await engine.initialize();

      expect(engine.state, NavigationEngineState.failed);
    });

    test('succeeds directly when permission is already granted', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
      );

      await engine.initialize();

      expect(engine.state, NavigationEngineState.initialized);
    });
  });

  group('GpsEngine.start/stop', () {
    test('throws EngineStateException if initialize() failed', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => false,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
      );
      await engine.initialize();

      expect(() => engine.start(), throwsA(isA<EngineStateException>()));
    });

    test('publishes fixes from the injected stream and tracks currentFix', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
        fixStream: () => Stream.fromIterable([_fix(lat: 1), _fix(lat: 2)]),
      );
      await engine.initialize();

      final received = <GpsFix>[];
      final sub = engine.fixes.listen(received.add);

      await engine.start();
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(engine.currentFix?.latitude, 2);
      expect(engine.state, NavigationEngineState.running);

      await sub.cancel();
      await engine.dispose();
    });

    test('stop() cancels the subscription, no more fixes received', () async {
      final controller = StreamController<GpsFix>();
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
        fixStream: () => controller.stream,
      );
      await engine.initialize();
      await engine.start();

      final received = <GpsFix>[];
      final sub = engine.fixes.listen(received.add);

      controller.add(_fix());
      await Future<void>.delayed(Duration.zero);
      await engine.stop();
      controller.add(_fix(lat: 99));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(engine.state, NavigationEngineState.stopped);

      await sub.cancel();
      await controller.close();
      await engine.dispose();
    });

    test('dispose() closes the fixes stream', () async {
      final engine = GpsEngine(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
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
