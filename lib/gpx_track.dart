import 'package:flutter/material.dart';
import 'gpx_parser.dart';

/// Un tracé GPX avec sa couleur d'affichage et son nom de fichier source
class GpxTrack {
  GpxData data; // mutable pour permettre l'enrichissement d'altitude a posteriori
  final String  fileName;
  final Color   color;
  bool          visible;

  GpxTrack({
    required this.data,
    required this.fileName,
    required this.color,
    this.visible = true,
  });

  String get displayName => data.name?.isNotEmpty == true ? data.name! : fileName;
}

/// Palette de couleurs pour distinguer les tracés
const List<Color> kTrackColors = [
  Color(0xFFE53935), // rouge
  Color(0xFF1E88E5), // bleu
  Color(0xFF43A047), // vert
  Color(0xFFFF8F00), // orange
  Color(0xFF8E24AA), // violet
  Color(0xFF00ACC1), // cyan
  Color(0xFFD81B60), // rose
  Color(0xFF6D4C41), // marron
  Color(0xFF546E7A), // gris-bleu
  Color(0xFFFFB300), // jaune
];

Color trackColorForIndex(int index) =>
    kTrackColors[index % kTrackColors.length];
