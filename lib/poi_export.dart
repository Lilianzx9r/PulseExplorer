import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'poi_layer.dart';
import 'gpx_track.dart';
import 'app_dirs.dart';

enum ExportFormat { gpx, kml, geojson, csv }

class PoiExporter {

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;').replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _ext(ExportFormat f) =>
      const {ExportFormat.gpx:'gpx', ExportFormat.kml:'kml',
             ExportFormat.geojson:'geojson', ExportFormat.csv:'csv'}[f]!;

  static const Map<String, String> _kmlIcons = {
    'city':       'http://maps.google.com/mapfiles/kml/shapes/city.png',
    'hotel':      'http://maps.google.com/mapfiles/kml/shapes/lodging.png',
    'restaurant': 'http://maps.google.com/mapfiles/kml/shapes/dining.png',
    'nature':     'http://maps.google.com/mapfiles/kml/shapes/parks.png',
    'poi':        'http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png',
  };

  // ── Export principal ───────────────────────────────────────────────────────
  static Future<String> export(
    List<PoiLayer>  layers,
    ExportFormat    format, {
    List<GpxTrack>? tracks,
    String?         fileName,
  }) async {
    final allPoi = layers.where((l) => l.visible)
        .expand((l) => l.points).toList();
    if (allPoi.isEmpty && (tracks == null || tracks.isEmpty)) {
      throw Exception('Aucune donnée visible à exporter');
    }

    final content = _buildContent(layers, allPoi, format, tracks: tracks);
    final name    = (fileName?.isNotEmpty == true ? fileName! : 'export') + '.${_ext(format)}';
    final dirPath = await AppDirs.exportDir();
    AppDirs.setLastExportDir(dirPath);
    final file    = File('$dirPath/$name');
    await file.writeAsString(content, encoding: utf8);
    return file.path;
  }

  static String _buildContent(
      List<PoiLayer> layers, List<PoiPoint> pts, ExportFormat fmt,
      {List<GpxTrack>? tracks}) {
    switch (fmt) {
      case ExportFormat.gpx:     return _toGpx(pts, tracks: tracks);
      case ExportFormat.kml:     return _toKml(pts, tracks: tracks);
      case ExportFormat.geojson: return _toGeoJson(pts, tracks: tracks);
      case ExportFormat.csv:     return _toCsv(pts);
    }
  }

  // ── GPX ───────────────────────────────────────────────────────────────────
  static String _toGpx(List<PoiPoint> pts, {List<GpxTrack>? tracks}) {
    final now = DateTime.now().toUtc().toIso8601String();
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<gpx version="1.1" creator="PulseGpx"');
    buf.writeln('  xmlns="http://www.topografix.com/GPX/1/1"');
    buf.writeln('  xmlns:pulsegpx="https://pulsegpx.app/extensions">');
    buf.writeln('  <metadata><name>PulseGpx Export</name><time>$now</time></metadata>');

    // Waypoints (POI)
    for (final poi in pts) {
      buf.writeln('  <wpt lat="${poi.lat}" lon="${poi.lon}">');
      buf.writeln('    <name>${_xmlEscape(poi.name)}</name>');
      if (poi.description != null && poi.description!.isNotEmpty) {
        // Filtrer les tags [img:...] de la description
        final desc = poi.description!
            .replaceAll(RegExp(r'\[img:[^\]]+\]'), '').trim();
        if (desc.isNotEmpty)
          buf.writeln('    <desc>${_xmlEscape(desc)}</desc>');
      }
      if (poi.type != null) buf.writeln('    <type>${_xmlEscape(poi.type!)}</type>');

      // Extension PulseGpx : photos
      final allPhotos = [...poi.localPhotos, ...poi.photoUrls];
      // Récupérer les images de la description
      final descImgs  = RegExp(r'\[img:([^\]]+)\]')
          .allMatches(poi.description ?? '')
          .map((m) => m.group(1)!)
          .toList();
      final allMedia  = {...allPhotos, ...descImgs}.toList();
      if (allMedia.isNotEmpty) {
        buf.writeln('    <extensions>');
        buf.writeln('      <pulsegpx:photos>');
        for (final p in allMedia) {
          buf.writeln('        <pulsegpx:photo>${_xmlEscape(p)}</pulsegpx:photo>');
        }
        buf.writeln('      </pulsegpx:photos>');
        buf.writeln('    </extensions>');
      }
      buf.writeln('  </wpt>');
    }

    // Tracés GPX
    if (tracks != null) {
      for (final track in tracks) {
        if (!track.visible || track.data.trackPoints.isEmpty) continue;
        buf.writeln('  <trk>');
        buf.writeln('    <name>${_xmlEscape(track.displayName)}</name>');
        buf.writeln('    <trkseg>');
        for (final pt in track.data.trackPoints) {
          buf.write('      <trkpt lat="${pt.lat}" lon="${pt.lon}">');
          if (pt.ele != null) buf.write('<ele>${pt.ele}</ele>');
          buf.writeln('</trkpt>');
        }
        buf.writeln('    </trkseg>');
        buf.writeln('  </trk>');
        // Waypoints du tracé
        for (final wp in track.data.waypoints) {
          buf.writeln('  <wpt lat="${wp.lat}" lon="${wp.lon}">');
          buf.writeln('    <name>${_xmlEscape(wp.name ?? "")}</name>');
          buf.writeln('  </wpt>');
        }
      }
    }

    buf.writeln('</gpx>');
    return buf.toString();
  }

  // ── KML ───────────────────────────────────────────────────────────────────
  static String _toKml(List<PoiPoint> pts, {List<GpxTrack>? tracks}) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    buf.writeln('<Document><name>PulseGpx Export</name>');

    for (final e in _kmlIcons.entries) {
      buf.writeln('<Style id="style_${e.key}">');
      buf.writeln('  <IconStyle><Icon><href>${e.value}</href></Icon></IconStyle>');
      buf.writeln('</Style>');
    }

    // POI
    for (final poi in pts) {
      buf.writeln('<Placemark>');
      buf.writeln('  <name>${_xmlEscape(poi.name)}</name>');

      // Description + photos en HTML
      final descParts = <String>[];
      if (poi.description != null) {
        final text = poi.description!
            .replaceAll(RegExp(r'\[img:[^\]]+\]'), '').trim();
        if (text.isNotEmpty) descParts.add(_xmlEscape(text));
      }
      final allMedia = [...poi.localPhotos, ...poi.photoUrls,
        ...RegExp(r'\[img:([^\]]+)\]')
            .allMatches(poi.description ?? '')
            .map((m) => m.group(1)!)];
      for (final p in allMedia) {
        if (p.startsWith('http')) {
          descParts.add('<img src="${_xmlEscape(p)}" width="300"/>');
        } else {
          descParts.add('<i>Photo locale: ${_xmlEscape(p.split('/').last)}</i>');
        }
      }
      if (descParts.isNotEmpty) {
        buf.writeln('  <description><![CDATA[${descParts.join("<br/>")}]]></description>');
      }

      final styleId = _kmlIcons.containsKey(poi.type) ? poi.type! : 'poi';
      buf.writeln('  <styleUrl>#style_$styleId</styleUrl>');
      buf.writeln('  <Point><coordinates>${poi.lon},${poi.lat},0</coordinates></Point>');
      buf.writeln('</Placemark>');
    }

    // Tracés
    if (tracks != null) {
      for (final track in tracks) {
        if (!track.visible || track.data.trackPoints.isEmpty) continue;
        buf.writeln('<Placemark>');
        buf.writeln('  <name>${_xmlEscape(track.displayName)}</name>');
        buf.writeln('  <LineString><coordinates>');
        buf.write('    ');
        for (final pt in track.data.trackPoints) {
          buf.write('${pt.lon},${pt.lat},${pt.ele ?? 0} ');
        }
        buf.writeln('\n  </coordinates></LineString>');
        buf.writeln('</Placemark>');
      }
    }

    buf.writeln('</Document></kml>');
    return buf.toString();
  }

  // ── GeoJSON ───────────────────────────────────────────────────────────────
  static String _toGeoJson(List<PoiPoint> pts, {List<GpxTrack>? tracks}) {
    final features = <Map<String, dynamic>>[];

    // POI
    for (final poi in pts) {
      final descText = (poi.description ?? '')
          .replaceAll(RegExp(r'\[img:[^\]]+\]'), '').trim();
      final descImgs = RegExp(r'\[img:([^\]]+)\]')
          .allMatches(poi.description ?? '')
          .map((m) => m.group(1)!)
          .toList();
      features.add({
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [poi.lon, poi.lat]},
        'properties': {
          'name':        poi.name,
          'description': descText,
          'type':        poi.type ?? 'poi',
          'photos':      [...poi.localPhotos, ...poi.photoUrls, ...descImgs],
        },
      });
    }

    // Tracés
    if (tracks != null) {
      for (final track in tracks) {
        if (!track.visible || track.data.trackPoints.isEmpty) continue;
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': track.data.trackPoints
                .map((p) => [p.lon, p.lat, p.ele ?? 0]).toList(),
          },
          'properties': {
            'name':  track.displayName,
            'color': '#${track.color.value.toRadixString(16).substring(2)}',
          },
        });
      }
    }

    return const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  // ── CSV ───────────────────────────────────────────────────────────────────
  static String _toCsv(List<PoiPoint> pts) {
    final buf = StringBuffer();
    buf.writeln('name,lat,lon,type,description,photos_locales,photos_url');
    for (final poi in pts) {
      String esc(String s) => '"${s.replaceAll('"', '""')}"';
      final desc = (poi.description ?? '')
          .replaceAll(RegExp(r'\[img:[^\]]+\]'), '').trim();
      final descImgs = RegExp(r'\[img:([^\]]+)\]')
          .allMatches(poi.description ?? '')
          .map((m) => m.group(1)!).toList();
      final locals = poi.localPhotos.join('|');
      final urls   = [...poi.photoUrls, ...descImgs].join('|');
      buf.writeln('${esc(poi.name)},${poi.lat},${poi.lon},'
          '${poi.type ?? ""},${esc(desc)},${esc(locals)},${esc(urls)}');
    }
    return buf.toString();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialogue d'export — inclut maintenant les tracés GPX
// ─────────────────────────────────────────────────────────────────────────────
class PoiExportDialog extends StatefulWidget {
  final List<PoiLayer>  layers;
  final List<GpxTrack>? tracks;

  const PoiExportDialog({super.key, required this.layers, this.tracks});

  @override
  State<PoiExportDialog> createState() => _PoiExportDialogState();
}

class _PoiExportDialogState extends State<PoiExportDialog> {
  ExportFormat _format       = ExportFormat.gpx;
  bool         _includeTracks = true;
  bool         _loading      = false;
  String?      _result;
  String?      _error;
  final _nameCtrl = TextEditingController(text: 'pulsegpx_export');

  Future<void> _export() async {
    setState(() { _loading = true; _result = null; _error = null; });
    try {
      final path = await PoiExporter.export(
        widget.layers, _format,
        tracks:   _includeTracks ? widget.tracks : null,
        fileName: _nameCtrl.text.trim().isEmpty ? 'export' : _nameCtrl.text.trim(),
      );
      setState(() => _result = path);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalPoi    = widget.layers.where((l) => l.visible)
        .fold(0, (s, l) => s + l.points.length);
    final totalPhotos = widget.layers.where((l) => l.visible)
        .expand((l) => l.points)
        .fold(0, (s, p) =>
            s + p.localPhotos.length + p.photoUrls.length +
            RegExp(r'\[img:').allMatches(p.description ?? '').length);
    final totalTracks = widget.tracks?.where((t) => t.visible).length ?? 0;

    return AlertDialog(
      title: const Row(children: [
        Icon(Icons.download, color: Color(0xFF003580)),
        SizedBox(width: 8),
        Text('Exporter'),
      ]),
      content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Résumé
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _infoRow(Icons.location_on, '$totalPoi POI',
                  sub: '$totalPhotos photo(s)'),
              if (totalTracks > 0) ...[
                const SizedBox(height: 4),
                _infoRow(Icons.route, '$totalTracks tracé(s) GPX', sub: ''),
              ],
            ]),
          ),
          const SizedBox(height: 10),

          // Nom du fichier
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Nom du fichier',
              border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),

          // Inclure tracés
          if (totalTracks > 0)
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('Inclure les $totalTracks tracé(s) GPX',
                  style: const TextStyle(fontSize: 13)),
              value: _includeTracks,
              onChanged: (v) => setState(() => _includeTracks = v),
            ),

          // Format
          ...ExportFormat.values.map((f) => RadioListTile<ExportFormat>(
            dense: true,
            value: f, groupValue: _format,
            onChanged: (v) => setState(() => _format = v!),
            title: Text(_fmtLabel(f),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            subtitle: Text(_fmtDesc(f),
                style: const TextStyle(fontSize: 11)),
            secondary: Icon(_fmtIcon(f), size: 20, color: const Color(0xFF003580)),
          )),

          if (_result != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.green.shade200)),
              child: Row(children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text('Sauvegardé :\n$_result',
                    style: const TextStyle(fontSize: 10, color: Colors.green))),
              ]),
            ),
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6)),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 11)),
            ),
        ],
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Fermer')),
        FilledButton.icon(
          onPressed: _loading ? null : _export,
          icon: _loading
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_alt, size: 16),
          label: const Text('Exporter'),
        ),
      ],
    );
  }

  Widget _infoRow(IconData icon, String text, {required String sub}) =>
    Row(children: [
      Icon(icon, size: 14, color: Colors.blue),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      if (sub.isNotEmpty) ...[
        const SizedBox(width: 6),
        Text(sub, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    ]);

  String   _fmtLabel(ExportFormat f) =>
      const {ExportFormat.gpx:'GPX', ExportFormat.kml:'KML',
             ExportFormat.geojson:'GeoJSON', ExportFormat.csv:'CSV'}[f]!;
  String   _fmtDesc(ExportFormat f) =>
      const {ExportFormat.gpx:'OsmAnd, Garmin, Komoot — photos incluses',
             ExportFormat.kml:'Google Earth — photos intégrées',
             ExportFormat.geojson:'QGIS, Mapbox — photos en propriétés',
             ExportFormat.csv:'Excel — colonnes photos_locales / photos_url'}[f]!;
  IconData _fmtIcon(ExportFormat f) =>
      const {ExportFormat.gpx:Icons.route, ExportFormat.kml:Icons.public,
             ExportFormat.geojson:Icons.code, ExportFormat.csv:Icons.table_chart}[f]!;
}
