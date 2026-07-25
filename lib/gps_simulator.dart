import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'navigation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// gps_simulator.dart
//
// Simule un déplacement GPS le long d'une géométrie de route, à vitesse
// réglable. Alimente les mêmes ValueNotifier<LatLng>/<double?> que le vrai
// GPS — donc boussole, orientation carte, validation d'étapes fonctionnent
// sans modification pendant une simulation.
// ─────────────────────────────────────────────────────────────────────────────

class GpsSimulator extends ChangeNotifier {
  final ValueNotifier<LatLng> positionNotifier;
  final ValueNotifier<double?> headingNotifier;
  final bool _ownsNotifiers;

  List<LatLng> _geometry = [];
  double _speedKmh = 50; // vitesse simulée
  bool _running = false;
  bool _paused = false;
  int _segmentIndex = 0;
  double _segmentProgress = 0; // 0..1 le long du segment courant
  Timer? _timer;

  static const _tickMs = 200; // fréquence de mise à jour

  /// Crée un simulateur avec ses propres notifiers (usage autonome)
  GpsSimulator({LatLng? initialPosition})
      : positionNotifier = ValueNotifier(initialPosition ?? const LatLng(0, 0)),
        headingNotifier  = ValueNotifier(null),
        _ownsNotifiers = true;

  /// Crée un simulateur qui écrit dans des notifiers EXISTANTS — utile pour
  /// que la simulation alimente le même circuit que le vrai GPS (radars,
  /// limites de vitesse, navigation) sans duplication de logique.
  GpsSimulator.withExternalNotifiers({
    required this.positionNotifier, required this.headingNotifier,
  }) : _ownsNotifiers = false;

  bool get isRunning => _running;
  bool get isPaused  => _paused;
  double get speedKmh => _speedKmh;
  double get progress => _geometry.isEmpty ? 0
      : (_segmentIndex + _segmentProgress) / (_geometry.length - 1).clamp(1, double.infinity);

  /// Démarre la simulation le long d'une géométrie de route
  void start(List<LatLng> geometry, {double speedKmh = 50}) {
    if (geometry.length < 2) return;
    _geometry = geometry;
    _speedKmh = speedKmh;
    _segmentIndex = 0;
    _segmentProgress = 0;
    _running = true;
    _paused = false;
    positionNotifier.value = geometry.first;
    _updateHeading();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: _tickMs), (_) => _tick());
    notifyListeners();
  }

  void pause() { _paused = true; notifyListeners(); }
  void resume() { _paused = false; notifyListeners(); }

  void setSpeed(double kmh) {
    _speedKmh = kmh.clamp(5, 200);
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _paused = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_ownsNotifiers) {
      positionNotifier.dispose();
      headingNotifier.dispose();
    }
    super.dispose();
  }

  void _tick() {
    if (_paused || !_running || _geometry.length < 2) return;

    final metersPerTick = (_speedKmh * 1000 / 3600) * (_tickMs / 1000);
    double remaining = metersPerTick;

    while (remaining > 0 && _segmentIndex < _geometry.length - 1) {
      final a = _geometry[_segmentIndex];
      final b = _geometry[_segmentIndex + 1];
      final segLen = NavigationService.distanceM(a, b);
      final remainingInSegment = segLen * (1 - _segmentProgress);

      if (remaining < remainingInSegment) {
        _segmentProgress += remaining / segLen;
        remaining = 0;
      } else {
        remaining -= remainingInSegment;
        _segmentIndex++;
        _segmentProgress = 0;
        if (_segmentIndex >= _geometry.length - 1) {
          // Arrivée
          positionNotifier.value = _geometry.last;
          stop();
          return;
        }
      }
    }

    final a = _geometry[_segmentIndex];
    final b = _geometry[_segmentIndex + 1];
    positionNotifier.value = LatLng(
      a.latitude  + (b.latitude  - a.latitude)  * _segmentProgress,
      a.longitude + (b.longitude - a.longitude) * _segmentProgress,
    );
    _updateHeading();
    notifyListeners();
  }

  void _updateHeading() {
    if (_segmentIndex < _geometry.length - 1) {
      final a = _geometry[_segmentIndex];
      final b = _geometry[_segmentIndex + 1];
      headingNotifier.value = NavigationService.bearingDeg(a, b);
    }
  }
}
