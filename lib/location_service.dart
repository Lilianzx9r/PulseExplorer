import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';

/// Service de localisation GPS + boussole
/// Uniquement sur Android/iOS — stub sur desktop
class LocationService {

  static StreamSubscription<Position>?     _positionSub;
  static StreamSubscription<CompassEvent>? _compassSub;

  static Position? lastPosition;
  static double?   lastHeading;  // degrés, nord = 0

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Demande les permissions et démarre le suivi
  static Future<String?> start({
    required void Function(Position)     onPosition,
    required void Function(double?)      onHeading,
  }) async {
    if (!isSupported) return 'GPS non disponible sur desktop';

    // Vérifier/demander permission
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) return 'Permission GPS refusée';
    }
    if (perm == LocationPermission.deniedForever) {
      return 'Permission GPS refusée définitivement — activez-la dans les paramètres';
    }

    // GPS activé ?
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return 'GPS désactivé — activez-le dans les paramètres';

    // Position initiale rapide
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      );
      lastPosition = pos;
      onPosition(pos);
    } catch (_) {}

    // Suivi continu
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:          LocationAccuracy.high,
        distanceFilter:    3,           // mise à jour toutes les 3 m
        timeLimit:         Duration(seconds: 2),
      ),
    ).listen((pos) {
      lastPosition = pos;
      onPosition(pos);
    });

    // Boussole
    _compassSub?.cancel();
    if (FlutterCompass.events != null) {
      _compassSub = FlutterCompass.events!.listen((event) {
        lastHeading = event.heading;
        onHeading(event.heading);
      });
    }

    return null; // succès
  }

  static void stop() {
    _positionSub?.cancel(); _positionSub = null;
    _compassSub?.cancel();  _compassSub  = null;
    lastPosition = null;
    lastHeading  = null;
  }
}
