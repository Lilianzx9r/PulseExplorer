import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulse_explorer/navigation_service.dart';
import 'package:pulse_explorer/navigation_v2/core/engine_exception.dart';
import 'package:pulse_explorer/navigation_v2/core/navigation_engine_state.dart';
import 'package:pulse_explorer/navigation_v2/engines/itinerary_engine.dart';

// Three points roughly 111 m apart (≈0.001° of latitude), forming a
// straight route: depart -> waypoint -> arrive.
const _a = LatLng(45.000, 0.000);
const _b = LatLng(45.001, 0.000);
const _c = LatLng(45.002, 0.000);

NavRoute _route() => NavRoute(
      geometry: [_a, _b, _c],
      steps: [
        NavStep(instruction: 'Départ', distanceM: 111, durationS: 80, location: _a, maneuver: 'depart'),
        NavStep(instruction: 'Continuez', distanceM: 111, durationS: 80, location: _b),
        NavStep(instruction: 'Arrivée', distanceM: 0, durationS: 0, location: _c, maneuver: 'arrive'),
      ],
      totalDistanceM: 222,
      totalDurationS: 160,
      isOffline: true,
    );

void main() {
  group('ItineraryEngine.start', () {
    test('throws EngineStateException if no route is set', () async {
      final engine = ItineraryEngine();
      await engine.initialize();

      expect(() => engine.start(), throwsA(isA<EngineStateException>()));
    });

    test('starts once a route has been set', () async {
      final engine = ItineraryEngine();
      await engine.initialize();
      engine.setRoute(_route());

      await engine.start();

      expect(engine.state, NavigationEngineState.running);
      expect(engine.activeRoute, isNotNull);
    });
  });

  group('ItineraryEngine.updatePosition', () {
    test('is a no-op before start()', () {
      final engine = ItineraryEngine();
      engine.setRoute(_route());

      engine.updatePosition(_a);

      expect(engine.currentProgress, isNull);
    });

    test('publishes progress and advances step index near a waypoint', () async {
      final engine = ItineraryEngine(proximityM: 40);
      engine.setRoute(_route());
      await engine.initialize();
      await engine.start();

      final received = <int>[];
      final sub = engine.progress.listen((p) => received.add(p.currentStepIndex));

      // Right at the start: still targeting step 1 (the waypoint).
      engine.updatePosition(_a);
      // Close to the waypoint: should advance to step 2 (arrive).
      engine.updatePosition(_b);

      expect(received, [1, 2]);
      expect(engine.currentProgress?.currentStepIndex, 2);

      await sub.cancel();
      await engine.dispose();
    });

    test('sets arrived once within proximity of the final step', () async {
      final engine = ItineraryEngine(proximityM: 40);
      engine.setRoute(_route());
      await engine.initialize();
      await engine.start();

      engine.updatePosition(_b);
      engine.updatePosition(_c);

      expect(engine.currentProgress?.arrived, isTrue);
      expect(engine.currentProgress?.distanceRemainingM, lessThan(40));

      await engine.dispose();
    });

    test('distanceRemaining decreases as position approaches destination', () async {
      final engine = ItineraryEngine(proximityM: 5); // tight, so index won't jump ahead
      engine.setRoute(_route());
      await engine.initialize();
      await engine.start();

      engine.updatePosition(_a);
      final first = engine.currentProgress!.distanceRemainingM;

      engine.updatePosition(_b);
      final second = engine.currentProgress!.distanceRemainingM;

      expect(second, lessThan(first));
    });
  });

  group('ItineraryEngine.setRoute', () {
    test('resets progress when called again', () async {
      final engine = ItineraryEngine();
      engine.setRoute(_route());
      await engine.initialize();
      await engine.start();
      engine.updatePosition(_b);
      expect(engine.currentProgress, isNotNull);

      engine.setRoute(_route());

      expect(engine.currentProgress, isNull);
    });
  });

  group('ItineraryEngine.dispose', () {
    test('closes the progress stream', () async {
      final engine = ItineraryEngine();
      engine.setRoute(_route());
      await engine.initialize();
      await engine.start();

      await engine.dispose();

      expect(engine.state, NavigationEngineState.disposed);
      await expectLater(engine.progress, emitsDone);
    });
  });
}
