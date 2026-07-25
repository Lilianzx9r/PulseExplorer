import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'georef_engine.dart';
import 'poi_layer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Résultat du calage
// ─────────────────────────────────────────────────────────────────────────────
class CalibrationResult {
  final GeoTransform  transform;
  final List<CalibrationPoint> points;
  final double        rmsPixels;

  CalibrationResult({
    required this.transform,
    required this.points,
    required this.rmsPixels,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Écran de calage : OCR + tap manuel
// ─────────────────────────────────────────────────────────────────────────────
class MapCalibrationScreen extends StatefulWidget {
  final Uint8List      screenshotBytes;
  final ui.Image       screenshotImage;
  final List<PoiPoint> knownPois;   // POI avec coordonnées GPS connues

  const MapCalibrationScreen({
    super.key,
    required this.screenshotBytes,
    required this.screenshotImage,
    required this.knownPois,
  });

  @override
  State<MapCalibrationScreen> createState() => _MapCalibrationScreenState();
}

class _MapCalibrationScreenState extends State<MapCalibrationScreen> {

  // Points de calage confirmés
  final List<CalibrationPoint> _calibPoints = [];

  // Textes détectés par OCR (non encore associés)
  final List<_OcrText> _ocrTexts = [];

  // État
  bool    _isOcrRunning  = false;
  bool    _isSearching   = false;
  String  _status        = 'Appuyez sur "OCR" pour détecter les villes automatiquement';

  // Mode tap : attente d'un tap pour positionner un POI
  PoiPoint? _pendingPoi;   // POI à positionner par tap

  // Transformation courante (recalculée en temps réel)
  GeoTransform? _transform;
  double?       _rms;

  // Échelle d'affichage (image → écran)
  double _scale = 1.0;
  Offset _imgOffset = Offset.zero;

  final GlobalKey _canvasKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Lancer OCR automatiquement au démarrage
    WidgetsBinding.instance.addPostFrameCallback((_) => _runOcr());
  }

  // ── OCR via ML Kit ─────────────────────────────────────────────────────────
  // ML Kit retiré (incompatible Windows). Le calage se fait manuellement.
  Future<void> _runOcr() async {
    setState(() {
      _isOcrRunning = false;
      _status = 'OCR automatique non disponible — '
                'tapez sur un point de la carte puis saisissez les coordonnées.';
    });
  }

  // ── Association automatique OCR ↔ POI connus ───────────────────────────────
  Future<void> _autoAssociate() async {
    setState(() { _isSearching = true; });
    int found = 0;

    for (final ocr in _ocrTexts) {
      // Normaliser : supprimer accents, lowercase
      final ocrNorm = _normalize(ocr.text);

      for (final poi in widget.knownPois) {
        final poiNorm = _normalize(poi.name.split(',').first);

        // Correspondance exacte ou début de mot
        if (ocrNorm == poiNorm ||
            poiNorm.startsWith(ocrNorm) ||
            ocrNorm.startsWith(poiNorm)) {

          // Vérifier pas déjà ajouté
          final alreadyAdded = _calibPoints.any((p) =>
              (p.lat - poi.lat).abs() < 0.001 && (p.lon - poi.lon).abs() < 0.001);
          if (alreadyAdded) continue;

          _calibPoints.add(CalibrationPoint(
            pixel:    ocr.center,
            lat:      poi.lat,
            lon:      poi.lon,
            cityName: poi.name,
          ));
          found++;
          break;
        }
      }
    }

    _recompute();
    setState(() {
      _isSearching = false;
      _status = found > 0
          ? '✅ $found ville${found > 1 ? "s" : ""} associée${found > 1 ? "s" : ""} automatiquement'
              '${_calibPoints.length >= 3 ? " — calage possible !" : " — ajoutez encore ${3 - _calibPoints.length} point(s)"}'
          : 'Aucune association auto — tapez sur les villes manuellement';
    });
  }

  // ── Normalisation pour comparaison ────────────────────────────────────────
  String _normalize(String s) {
    return s.toLowerCase()
        .replaceAll(RegExp(r'[àáâãäå]'), 'a')
        .replaceAll(RegExp(r'[èéêë]'),   'e')
        .replaceAll(RegExp(r'[ìíîï]'),   'i')
        .replaceAll(RegExp(r'[òóôõö]'),  'o')
        .replaceAll(RegExp(r'[ùúûü]'),   'u')
        .replaceAll(RegExp(r'[ç]'),      'c')
        .replaceAll(RegExp(r'[ñ]'),      'n')
        .trim();
  }

  // ── Recalcul transformation ────────────────────────────────────────────────
  void _recompute() {
    if (_calibPoints.length < 2) {
      setState(() { _transform = null; _rms = null; });
      return;
    }
    final t = GeoRefEngine.compute(_calibPoints);
    double? rms;
    if (t != null && _calibPoints.length >= 2) {
      final imgSize = Size(
        widget.screenshotImage.width.toDouble(),
        widget.screenshotImage.height.toDouble(),
      );
      rms = t.rmsError(_calibPoints, imgSize);
    }
    setState(() { _transform = t; _rms = rms; });
  }

  // ── Tap sur la carte pour positionner un POI manuellement ─────────────────
  void _onTapCanvas(TapDownDetails details) {
    // Convertir position écran → position image
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local  = box.globalToLocal(details.globalPosition);
    final imgPx  = _screenToImage(local);

    if (_pendingPoi != null) {
      // Associer ce tap au POI en attente
      final poi = _pendingPoi!;
      setState(() {
        _calibPoints.add(CalibrationPoint(
          pixel: imgPx, lat: poi.lat, lon: poi.lon, cityName: poi.name));
        _pendingPoi = null;
        _status = 'Point ajouté : ${poi.name}';
      });
      _recompute();
      return;
    }

    // Chercher si un texte OCR est proche du tap
    final nearby = _ocrTexts.where((o) {
      final screenPx = _imageToScreen(o.center);
      return (screenPx - local).distance < 30;
    }).toList();

    if (nearby.isNotEmpty) {
      _showAssociateDialog(nearby.first, imgPx);
    } else {
      _showAddManualDialog(imgPx);
    }
  }

  // Convertit pixel écran → pixel image
  Offset _screenToImage(Offset screen) {
    return Offset(
      (screen.dx - _imgOffset.dx) / _scale,
      (screen.dy - _imgOffset.dy) / _scale,
    );
  }

  // Convertit pixel image → pixel écran
  Offset _imageToScreen(Offset img) {
    return Offset(
      img.dx * _scale + _imgOffset.dx,
      img.dy * _scale + _imgOffset.dy,
    );
  }

  // Dialog : associer un texte OCR à un POI connu
  void _showAssociateDialog(_OcrText ocr, Offset imgPx) {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: Text('Texte détecté : "${ocr.text}"'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Associer à quel POI ?', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        ...widget.knownPois.take(10).map((poi) => ListTile(
          dense: true,
          title: Text(poi.name, style: const TextStyle(fontSize: 12)),
          subtitle: Text('${poi.lat.toStringAsFixed(4)}, ${poi.lon.toStringAsFixed(4)}',
              style: const TextStyle(fontSize: 10)),
          onTap: () {
            Navigator.pop(context);
            setState(() => _calibPoints.add(CalibrationPoint(
              pixel: imgPx, lat: poi.lat, lon: poi.lon, cityName: poi.name)));
            _recompute();
          },
        )),
        const Divider(),
        ListTile(
          dense: true,
          leading: const Icon(Icons.add, color: Colors.blue),
          title: const Text('Saisir coordonnées manuellement',
              style: TextStyle(fontSize: 12)),
          onTap: () {
            Navigator.pop(context);
            _showAddManualDialog(imgPx);
          },
        ),
      ]),
    ));
  }

  // Dialog : saisie manuelle lat/lon
  void _showAddManualDialog(Offset imgPx) {
    final latC  = TextEditingController();
    final lonC  = TextEditingController();
    final nameC = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Point de calage manuel'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Position : (${imgPx.dx.toStringAsFixed(0)}, ${imgPx.dy.toStringAsFixed(0)})',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(controller: nameC,
            decoration: const InputDecoration(labelText: 'Nom', border: OutlineInputBorder())),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: TextField(controller: latC,
              decoration: const InputDecoration(labelText: 'Lat', border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true))),
          const SizedBox(width: 6),
          Expanded(child: TextField(controller: lonC,
              decoration: const InputDecoration(labelText: 'Lon', border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true))),
        ]),
        const SizedBox(height: 4),
        const Text('💡 Lat/Lon depuis maps.google.com',
            style: TextStyle(fontSize: 10, color: Colors.blue)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: () {
          final lat  = double.tryParse(latC.text);
          final lon  = double.tryParse(lonC.text);
          if (lat == null || lon == null) return;
          Navigator.pop(context);
          setState(() => _calibPoints.add(CalibrationPoint(
            pixel: imgPx, lat: lat, lon: lon,
            cityName: nameC.text.trim().isEmpty ? 'Point manuel' : nameC.text.trim(),
          )));
          _recompute();
        }, child: const Text('Ajouter')),
      ],
    ));
  }

  // ── Choix d'un POI à positionner par tap ──────────────────────────────────
  void _selectPoiForTap() {
    final remaining = widget.knownPois.where((poi) =>
        !_calibPoints.any((cp) =>
            (cp.lat - poi.lat).abs() < 0.001 &&
            (cp.lon - poi.lon).abs() < 0.001)).toList();

    if (remaining.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tous les POI ont déjà été positionnés')));
      return;
    }

    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Quel lieu positionner ?'),
      content: Column(mainAxisSize: MainAxisSize.min,
        children: remaining.take(8).map((poi) => ListTile(
          dense: true,
          leading: const Icon(Icons.location_on, color: Colors.blue, size: 18),
          title: Text(poi.name, style: const TextStyle(fontSize: 13)),
          subtitle: Text('${poi.lat.toStringAsFixed(4)}, ${poi.lon.toStringAsFixed(4)}',
              style: const TextStyle(fontSize: 10)),
          onTap: () {
            Navigator.pop(context);
            setState(() {
              _pendingPoi = poi;
              _status = '👆 Tapez sur "${poi.name}" dans la carte';
            });
          },
        )).toList(),
      ),
    ));
  }

  // ── Confirmer et retourner le résultat ────────────────────────────────────
  void _confirm() {
    if (_transform == null || _calibPoints.length < 3) return;
    Navigator.pop(context, CalibrationResult(
      transform: _transform!,
      points:    List.from(_calibPoints),
      rmsPixels: _rms ?? 0,
    ));
  }

  // ─────────────────────────────── BUILD ────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Calage carte', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text('${_calibPoints.length} point${_calibPoints.length > 1 ? "s" : ""}${_transform != null ? " — calé ✅" : ""}',
              style: const TextStyle(fontSize: 10, color: Colors.white70)),
        ]),
        actions: [
          // Lancer OCR
          IconButton(
            icon: _isOcrRunning
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.document_scanner),
            tooltip: 'Relancer OCR',
            onPressed: _isOcrRunning ? null : _runOcr,
          ),
          // Ajouter point par tap
          IconButton(
            icon: Icon(_pendingPoi != null
                ? Icons.touch_app : Icons.add_location,
                color: _pendingPoi != null ? Colors.amber : Colors.white),
            tooltip: 'Positionner un POI par tap',
            onPressed: _selectPoiForTap,
          ),
          // Confirmer
          if (_calibPoints.length >= 3)
            FilledButton(
              onPressed: _confirm,
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Appliquer'),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [

        // ── Barre de statut ────────────────────────────────────────────────
        Container(
          color: _transform != null
              ? (_rms != null && _rms! < 20 ? Colors.green.shade50 : Colors.orange.shade50)
              : Colors.blue.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Expanded(child: Text(_status,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis)),
            if (_rms != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _rms! < 20 ? Colors.green : _rms! < 50 ? Colors.orange : Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('RMS: ${_rms!.toStringAsFixed(1)}px',
                    style: const TextStyle(color: Colors.white, fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
          ]),
        ),

        // ── Carte interactive ──────────────────────────────────────────────
        Expanded(
          child: LayoutBuilder(builder: (ctx, constraints) {
            // Calculer scale pour fit l'image dans la zone
            final imgW = widget.screenshotImage.width.toDouble();
            final imgH = widget.screenshotImage.height.toDouble();
            _scale = (constraints.maxWidth / imgW)
                .clamp(0.1, constraints.maxHeight / imgH);
            final displayW = imgW * _scale;
            final displayH = imgH * _scale;
            _imgOffset = Offset(
              (constraints.maxWidth  - displayW) / 2,
              (constraints.maxHeight - displayH) / 2,
            );

            return GestureDetector(
              key: _canvasKey,
              onTapDown: _onTapCanvas,
              child: CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _CalibPainter(
                  image:       widget.screenshotImage,
                  scale:       _scale,
                  imgOffset:   _imgOffset,
                  calibPoints: _calibPoints,
                  ocrTexts:    _ocrTexts,
                  pendingPoi:  _pendingPoi,
                ),
              ),
            );
          }),
        ),

        // ── Liste des points de calage ─────────────────────────────────────
        if (_calibPoints.isNotEmpty)
          Container(
            color: Colors.grey.shade50,
            constraints: const BoxConstraints(maxHeight: 140),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(children: [
                  Text('Points de calage (${_calibPoints.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const Spacer(),
                  if (_calibPoints.length < 3)
                    Text('Encore ${3 - _calibPoints.length} nécessaire(s)',
                        style: TextStyle(fontSize: 11, color: Colors.orange.shade700)),
                ]),
              ),
              Flexible(child: ListView.builder(
                shrinkWrap: true,
                itemCount: _calibPoints.length,
                itemBuilder: (ctx, i) {
                  final p = _calibPoints[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 12,
                      backgroundColor: _pointColor(i),
                      child: Text('${i+1}', style: const TextStyle(
                          color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(p.cityName,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                    subtitle: Text(
                      'Pixel: (${p.pixel.dx.toStringAsFixed(0)}, ${p.pixel.dy.toStringAsFixed(0)})'
                      '  GPS: ${p.lat.toStringAsFixed(4)}, ${p.lon.toStringAsFixed(4)}',
                      style: const TextStyle(fontSize: 10),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, size: 16, color: Colors.red),
                      onPressed: () {
                        setState(() => _calibPoints.removeAt(i));
                        _recompute();
                      },
                    ),
                  );
                },
              )),
            ]),
          ),
      ]),
    );
  }

  Color _pointColor(int i) {
    const colors = [Colors.red, Colors.blue, Colors.green,
        Colors.purple, Colors.orange, Colors.teal];
    return colors[i % colors.length];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter de la carte de calage
// ─────────────────────────────────────────────────────────────────────────────
class _OcrText {
  final String text;
  final Offset center;
  final Rect   bounds;
  _OcrText({required this.text, required this.center, required this.bounds});
}

class _CalibPainter extends CustomPainter {
  final ui.Image            image;
  final double              scale;
  final Offset              imgOffset;
  final List<CalibrationPoint> calibPoints;
  final List<_OcrText>      ocrTexts;
  final PoiPoint?           pendingPoi;

  _CalibPainter({
    required this.image,
    required this.scale,
    required this.imgOffset,
    required this.calibPoints,
    required this.ocrTexts,
    required this.pendingPoi,
  });

  Offset _toScreen(Offset imgPx) =>
      Offset(imgPx.dx * scale + imgOffset.dx, imgPx.dy * scale + imgOffset.dy);

  @override
  void paint(Canvas canvas, Size size) {
    // Fond image
    final src = Rect.fromLTWH(0, 0,
        image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(imgOffset.dx, imgOffset.dy,
        image.width * scale, image.height * scale);
    canvas.drawImageRect(image, src, dst, Paint());

    // Surlignage des textes OCR détectés (en jaune pâle)
    for (final ocr in ocrTexts) {
      final screenBounds = Rect.fromLTWH(
        ocr.bounds.left   * scale + imgOffset.dx,
        ocr.bounds.top    * scale + imgOffset.dy,
        ocr.bounds.width  * scale,
        ocr.bounds.height * scale,
      );
      canvas.drawRect(screenBounds,
          Paint()..color = Colors.yellow.withOpacity(0.35));
      canvas.drawRect(screenBounds,
          Paint()
            ..color = Colors.amber
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0);
    }

    // Points de calage confirmés
    final colors = [Colors.red, Colors.blue, Colors.green,
        Colors.purple, Colors.orange, Colors.teal];

    for (int i = 0; i < calibPoints.length; i++) {
      final p      = calibPoints[i];
      final screen = _toScreen(p.pixel);
      final color  = colors[i % colors.length];

      // Croix
      canvas.drawLine(Offset(screen.dx - 14, screen.dy),
          Offset(screen.dx + 14, screen.dy),
          Paint()..color = Colors.white..strokeWidth = 3.0);
      canvas.drawLine(Offset(screen.dx, screen.dy - 14),
          Offset(screen.dx, screen.dy + 14),
          Paint()..color = Colors.white..strokeWidth = 3.0);
      canvas.drawLine(Offset(screen.dx - 12, screen.dy),
          Offset(screen.dx + 12, screen.dy),
          Paint()..color = color..strokeWidth = 2.0);
      canvas.drawLine(Offset(screen.dx, screen.dy - 12),
          Offset(screen.dx, screen.dy + 12),
          Paint()..color = color..strokeWidth = 2.0);

      // Cercle
      canvas.drawCircle(screen, 10,
          Paint()..color = color.withOpacity(0.3));
      canvas.drawCircle(screen, 10,
          Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.0);

      // Numéro
      final tp = TextPainter(
        text: TextSpan(text: '${i+1}',
            style: TextStyle(color: color, fontSize: 11,
                fontWeight: FontWeight.bold,
                shadows: const [Shadow(color: Colors.white, blurRadius: 3)])),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(screen.dx + 12, screen.dy - tp.height / 2));

      // Nom
      final nameTp = TextPainter(
        text: TextSpan(text: p.cityName,
            style: TextStyle(color: Colors.white, fontSize: 10,
                fontWeight: FontWeight.bold,
                background: Paint()..color = color.withOpacity(0.8))),
        textDirection: TextDirection.ltr,
      )..layout();
      nameTp.paint(canvas, Offset(screen.dx + 12, screen.dy + 4));
    }

    // Indicateur POI en attente de tap
    if (pendingPoi != null) {
      // Overlay semi-transparent
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = Colors.black.withOpacity(0.15));

      // Message central
      final tp = TextPainter(
        text: TextSpan(
          text: '👆 Tapez sur "${pendingPoi!.name}"',
          style: const TextStyle(color: Colors.white, fontSize: 16,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 32);
      tp.paint(canvas, Offset((size.width - tp.width) / 2, 40));
    }
  }

  @override
  bool shouldRepaint(_CalibPainter old) =>
      old.calibPoints.length != calibPoints.length ||
      old.ocrTexts.length != ocrTexts.length ||
      old.pendingPoi != pendingPoi;
}
