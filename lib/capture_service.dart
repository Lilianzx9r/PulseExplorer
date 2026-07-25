import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

class CaptureService {
  static const _channel = MethodChannel('pulse_gpx/capture');

  static Function(Uint8List bytes)? onCapture;

  static Future<bool> hasOverlayPermission() async =>
      await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;

  static Future<bool> requestOverlayPermission() async =>
      await _channel.invokeMethod<bool>('requestOverlayPermission') ?? false;

  /// Retourne le resultCode si accordé, null si annulé, lance une exception si erreur
  static Future<int?> requestMediaProjection() async {
    try {
      final result = await _channel.invokeMethod('startCapture');
      // null = l'utilisateur a appuyé "Annuler" dans la boîte système
      if (result == null) return null;
      return result as int;
    } on PlatformException catch (e) {
      throw Exception('Erreur MediaProjection : ${e.message}');
    }
  }

  static Future<void> startFloatingService(int resultCode) async {
    try {
      await _channel.invokeMethod('startFloatingService', {'resultCode': resultCode});
    } on PlatformException catch (e) {
      throw Exception('Impossible de démarrer le service : ${e.message}');
    }
  }

  static Future<void> stopFloatingService() async =>
      await _channel.invokeMethod('stopFloatingService');

  static Future<bool> openApp(String packageName) async =>
      await _channel.invokeMethod<bool>('openApp', {'package': packageName}) ?? false;

  static Future<bool> isAppInstalled(String packageName) async =>
      await _channel.invokeMethod<bool>('isAppInstalled', {'package': packageName}) ?? false;

  static Future<ui.Image> bytesToImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }
}
