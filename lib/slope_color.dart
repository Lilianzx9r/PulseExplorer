import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// slope_color.dart
//
// Échelle de couleur de pente UNIQUE, normalisée sur ±20 %, avec noir aux
// deux extrêmes (montée et descente) — au-delà de 20 %, la pente est
// considérée dangereuse/extrême dans les deux sens.
//
// Utilisée à la fois par elevation_3d_screen.dart (mode "pente" du ruban 3D
// + étiquettes) et route_elevation_profile.dart (ruban 2D incrusté sur la
// carte), pour que les deux vues représentent les pentes avec exactement le
// même code couleur.
//
//   Descente (pente < 0)  : noir (-20%) → bleu (-10%) → vert (0%)
//   Montée   (pente > 0)  : vert (0%) → jaune → orange → rouge (+10%) → noir (+20%)
// ─────────────────────────────────────────────────────────────────────────────

Color gradientColor(double gradientPct) {
  const limit = 20.0; // normalisation ±20 %
  final t = (gradientPct / limit).clamp(-1.0, 1.0);
  if (t < 0) {
    final u = (-t) * 2; // 0 (plat) .. 1 (-10%) .. 2 (-20%)
    if (u <= 1) {
      return Color.lerp(const Color(0xFF00C853), const Color(0xFF2962FF), u)!;
    }
    return Color.lerp(const Color(0xFF2962FF), Colors.black, u - 1)!;
  } else {
    final u = t * 2; // 0 (plat) .. 1 (+10%) .. 2 (+20%)
    if (u <= 1) {
      return _multiLerp(u, [
        const Color(0xFF00C853),
        const Color(0xFFFFD600),
        const Color(0xFFFF6D00),
        const Color(0xFFD50000),
      ]);
    }
    return Color.lerp(const Color(0xFFD50000), Colors.black, u - 1)!;
  }
}

Color _multiLerp(double t, List<Color> colors) {
  final scaled = t.clamp(0.0, 1.0) * (colors.length - 1);
  final idx = scaled.floor().clamp(0, colors.length - 2);
  final frac = scaled - idx;
  return Color.lerp(colors[idx], colors[idx + 1], frac)!;
}
