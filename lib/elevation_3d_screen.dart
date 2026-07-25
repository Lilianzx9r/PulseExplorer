import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'gpx_track.dart';
import 'gpx_parser.dart';
import 'navigation_service.dart';
import 'slope_color.dart';

// ─────────────────────────────────────────────────────────────────────────────
// elevation_3d_screen.dart
//
// Profil altimétrique 3D façon VeloViewer : ruban suivant le tracé RÉEL
// projeté au sol (pas une simple ligne droite — les virages du parcours
// sont visibles en 3D), coloré par altitude ou par pente, avec grille au
// sol, ombre portée, annotations de pente le long du tracé, et zoom sur
// une portion du profil. Rotation/zoom tactile.
//
// Le sol (X, Z) est obtenu par projection équirectangulaire locale des
// coordonnées lat/lon autour du centre du tracé — contrairement à la
// version précédente qui alignait tous les points sur une droite (X =
// distance cumulée), ce qui donnait un ruban artificiellement rectiligne
// quel que soit le tracé réel.
// ─────────────────────────────────────────────────────────────────────────────

enum Elevation3DColorMode { altitude, gradient }

class Elevation3DScreen extends StatefulWidget {
  final GpxTrack track;
  const Elevation3DScreen({super.key, required this.track});

  @override
  State<Elevation3DScreen> createState() => _Elevation3DScreenState();
}

class _Elevation3DScreenState extends State<Elevation3DScreen> {
  Elevation3DColorMode _colorMode = Elevation3DColorMode.altitude;
  double _rotationY = -0.6;  // radians — rotation horizontale (autour de l'axe vertical)
  double _rotationX = 0.55;  // inclinaison de la vue (0 = à plat, pi/2 = vue du dessus)
  double _zoom = 1.0;
  double _verticalExaggeration = 3.0; // amplifie le relief pour le rendre visible
  double _ribbonWidth = 14.0;   // épaisseur du ruban (réglable)
  double _labelDensity = 7.0;   // nombre cible d'étiquettes de pente (réglable)

  Offset? _lastPan;

  late final List<_ProfilePoint3D> _points; // TOUS les points du tracé
  double _minEle = 0, _maxEle = 0;

  // ── Zoom sur une portion du profil (0..1 = fraction de la distance totale) ──
  RangeValues _rangeFrac = const RangeValues(0, 1);

  @override
  void initState() {
    super.initState();
    _points = _buildPoints();
  }

  List<_ProfilePoint3D> _buildPoints() {
    final raw = widget.track.data.trackPoints
        .where((p) => p.ele != null && p.ele!.isFinite)
        .toList();
    if (raw.isEmpty) return [];

    _minEle = raw.map((p) => p.ele!).reduce(math.min);
    _maxEle = raw.map((p) => p.ele!).reduce(math.max);
    if (_maxEle == _minEle) _maxEle = _minEle + 1; // évite division par zéro

    // Projection équirectangulaire locale (lat/lon → mètres) centrée sur la
    // bbox du tracé, pour que le ruban 3D suive la forme RÉELLE du parcours
    // au sol plutôt qu'une ligne droite.
    final lat0 = raw.map((p) => p.lat).reduce((a, b) => a + b) / raw.length;
    final lon0 = raw.map((p) => p.lon).reduce((a, b) => a + b) / raw.length;
    final cosLat0 = math.cos(lat0 * math.pi / 180);
    double xmOf(double lon) => (lon - lon0) * cosLat0 * 111320.0;
    double zmOf(double lat) => (lat - lat0) * 110540.0;

    double cumDist = 0;
    final points = <_ProfilePoint3D>[];
    GpxPoint? prev;
    for (final p in raw) {
      if (prev != null) {
        cumDist += NavigationService.distanceM(
            LatLng(prev.lat, prev.lon), LatLng(p.lat, p.lon));
      }
      points.add(_ProfilePoint3D(
        distM: cumDist, ele: p.ele!, lat: p.lat, lon: p.lon,
        xm: xmOf(p.lon), zm: zmOf(p.lat),
      ));
      prev = p;
    }

    // Calcul de la pente locale (%) pour le mode gradient et les annotations
    for (int i = 0; i < points.length; i++) {
      final a = points[math.max(0, i - 1)];
      final b = points[math.min(points.length - 1, i + 1)];
      final dDist = b.distM - a.distM;
      points[i].gradientPct = dDist > 0.5 ? ((b.ele - a.ele) / dDist) * 100 : 0;
    }
    return points;
  }

  /// Sous-ensemble de points correspondant au zoom courant (_rangeFrac).
  List<_ProfilePoint3D> get _visiblePoints {
    if (_points.length < 2) return _points;
    if (_rangeFrac.start <= 0 && _rangeFrac.end >= 1) return _points;
    final totalDist = _points.last.distM;
    final dStart = _rangeFrac.start * totalDist;
    final dEnd = _rangeFrac.end * totalDist;
    final sub = _points.where((p) => p.distM >= dStart && p.distM <= dEnd).toList();
    // Toujours au moins 2 points pour pouvoir dessiner un ruban
    if (sub.length < 2) return _points;
    return sub;
  }

  @override
  Widget build(BuildContext context) {
    if (_points.length < 2) {
      return Scaffold(
        backgroundColor: const Color(0xFF0a1628),
        appBar: AppBar(title: const Text('Profil 3D'),
            backgroundColor: const Color(0xFF003580), foregroundColor: Colors.white),
        body: const Center(child: Text(
            'Ce tracé ne contient pas de données d\'altitude exploitables',
            style: TextStyle(color: Colors.white54), textAlign: TextAlign.center)),
      );
    }

    final visible = _visiblePoints;
    final totalDist = _points.last.distM;
    final visibleDist = visible.last.distM - visible.first.distM;
    final totalAscent = _computeAscent(visible);
    final isZoomed = _rangeFrac.start > 0.001 || _rangeFrac.end < 0.999;

    return Scaffold(
      backgroundColor: const Color(0xFF0a1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: Text(widget.track.displayName,
            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            icon: Icon(_colorMode == Elevation3DColorMode.altitude
                ? Icons.terrain : Icons.trending_up),
            tooltip: _colorMode == Elevation3DColorMode.altitude
                ? 'Colorer par altitude' : 'Colorer par pente',
            onPressed: () => setState(() {
              _colorMode = _colorMode == Elevation3DColorMode.altitude
                  ? Elevation3DColorMode.gradient : Elevation3DColorMode.altitude;
            }),
          ),
        ],
      ),
      body: Column(children: [
        // Statistiques façon VeloViewer (reflètent la portion visible si zoomée)
        Container(
          color: const Color(0xFF0f1e3c),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 18, runSpacing: 4, children: [
            _stat('📏', '${(visibleDist / 1000).toStringAsFixed(1)} km'),
            _stat('⛰️', '${_minEle.round()}–${_maxEle.round()} m'),
            _stat('📈', '+${totalAscent.round()} m D+'),
            _stat(_colorMode == Elevation3DColorMode.altitude ? '🎨' : '📐',
                _colorMode == Elevation3DColorMode.altitude ? 'Altitude' : 'Pente'),
            if (isZoomed)
              GestureDetector(
                onTap: () => setState(() => _rangeFrac = const RangeValues(0, 1)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.zoom_in, size: 14, color: Colors.amber),
                  SizedBox(width: 3),
                  Text('Zoomé — toucher pour réinitialiser',
                      style: TextStyle(color: Colors.amber, fontSize: 11)),
                ]),
              ),
          ]),
        ),

        // Vue 3D interactive
        Expanded(child: GestureDetector(
          onScaleStart: (d) => _lastPan = d.focalPoint,
          onScaleUpdate: (d) {
            setState(() {
              if (d.pointerCount == 1 && _lastPan != null) {
                final delta = d.focalPoint - _lastPan!;
                _rotationY += delta.dx * 0.005;
                _rotationX = (_rotationX - delta.dy * 0.005).clamp(0.1, 1.4);
                _lastPan = d.focalPoint;
              }
              if (d.scale != 1.0) {
                _zoom = (_zoom * d.scale).clamp(0.4, 3.0);
              }
            });
          },
          onScaleEnd: (_) => _lastPan = null,
          child: ClipRect(child: CustomPaint(
            size: Size.infinite,
            painter: _Ribbon3DPainter(
              points: visible,
              minEle: _minEle, maxEle: _maxEle,
              rotationY: _rotationY, rotationX: _rotationX,
              zoom: _zoom, verticalExaggeration: _verticalExaggeration,
              ribbonWidth: _ribbonWidth, labelDensity: _labelDensity,
              colorMode: _colorMode,
            ),
          )),
        )),

        // ── Zoom sur une portion du profil ──────────────────────────────────
        Container(
          color: const Color(0xFF0f1e3c),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            const Icon(Icons.unfold_more, size: 16, color: Colors.white38),
            const SizedBox(width: 8),
            const Text('Zoom', style: TextStyle(color: Colors.white38, fontSize: 11)),
            Expanded(child: RangeSlider(
              values: _rangeFrac, min: 0, max: 1,
              activeColor: Colors.amber, inactiveColor: Colors.white24,
              labels: RangeLabels(
                '${(_rangeFrac.start * totalDist / 1000).toStringAsFixed(1)} km',
                '${(_rangeFrac.end * totalDist / 1000).toStringAsFixed(1)} km',
              ),
              onChanged: (v) => setState(() => _rangeFrac = v),
            )),
          ]),
        ),

        // Contrôles
        Container(
          color: const Color(0xFF0f1e3c),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.height, size: 16, color: Colors.white38),
              const SizedBox(width: 8),
              const SizedBox(width: 34, child: Text('Relief', style: TextStyle(color: Colors.white38, fontSize: 10))),
              Expanded(child: Slider(
                value: _verticalExaggeration, min: 1, max: 8,
                activeColor: Colors.amber, inactiveColor: Colors.white24,
                onChanged: (v) => setState(() => _verticalExaggeration = v),
              )),
            ]),
            Row(children: [
              const Icon(Icons.line_weight, size: 16, color: Colors.white38),
              const SizedBox(width: 8),
              const SizedBox(width: 34, child: Text('Ruban', style: TextStyle(color: Colors.white38, fontSize: 10))),
              Expanded(child: Slider(
                value: _ribbonWidth, min: 4, max: 40,
                activeColor: Colors.amber, inactiveColor: Colors.white24,
                onChanged: (v) => setState(() => _ribbonWidth = v),
              )),
            ]),
            Row(children: [
              const Icon(Icons.label_outline, size: 16, color: Colors.white38),
              const SizedBox(width: 8),
              const SizedBox(width: 34, child: Text('Pentes', style: TextStyle(color: Colors.white38, fontSize: 10))),
              Expanded(child: Slider(
                value: _labelDensity, min: 0, max: 16, divisions: 16,
                activeColor: Colors.amber, inactiveColor: Colors.white24,
                label: _labelDensity == 0 ? 'aucune' : _labelDensity.round().toString(),
                onChanged: (v) => setState(() => _labelDensity = v),
              )),
              TextButton.icon(
                onPressed: () => setState(() {
                  _rotationY = -0.6; _rotationX = 0.55; _zoom = 1.0;
                  _rangeFrac = const RangeValues(0, 1);
                  _ribbonWidth = 14.0; _labelDensity = 7.0;
                }),
                icon: const Icon(Icons.replay, size: 14, color: Colors.white54),
                label: const Text('Réinit.', style: TextStyle(fontSize: 11, color: Colors.white54)),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }

  double _computeAscent(List<_ProfilePoint3D> pts) {
    double asc = 0;
    for (int i = 1; i < pts.length; i++) {
      final d = pts[i].ele - pts[i - 1].ele;
      if (d > 0) asc += d;
    }
    return asc;
  }

  Widget _stat(String emoji, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text(emoji, style: const TextStyle(fontSize: 13)),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
  ]);
}

/// Modèle de point pour le rendu 3D
class _ProfilePoint3D {
  final double distM;
  final double ele;
  final double lat, lon;
  final double xm, zm; // position au sol en mètres (projection locale)
  double gradientPct = 0;
  _ProfilePoint3D({
    required this.distM, required this.ele, required this.lat, required this.lon,
    required this.xm, required this.zm,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter — projection isométrique du ruban altimétrique suivant le
// tracé réel au sol, avec annotations de pente.
// ─────────────────────────────────────────────────────────────────────────────
class _Ribbon3DPainter extends CustomPainter {
  final List<_ProfilePoint3D> points;
  final double minEle, maxEle;
  final double rotationY, rotationX, zoom, verticalExaggeration;
  final double ribbonWidth, labelDensity;
  final Elevation3DColorMode colorMode;

  _Ribbon3DPainter({
    required this.points, required this.minEle, required this.maxEle,
    required this.rotationY, required this.rotationX, required this.zoom,
    required this.verticalExaggeration, required this.colorMode,
    required this.ribbonWidth, required this.labelDensity,
  });

  // Projection isométrique simple : rotation Y puis X, puis projection orthographique
  Offset _project(double x, double y, double z, Size canvasSize) {
    // Rotation autour de Y (horizontal)
    final cosY = math.cos(rotationY), sinY = math.sin(rotationY);
    final x1 = x * cosY - z * sinY;
    final z1 = x * sinY + z * cosY;

    // Rotation autour de X (inclinaison)
    final cosX = math.cos(rotationX), sinX = math.sin(rotationX);
    final y1 = y * cosX - z1 * sinX;
    final z2 = y * sinX + z1 * cosX;

    // Projection orthographique avec petite perspective sur z2
    final scale = 1.0 / (1.0 + z2 * 0.0003);
    final screenX = canvasSize.width / 2 + x1 * zoom * scale;
    final screenY = canvasSize.height / 2 + y1 * zoom * scale;
    return Offset(screenX, screenY);
  }

  Color _colorFor(_ProfilePoint3D p) {
    if (colorMode == Elevation3DColorMode.altitude) {
      final t = ((p.ele - minEle) / (maxEle - minEle)).clamp(0.0, 1.0);
      // Dégradé façon VeloViewer : bleu → vert → jaune → orange → rouge
      return _multiLerp(t, [
        const Color(0xFF2962FF), // bleu (bas)
        const Color(0xFF00C853), // vert
        const Color(0xFFFFD600), // jaune
        const Color(0xFFFF6D00), // orange
        const Color(0xFFD50000), // rouge (haut)
      ]);
    } else {
      return gradientColor(p.gradientPct);
    }
  }

  Color _multiLerp(double t, List<Color> colors) {
    final scaled = t * (colors.length - 1);
    final idx = scaled.floor().clamp(0, colors.length - 2);
    final frac = scaled - idx;
    return Color.lerp(colors[idx], colors[idx + 1], frac)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    // ── Mise à l'échelle du sol (xm, zm) pour tenir dans l'espace virtuel ──
    // Contrairement à l'ancienne version (X = distance cumulée sur une
    // droite), on utilise ici la position géographique réelle : le ruban
    // suit donc les virages du parcours. Mise à l'échelle isotrope (même
    // facteur sur X et Z) pour ne pas déformer la forme du tracé.
    const spanMax = 600.0; // dimension virtuelle max (largeur ou profondeur)
    final ribbonHalfWidth = ribbonWidth; // épaisseur du ruban (réglable, voir contrôles)

    double minXm = points.first.xm, maxXm = points.first.xm;
    double minZm = points.first.zm, maxZm = points.first.zm;
    for (final p in points) {
      if (p.xm < minXm) minXm = p.xm;
      if (p.xm > maxXm) maxXm = p.xm;
      if (p.zm < minZm) minZm = p.zm;
      if (p.zm > maxZm) maxZm = p.zm;
    }
    final extentX = (maxXm - minXm).abs();
    final extentZ = (maxZm - minZm).abs();
    final extent = math.max(extentX, extentZ).clamp(1.0, double.infinity);
    final scale = spanMax / extent;
    final centerXm = (minXm + maxXm) / 2, centerZm = (minZm + maxZm) / 2;

    List<double> xs = [], ys = [], zs = [];
    for (final p in points) {
      xs.add((p.xm - centerXm) * scale);
      zs.add((p.zm - centerZm) * scale);
      final eleNorm = (p.ele - minEle) / (maxEle - minEle == 0 ? 1 : (maxEle - minEle));
      ys.add(-eleNorm * 100 * verticalExaggeration / 3);
    }

    // Décalage perpendiculaire au tracé (tangente locale) pour donner une
    // épaisseur au ruban qui suit la direction réelle du parcours, plutôt
    // qu'un décalage fixe sur un seul axe.
    final frontX = <double>[], frontZ = <double>[], backX = <double>[], backZ = <double>[];
    for (int i = 0; i < points.length; i++) {
      final i0 = math.max(0, i - 1), i1 = math.min(points.length - 1, i + 1);
      double dx = xs[i1] - xs[i0], dz = zs[i1] - zs[i0];
      final len = math.sqrt(dx * dx + dz * dz);
      double px, pz; // perpendiculaire normalisée
      if (len < 1e-6) { px = 0; pz = 1; } else { px = -dz / len; pz = dx / len; }
      frontX.add(xs[i] - px * ribbonHalfWidth);
      frontZ.add(zs[i] - pz * ribbonHalfWidth);
      backX.add(xs[i] + px * ribbonHalfWidth);
      backZ.add(zs[i] + pz * ribbonHalfWidth);
    }

    // Grille au sol (façon VeloViewer)
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(.06)
      ..strokeWidth = 1;
    const groundY = 20.0;
    for (int gx = -3; gx <= 3; gx++) {
      final p1 = _project(gx * spanMax / 6, groundY, -spanMax / 2, size);
      final p2 = _project(gx * spanMax / 6, groundY, spanMax / 2, size);
      canvas.drawLine(p1, p2, gridPaint);
    }
    for (int gz = -3; gz <= 3; gz++) {
      final p1 = _project(-spanMax / 2, groundY, gz * spanMax / 6, size);
      final p2 = _project(spanMax / 2, groundY, gz * spanMax / 6, size);
      canvas.drawLine(p1, p2, gridPaint);
    }

    // Ombre portée au sol (silhouette assombrie, suit maintenant la forme réelle)
    final shadowPath = ui.Path();
    for (int i = 0; i < points.length; i++) {
      final pt = _project(frontX[i], groundY, frontZ[i], size);
      if (i == 0) shadowPath.moveTo(pt.dx, pt.dy); else shadowPath.lineTo(pt.dx, pt.dy);
    }
    for (int i = points.length - 1; i >= 0; i--) {
      final pt = _project(backX[i], groundY, backZ[i], size);
      shadowPath.lineTo(pt.dx, pt.dy);
    }
    shadowPath.close();
    canvas.drawPath(shadowPath, Paint()..color = Colors.black.withOpacity(.25));

    // Ruban 3D : quads colorés entre points consécutifs (face dessus + face avant)
    for (int i = 0; i < points.length - 1; i++) {
      final color = Color.lerp(_colorFor(points[i]), _colorFor(points[i + 1]), 0.5)!;

      final ptA = _project(frontX[i], ys[i], frontZ[i], size);
      final ptB = _project(frontX[i + 1], ys[i + 1], frontZ[i + 1], size);
      final ptC = _project(backX[i + 1], ys[i + 1], backZ[i + 1], size);
      final ptD = _project(backX[i], ys[i], backZ[i], size);
      final topPath = ui.Path()
        ..moveTo(ptA.dx, ptA.dy)
        ..lineTo(ptB.dx, ptB.dy)
        ..lineTo(ptC.dx, ptC.dy)
        ..lineTo(ptD.dx, ptD.dy)
        ..close();
      canvas.drawPath(topPath, Paint()..color = color);

      // Face avant (paroi verticale côté "front", légèrement assombrie)
      final frontPath = ui.Path();
      final ptGroundA = _project(frontX[i], groundY, frontZ[i], size);
      final ptGroundB = _project(frontX[i + 1], groundY, frontZ[i + 1], size);
      frontPath
        ..moveTo(ptA.dx, ptA.dy)
        ..lineTo(ptB.dx, ptB.dy)
        ..lineTo(ptGroundB.dx, ptGroundB.dy)
        ..lineTo(ptGroundA.dx, ptGroundA.dy)
        ..close();
      canvas.drawPath(frontPath, Paint()..color = _darken(color, .35));
    }

    // Contour supérieur (ligne de crête, côté front)
    final ridgePath = ui.Path();
    for (int i = 0; i < points.length; i++) {
      final pt = _project(frontX[i], ys[i], frontZ[i], size);
      if (i == 0) ridgePath.moveTo(pt.dx, pt.dy); else ridgePath.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(ridgePath, Paint()
      ..color = Colors.white.withOpacity(.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);

    // ── Annotations de pente le long du tracé ───────────────────────────────
    _drawSlopeLabels(canvas, size, xs, ys, zs);
  }

  /// Affiche le % de pente à intervalles réguliers le long du tracé —
  /// moyenne glissante sur une petite fenêtre pour éviter des valeurs trop
  /// bruitées point-à-point.
  void _drawSlopeLabels(Canvas canvas, Size size, List<double> xs, List<double> ys, List<double> zs) {
    if (points.length < 4) return;
    final targetLabelCount = labelDensity.round();
    if (targetLabelCount <= 0) return; // densité à 0 = étiquettes désactivées
    final totalDist = points.last.distM - points.first.distM;
    if (totalDist <= 0) return;
    final windowDist = totalDist / targetLabelCount;

    // Moyenne glissante de la pente (fenêtre ±3 points) pour chaque point,
    // pour lisser le bruit avant de chercher le maximum par fenêtre.
    final avgGrad = List<double>.filled(points.length, 0);
    for (int i = 0; i < points.length; i++) {
      final i0 = math.max(0, i - 3), i1 = math.min(points.length - 1, i + 3);
      double sum = 0; int n = 0;
      for (int k = i0; k <= i1; k++) { sum += points[k].gradientPct; n++; }
      avgGrad[i] = n > 0 ? sum / n : 0.0;
    }

    // Le pic global (montée OU descente la plus marquée du tracé affiché)
    // est mis en évidence par une étiquette plus grande — "identifier les
    // parties les plus importantes".
    int steepestIdx = 0;
    for (int i = 1; i < points.length; i++) {
      if (avgGrad[i].abs() > avgGrad[steepestIdx].abs()) steepestIdx = i;
    }

    double windowStart = points.first.distM;
    while (windowStart < points.last.distM) {
      final windowEnd = windowStart + windowDist;
      // Point le plus raide (en valeur absolue) DANS cette fenêtre de
      // distance — plutôt qu'un point arbitraire au milieu de la fenêtre,
      // ça garantit que l'étiquette pointe vers le passage le plus
      // significatif de ce tronçon du profil, pas un point moyen anodin.
      int bestIdx = -1;
      for (int i = 0; i < points.length; i++) {
        if (points[i].distM < windowStart || points[i].distM > windowEnd) continue;
        if (bestIdx == -1 || avgGrad[i].abs() > avgGrad[bestIdx].abs()) bestIdx = i;
      }
      windowStart = windowEnd;
      if (bestIdx == -1) continue;
      final grad = avgGrad[bestIdx];
      if (grad.abs() < 1.5) continue; // pas d'étiquette sur le quasi-plat

      final isPeak = bestIdx == steepestIdx && grad.abs() >= 6;
      final labelColor = gradientColor(grad);
      final anchor = _project(xs[bestIdx], ys[bestIdx], zs[bestIdx], size);
      final label = '${isPeak ? "⚠ " : ""}${grad >= 0 ? "+" : ""}${grad.round()}%';

      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(
          color: Colors.white, fontSize: isPeak ? 13 : 11,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: labelColor.withOpacity(.9), blurRadius: 3)],
        )),
        textDirection: TextDirection.ltr,
      )..layout();

      final bgRect = Rect.fromCenter(
        center: anchor.translate(0, isPeak ? -20 : -16),
        width: tp.width + (isPeak ? 12 : 8), height: tp.height + (isPeak ? 6 : 4),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bgRect, const Radius.circular(4)),
        Paint()..color = labelColor.withOpacity(isPeak ? 0.95 : .85));
      if (isPeak) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(bgRect.inflate(1.5), const Radius.circular(5)),
          Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.2);
      }
      tp.paint(canvas, bgRect.topLeft + Offset(isPeak ? 6 : 4, isPeak ? 3 : 2));
    }
  }

  Color _darken(Color c, double amount) => Color.lerp(c, Colors.black, amount)!;

  @override
  bool shouldRepaint(covariant _Ribbon3DPainter old) =>
      old.points != points ||
      old.rotationY != rotationY || old.rotationX != rotationX ||
      old.zoom != zoom || old.verticalExaggeration != verticalExaggeration ||
      old.colorMode != colorMode ||
      old.ribbonWidth != ribbonWidth || old.labelDensity != labelDensity;
}
