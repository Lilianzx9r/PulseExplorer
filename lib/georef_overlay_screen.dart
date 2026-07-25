import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'gpx_track.dart';
import 'georef_engine.dart';
import 'ocr_georef_service.dart';
import 'georef_overlay_painter.dart';
import 'track_list_panel.dart';
import 'nominatim_helper.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';

class GeorefOverlayScreen extends StatefulWidget {
  final List<GpxTrack>  tracks;
  final List<PoiLayer>  poiLayers;
  final List<PoiFolder> poiFolders;
  final ui.Image        screenshotImage;
  final Uint8List       screenshotBytes;
  final BoundingBox?    hintBbox;

  const GeorefOverlayScreen({
    super.key,
    required this.tracks,
    required this.poiLayers,
    required this.poiFolders,
    required this.screenshotImage,
    required this.screenshotBytes,
    this.hintBbox,
  });

  @override
  State<GeorefOverlayScreen> createState() => _GeorefOverlayScreenState();
}

class _GeorefOverlayScreenState extends State<GeorefOverlayScreen> {

  // ── État OCR / géoréférencement ───────────────────────────────────────────
  bool               _isProcessing  = false;
  String             _statusMessage = 'Appuyez sur 🔍 pour détecter les villes';
  List<DetectedCity> _cities        = [];
  GeoTransform?      _transform;
  double?            _rmsError;

  // ── État UI ───────────────────────────────────────────────────────────────
  bool   _showCities     = true;
  bool   _showGrid       = false;
  bool   _showTrackPanel = false;
  bool   _dragMode       = false;
  bool   _hideLayersForAdd = false; // masquer GPX/POI pour ajout manuel
  Offset _manualOffset   = Offset.zero;
  Offset _dragStart      = Offset.zero;
  Offset _offsetAtDrag   = Offset.zero;
  // Textes OCR bruts (pour recherche par nom)
  List<String> _ocrTexts = [];

  Size get _imgSize => Size(
    widget.screenshotImage.width.toDouble(),
    widget.screenshotImage.height.toDouble(),
  );

  // ── Lance le pipeline OCR + géoréférencement ─────────────────────────────
  Future<void> _runOcr() async {
    setState(() {
      _isProcessing  = true;
      _statusMessage = '🔍 Détection du texte sur la carte...';
      _cities        = [];
      _transform     = null;
    });

    try {
      setState(() => _statusMessage = '📖 Analyse OCR en cours...');

      final result = await OcrGeorefService.processImage(
        widget.screenshotBytes,
        imageSize: _imgSize,
        hintMinLat: widget.hintBbox?.minLat,
        hintMaxLat: widget.hintBbox?.maxLat,
        hintMinLon: widget.hintBbox?.minLon,
        hintMaxLon: widget.hintBbox?.maxLon,
      );

      // Calcul erreur RMS si transform disponible
      double? rms;
      if (result.transform != null && result.cities.length >= 2) {
        final pts = result.cities.map((c) => CalibrationPoint(
          pixel: c.pixelCenter, lat: c.lat, lon: c.lon, cityName: c.name,
        )).toList();
        rms = result.transform!.rmsError(pts, _imgSize);
      }

      // Extraction textes bruts pour suggestion POI
      // (OCR ML Kit retiré — non disponible sur Windows)
      final ocrTexts = <String>[];

      setState(() {
        _cities        = result.cities;
        _transform     = result.transform;
        _rmsError      = rms;
        _statusMessage = result.message;
        _manualOffset  = Offset.zero;
        _ocrTexts      = ocrTexts;
      });

    } catch (e) {
      setState(() => _statusMessage = '❌ Erreur : $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // ── Ajouter un point de calage manuel ────────────────────────────────────
  void _addManualCalibration(Offset tapPosition) async {
    // Masquer les couches pour faciliter la lecture de la carte
    setState(() => _hideLayersForAdd = true);

    final latC  = TextEditingController();
    final lonC  = TextEditingController();
    final nameC = TextEditingController();

    // Pré-remplir avec un texte OCR si disponible
    String? prefilledName;
    if (_ocrTexts.isNotEmpty) {
      prefilledName = await _pickOcrText();
      if (prefilledName != null) nameC.text = prefilledName;
    }

    if (!mounted) { setState(() => _hideLayersForAdd = false); return; }

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('Point de calage'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Pixel : (${tapPosition.dx.toStringAsFixed(0)}, '
                '${tapPosition.dy.toStringAsFixed(0)})',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 8),
            // Suggestions OCR
            if (_ocrTexts.isNotEmpty) ...[
              const Align(alignment: Alignment.centerLeft,
                child: Text('Textes détectés :', style: TextStyle(fontSize: 11, color: Colors.grey))),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4,
                children: _ocrTexts.take(8).map((t) => ActionChip(
                  label: Text(t, style: const TextStyle(fontSize: 11)),
                  onPressed: () => setDlg(() => nameC.text = t),
                )).toList(),
              ),
              const SizedBox(height: 8),
            ],
            TextField(controller: nameC,
              decoration: const InputDecoration(
                  labelText: 'Nom du lieu', border: OutlineInputBorder())),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: latC,
                decoration: const InputDecoration(
                    labelText: 'Latitude', border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: lonC,
                decoration: const InputDecoration(
                    labelText: 'Longitude', border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true))),
            ]),
            const SizedBox(height: 6),
            const Text('💡 lat/lon sur maps.google.com',
                style: TextStyle(fontSize: 10, color: Colors.blue)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                final lat  = double.tryParse(latC.text);
                final lon  = double.tryParse(lonC.text);
                final name = nameC.text.trim();
                if (lat == null || lon == null || name.isEmpty) return;
                Navigator.pop(ctx);
                _addCityPoint(DetectedCity(
                  name: name, pixelCenter: tapPosition,
                  lat: lat, lon: lon, confidence: 1.0,
                ));
              },
              child: const Text('Ajouter'),
            ),
          ],
        );
      }),
    );

    setState(() => _hideLayersForAdd = false);
  }

  // Sélectionner un texte OCR comme suggestion
  Future<String?> _pickOcrText() async {
    return showDialog<String>(context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Choisir un texte détecté'),
        children: [
          ..._ocrTexts.take(12).map((t) => SimpleDialogOption(
            onPressed: () => Navigator.pop(context, t),
            child: Text(t, style: const TextStyle(fontSize: 13)),
          )),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Saisir manuellement',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  void _addCityPoint(DetectedCity city) {
    setState(() => _cities.add(city));
    _recomputeTransform();
  }

  void _recomputeTransform() {
    if (_cities.length < 1) return;
    final pts = _cities.map((c) => CalibrationPoint(
      pixel: c.pixelCenter, lat: c.lat, lon: c.lon, cityName: c.name,
    )).toList();
    final t = GeoRefEngine.compute(pts);
    double? rms;
    if (t != null && pts.length >= 2) rms = t.rmsError(pts, _imgSize);
    setState(() {
      _transform    = t;
      _rmsError     = rms;
      _statusMessage = t != null
          ? '✅ ${_cities.length} point${_cities.length > 1 ? "s" : ""} — tracé recalé'
          : 'Ajoutez encore un point';
      _manualOffset  = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: const Text('Superposition géoréférencée',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        actions: [
          // Villes OCR
          IconButton(
            icon: Icon(_showCities ? Icons.location_on : Icons.location_off,
                color: Colors.amber),
            tooltip: 'Villes détectées',
            onPressed: () => setState(() => _showCities = !_showCities),
          ),
          // Grille
          IconButton(
            icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off,
                color: Colors.white70),
            tooltip: 'Grille',
            onPressed: () => setState(() => _showGrid = !_showGrid),
          ),
          // Tracés
          IconButton(
            icon: Icon(_showTrackPanel ? Icons.layers : Icons.layers_outlined,
                color: Colors.white),
            tooltip: 'Tracés',
            onPressed: () => setState(() => _showTrackPanel = !_showTrackPanel),
          ),
        ],
      ),
      body: Column(children: [

        // ── Barre de statut OCR ──────────────────────────────────────────
        _buildStatusBar(),

        // ── Barre d'outils ───────────────────────────────────────────────
        _buildToolbar(),

        // ── Carte + GPX ──────────────────────────────────────────────────
        Expanded(child: Stack(children: [

          // Mode drag
          if (_dragMode)
            GestureDetector(
              onPanStart: (d) {
                _dragStart    = d.globalPosition;
                _offsetAtDrag = _manualOffset;
              },
              onPanUpdate: (d) => setState(() =>
                  _manualOffset = _offsetAtDrag + (d.globalPosition - _dragStart)),
              onLongPressStart: (d) => _addManualCalibration(d.localPosition),
              child: _buildCanvas(),
            ),

          // Mode zoom
          if (!_dragMode)
            GestureDetector(
              onLongPressStart: (d) => _addManualCalibration(d.localPosition),
              child: InteractiveViewer(
                minScale: 0.5, maxScale: 8.0,
                child: _buildCanvas(),
              ),
            ),

          // Panneau tracés
          if (_showTrackPanel)
            Positioned(top: 8, right: 8, left: 8,
              child: TrackListPanel(
                tracks: widget.tracks,
                onChanged: () => setState(() {}),
                onClear: () => setState(() {
                  widget.tracks.clear();
                  _showTrackPanel = false;
                }),
              ),
            ),

          // Spinner OCR
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(_statusMessage,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ],
              )),
            ),

          // Indicateur mode drag
          if (_dragMode && !_isProcessing)
            Positioned(bottom: 8, left: 0, right: 0,
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '✋ Drag = déplacer  •  Appui long = ajouter point de calage',
                  style: TextStyle(color: Colors.white, fontSize: 11),
                ),
              )),
            ),
        ])),

        // ── Légende ──────────────────────────────────────────────────────
        _buildLegend(),
      ]),
    );
  }

  Widget _buildCanvas() {
    return SizedBox.expand(
      child: CustomPaint(
        painter: GeorefOverlayPainter(
          tracks: _hideLayersForAdd ? [] : widget.tracks,
          screenshotImage: widget.screenshotImage,
          transform: _hideLayersForAdd ? null : _transform,
          cities: (_showCities && !_hideLayersForAdd) ? _cities : [],
          showGrid: _showGrid && !_hideLayersForAdd,
          manualOffset: _manualOffset,
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    Color barColor = Colors.grey.shade200;
    if (_transform != null && _cities.length >= 2) barColor = Colors.green.shade50;
    if (_cities.length == 1) barColor = Colors.orange.shade50;
    if (_statusMessage.startsWith('❌')) barColor = Colors.red.shade50;

    return Container(
      color: barColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Expanded(child: Text(_statusMessage,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis)),
        if (_rmsError != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _rmsError! < 20 ? Colors.green : Colors.orange,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('RMS: ${_rmsError!.toStringAsFixed(1)}px',
                style: const TextStyle(color: Colors.white, fontSize: 10)),
          ),
      ]),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: Colors.grey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(children: [
        // Bouton OCR principal
        FilledButton.icon(
          onPressed: _isProcessing ? null : _runOcr,
          icon: _isProcessing
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.image_search, size: 16),
          label: const Text('Détecter villes', style: TextStyle(fontSize: 12)),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF003580),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
        ),
        const SizedBox(width: 6),
        // Toggle drag/zoom
        _toolBtn(
          icon: _dragMode ? Icons.open_with : Icons.zoom_in,
          label: _dragMode ? 'Drag' : 'Zoom',
          color: _dragMode ? Colors.purple : Colors.blue,
          onTap: () => setState(() => _dragMode = !_dragMode),
        ),
        const SizedBox(width: 6),
        // Reset offset
        if (_manualOffset != Offset.zero)
          _toolBtn(
            icon: Icons.center_focus_strong,
            label: 'Reset',
            color: Colors.teal,
            onTap: () => setState(() => _manualOffset = Offset.zero),
          ),
        const Spacer(),
        // Info villes
        if (_cities.isNotEmpty)
          GestureDetector(
            onTap: _showCitiesDetail,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.shade400),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('📍', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 3),
                Text('${_cities.length} ville${_cities.length > 1 ? "s" : ""}',
                    style: TextStyle(fontSize: 11,
                        color: Colors.amber.shade900,
                        fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
      ]),
    );
  }

  void _showCitiesDetail() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const Text('Villes détectées',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const Spacer(),
            TextButton(
              onPressed: () {
                setState(() { _cities.clear(); _transform = null; _rmsError = null; });
                Navigator.pop(context);
              },
              child: const Text('Tout effacer', style: TextStyle(color: Colors.red)),
            ),
          ]),
        ),
        const Divider(height: 0),
        ..._cities.map((c) => ListTile(
          dense: true,
          leading: const Icon(Icons.location_on, color: Colors.amber, size: 20),
          title: Text(c.name),
          subtitle: Text(
            'Pixel: (${c.pixelCenter.dx.toStringAsFixed(0)}, ${c.pixelCenter.dy.toStringAsFixed(0)})'
            '  •  GPS: ${c.lat.toStringAsFixed(4)}, ${c.lon.toStringAsFixed(4)}',
            style: const TextStyle(fontSize: 10),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete, size: 18, color: Colors.red),
            onPressed: () {
              setState(() => _cities.remove(c));
              _recomputeTransform();
              Navigator.pop(context);
            },
          ),
        )),
        const SizedBox(height: 16),
      ]),
    );
  }

  Widget _buildLegend() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        Expanded(child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            ...widget.tracks.map((t) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 18, height: 3, color: t.color),
                const SizedBox(width: 4),
                Text(t.displayName,
                    style: const TextStyle(fontSize: 10),
                    overflow: TextOverflow.ellipsis),
              ]),
            )),
            if (_showCities && _cities.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.location_on, color: Colors.amber, size: 12),
                const SizedBox(width: 2),
                const Text('Villes calage', style: TextStyle(fontSize: 10)),
              ]),
          ]),
        )),
        Text(_transform != null
            ? '${_cities.length} pts • calé'
            : 'non calé',
            style: TextStyle(
                fontSize: 9,
                color: _transform != null ? Colors.green : Colors.orange)),
      ]),
    );
  }

  Widget _toolBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 11, color: color,
              fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}
