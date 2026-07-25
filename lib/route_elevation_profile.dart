import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'gpx_parser.dart';
import 'navigation_service.dart';
import 'slope_color.dart';

// ─────────────────────────────────────────────────────────────────────────────
// route_elevation_profile.dart
//
// Profil altimétrique 2D, affiché en incrustation SUR LA CARTE (pas en plein
// écran comme Elevation3DScreen) : un ruban en bas de la carte façon
// Komoot/Strava, avec un curseur qu'on fait glisser au doigt pour voir
// l'altitude/distance à un point donné — et un marqueur qui suit la
// position correspondante sur la carte via [onScrub].
//
// Complémentaire de Elevation3DScreen (vue 3D immersive plein écran) plutôt
// qu'un remplacement : celui-ci reste visible EN NAVIGUANT sur la carte,
// l'autre est une vue dédiée qu'on ouvre à part.
// ─────────────────────────────────────────────────────────────────────────────

class RouteElevationProfile extends StatefulWidget {
  /// Points de la route/trace, dans l'ordre. Les points sans altitude
  /// (`ele == null`) sont ignorés pour le tracé du profil mais comptent pour
  /// la distance cumulée.
  final List<GpxPoint> points;
  /// Appelé en continu pendant le glissement du curseur, avec la position
  /// géographique correspondante — l'appelant peut afficher un marqueur sur
  /// la carte à cette position.
  final ValueChanged<LatLng>? onScrub;
  /// Appelé quand le doigt est relâché (fin du glissement).
  final VoidCallback? onScrubEnd;
  final VoidCallback? onClose;
  final double height;
  /// Fraction (0..1) de la distance déjà parcourue — si fournie, la portion
  /// déjà parcourue est affichée en clair/pleine opacité et la portion
  /// restante est estompée, pour visualiser l'avancée pendant la navigation.
  /// null = pas de distinction (affichage classique, comme hors navigation).
  final double? progressFrac;

  const RouteElevationProfile({
    super.key,
    required this.points,
    this.onScrub,
    this.onScrubEnd,
    this.onClose,
    this.height = 110,
    this.progressFrac,
  });

  @override
  State<RouteElevationProfile> createState() => _RouteElevationProfileState();
}

class _RouteElevationProfileState extends State<RouteElevationProfile> {
  double? _cursorFrac; // 0..1 le long de la route, null = pas de curseur actif

  late List<_ElePoint> _pts = _build();

  @override
  void didUpdateWidget(RouteElevationProfile old) {
    super.didUpdateWidget(old);
    if (old.points != widget.points) _pts = _build();
  }

  List<_ElePoint> _build() {
    final out = <_ElePoint>[];
    double cumDist = 0;
    GpxPoint? prev;
    for (final p in widget.points) {
      if (prev != null) {
        cumDist += NavigationService.distanceM(
            LatLng(prev.lat, prev.lon), LatLng(p.lat, p.lon));
      }
      out.add(_ElePoint(p.lat, p.lon, p.ele, cumDist));
      prev = p;
    }
    // Pente locale (%) — moyenne glissante sur une petite fenêtre pour
    // éviter des valeurs point-à-point trop bruitées.
    for (int i = 0; i < out.length; i++) {
      final i0 = math.max(0, i - 3), i1 = math.min(out.length - 1, i + 3);
      final a = out[i0], b = out[i1];
      final dDist = b.dist - a.dist;
      if (dDist > 0.5 && a.ele != null && b.ele != null) {
        out[i].gradientPct = ((b.ele! - a.ele!) / dDist) * 100;
      }
    }
    return out;
  }

  _ElePoint? get _cursorPoint {
    if (_cursorFrac == null || _pts.isEmpty) return null;
    final totalDist = _pts.last.dist;
    if (totalDist <= 0) return _pts.first;
    final targetDist = _cursorFrac! * totalDist;
    // Recherche du point le plus proche de la distance cible
    _ElePoint best = _pts.first;
    double bestDiff = (best.dist - targetDist).abs();
    for (final p in _pts) {
      final diff = (p.dist - targetDist).abs();
      if (diff < bestDiff) { best = p; bestDiff = diff; }
    }
    return best;
  }

  void _updateCursor(double dx, double width) {
    final frac = (dx / width).clamp(0.0, 1.0);
    setState(() => _cursorFrac = frac);
    final p = _cursorPoint;
    if (p != null) widget.onScrub?.call(LatLng(p.lat, p.lon));
  }

  @override
  Widget build(BuildContext context) {
    final withEle = _pts.where((p) => p.ele != null && p.ele!.isFinite).toList();
    if (withEle.length < 2) {
      // Pas assez de données d'altitude — ne rien afficher plutôt qu'un
      // graphique vide et trompeur.
      return const SizedBox.shrink();
    }

    final minEle = withEle.map((p) => p.ele!).reduce(math.min);
    final maxEle = withEle.map((p) => p.ele!).reduce(math.max);
    double gain = 0, loss = 0;
    for (int i = 1; i < withEle.length; i++) {
      final d = withEle[i].ele! - withEle[i - 1].ele!;
      if (d > 0) gain += d; else loss -= d;
    }
    final totalKm = _pts.last.dist / 1000;
    final cursor = _cursorPoint;

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a1a).withOpacity(0.92),
        border: const Border(top: BorderSide(color: Colors.white24)),
      ),
      child: Column(children: [
        // ── En-tête stats ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 2),
          child: Row(children: [
            const Icon(Icons.terrain, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
            Text('${totalKm.toStringAsFixed(1)} km',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            const Icon(Icons.trending_up, size: 14, color: Colors.greenAccent),
            Text(' +${gain.round()} m', style: const TextStyle(color: Colors.greenAccent, fontSize: 11)),
            const SizedBox(width: 8),
            const Icon(Icons.trending_down, size: 14, color: Colors.redAccent),
            Text(' -${loss.round()} m', style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
            const Spacer(),
            if (cursor != null) ...[
              Text('${cursor.ele?.round() ?? "—"} m  •  ${(cursor.dist / 1000).toStringAsFixed(1)} km'
                  '${cursor.gradientPct.abs() >= 1 ? "  •  ${cursor.gradientPct >= 0 ? "+" : ""}${cursor.gradientPct.round()}%" : ""}',
                  style: const TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
            ],
            if (widget.onClose != null)
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.close, size: 16, color: Colors.white54)),
          ]),
        ),
        // ── Graphique ──────────────────────────────────────────────────────
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) =>
                  _updateCursor(d.localPosition.dx, constraints.maxWidth),
              onHorizontalDragEnd: (_) => widget.onScrubEnd?.call(),
              onTapDown: (d) =>
                  _updateCursor(d.localPosition.dx, constraints.maxWidth),
              onTapUp: (_) => widget.onScrubEnd?.call(),
              child: CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _ProfilePainter(
                  points: withEle,
                  minEle: minEle,
                  maxEle: maxEle,
                  totalDist: _pts.last.dist,
                  cursorFrac: _cursorFrac,
                  progressFrac: widget.progressFrac,
                ),
              ),
            );
          }),
        ),
      ]),
    );
  }
}

/// Bandeau discret affiché pendant la récupération d'altitude via API pour
/// un itinéraire de navigation (voir gpx_only_view.dart::_fetchNavProfile).
class NavProfileLoadingBar extends StatelessWidget {
  const NavProfileLoadingBar({super.key});
  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    color: const Color(0xFF1a1a1a).withOpacity(0.92),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: const Row(children: [
      SizedBox(width: 14, height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber)),
      SizedBox(width: 10),
      Text("Récupération de l'altitude le long de la route…",
          style: TextStyle(color: Colors.white70, fontSize: 11)),
    ]),
  );
}

class _ElePoint {
  final double lat, lon;
  final double? ele;
  final double dist; // distance cumulée depuis le départ, en mètres
  double gradientPct = 0;
  _ElePoint(this.lat, this.lon, this.ele, this.dist);
}

class _ProfilePainter extends CustomPainter {
  final List<_ElePoint> points;
  final double minEle, maxEle, totalDist;
  final double? cursorFrac;
  final double? progressFrac;

  _ProfilePainter({
    required this.points, required this.minEle, required this.maxEle,
    required this.totalDist, required this.cursorFrac, required this.progressFrac,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || totalDist <= 0) return;
    final eleRange = (maxEle - minEle).clamp(1, double.infinity);
    const padTop = 6.0, padBottom = 4.0;
    final chartH = size.height - padTop - padBottom;

    Offset toOffset(_ElePoint p) {
      final x = (p.dist / totalDist) * size.width;
      final y = padTop + chartH - ((p.ele! - minEle) / eleRange) * chartH;
      return Offset(x, y);
    }

    // Remplissage + ligne colorés par pente, segment par segment — même
    // échelle normalisée ±20% que le profil 3D (slope_color.dart), pour
    // une lecture cohérente entre les deux vues.
    for (int i = 0; i < points.length - 1; i++) {
      final a = toOffset(points[i]), b = toOffset(points[i + 1]);
      final color = gradientColor(points[i].gradientPct);

      // Portion déjà parcourue (avant progressFrac) en pleine opacité,
      // portion restante estompée — pour visualiser l'avancée pendant la
      // navigation. Sans progressFrac (hors navigation), opacité normale.
      final segFrac = points[i].dist / totalDist;
      final isTravelled = progressFrac != null && segFrac < progressFrac!;
      final fillOpacity = progressFrac == null ? 0.35 : (isTravelled ? 0.18 : 0.42);
      final lineOpacity = progressFrac == null ? 1.0 : (isTravelled ? 0.35 : 1.0);

      final segFill = ui.Path()
        ..moveTo(a.dx, size.height)
        ..lineTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(b.dx, size.height)
        ..close();
      canvas.drawPath(segFill, Paint()..color = color.withOpacity(fillOpacity));

      canvas.drawLine(a, b, Paint()
        ..color = color.withOpacity(lineOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8);
    }

    // Repère de position actuelle (avancée sur le trajet), distinct du
    // curseur de survol (ambre) — trait blanc avec pastille pleine.
    if (progressFrac != null && progressFrac! > 0 && progressFrac! < 1) {
      final x = progressFrac! * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          Paint()..color = Colors.white..strokeWidth = 2);
      canvas.drawCircle(Offset(x, size.height - 6), 4, Paint()..color = Colors.white);
    }

    // Curseur
    if (cursorFrac != null) {
      final x = cursorFrac! * size.width;
      canvas.drawLine(Offset(x, padTop), Offset(x, size.height),
          Paint()..color = Colors.amber..strokeWidth = 1.2);
      canvas.drawCircle(Offset(x, padTop), 3, Paint()..color = Colors.amber);
    }
  }

  @override
  bool shouldRepaint(covariant _ProfilePainter old) =>
      old.points != points || old.cursorFrac != cursorFrac ||
      old.minEle != minEle || old.maxEle != maxEle ||
      old.progressFrac != progressFrac;
}
