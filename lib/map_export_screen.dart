import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'gpx_track.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'app_dirs.dart';

class MapExportScreen extends StatefulWidget {
  final List<GpxTrack>  tracks;
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final String          sessionLabel;

  const MapExportScreen({
    super.key,
    required this.tracks,
    required this.rootLayers,
    required this.folders,
    required this.sessionLabel,
  });

  @override
  State<MapExportScreen> createState() => _MapExportScreenState();
}

class _MapExportScreenState extends State<MapExportScreen> {

  bool    _generating = false;
  String? _outputPath;
  String? _error;
  String? _outputDir;          // dossier choisi par l'utilisateur

  // Options
  bool   _includeTracks   = true;
  bool   _includePoi      = true;
  bool   _includePhotos   = true;
  bool   _numberedMarkers = true;
  bool   _includeProfile  = true;
  String _mapTile         = 'osm';

  // ── Données ───────────────────────────────────────────────────────────────
  List<PoiPoint> get _allPoi => [
    ...widget.rootLayers.where((l) => l.visible).expand((l) => l.points),
    ...widget.folders.where((f) => f.visible)
        .expand((f) => f.layers.where((l) => l.visible).expand((l) => l.points)),
  ];

  List<GpxTrack> get _visibleTracks =>
      widget.tracks.where((t) => t.visible).toList();

  // ── Choix du dossier ──────────────────────────────────────────────────────
  Future<void> _pickDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choisir le dossier de destination',
    );
    if (dir != null) setState(() => _outputDir = dir);
  }

  Future<void> _useBackupDir() async {
    final dir = await AppDirs.exportDir();
    setState(() => _outputDir = dir);
  }

  // ── Génération ────────────────────────────────────────────────────────────
  Future<void> _generate() async {
    setState(() { _generating = true; _error = null; _outputPath = null; });
    try {
      // Résoudre le dossier de destination
      final destDir = _outputDir ?? await AppDirs.exportDir();
      final d = Directory(destDir);
      if (!await d.exists()) await d.create(recursive: true);

      // Encoder les photos locales en base64 si option activée
      final photoCache = <String, String>{}; // chemin → data URI
      if (_includePhotos) {
        for (final poi in _allPoi) {
          for (final path in poi.localPhotos) {
            if (photoCache.containsKey(path)) continue;
            try {
              final f = File(path);
              if (await f.exists()) {
                final bytes = await f.readAsBytes();
                final ext   = path.split('.').last.toLowerCase();
                final mime  = ext == 'png' ? 'image/png'
                            : ext == 'gif' ? 'image/gif'
                            : 'image/jpeg';
                photoCache[path] = 'data:$mime;base64,${base64Encode(bytes)}';
              }
            } catch (_) {}
          }
        }
      }

      final html = _buildHtml(photoCache);
      final safe = widget.sessionLabel
          .replaceAll(RegExp(r'[^\w\-]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final name = 'roadbook_${safe}_${DateTime.now().millisecondsSinceEpoch}.html';
      final file = File('$destDir/$name');
      await file.writeAsString(html, encoding: utf8);
      AppDirs.setLastExportDir(destDir);
      setState(() { _outputPath = file.path; });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _generating = false; });
    }
  }

  Future<void> _open() async {
    if (_outputPath == null) return;
    if (Platform.isAndroid || Platform.isIOS) {
      // Sur mobile : Uri.file() est bloqué — afficher dans WebView intégrée
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(
        builder: (_) => _RoadbookWebView(filePath: _outputPath!),
      ));
    } else {
      // Sur desktop : ouvrir dans le navigateur système
      final uri = Uri.file(_outputPath!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  // ── Build HTML ────────────────────────────────────────────────────────────
  String _buildHtml(Map<String, String> photoCache) {
    final pois   = _includePoi    ? _allPoi        : <PoiPoint>[];
    final tracks = _includeTracks ? _visibleTracks : <GpxTrack>[];

    final allLats = [
      ...pois.map((p) => p.lat),
      ...tracks.expand((t) => t.data.trackPoints.map((p) => p.lat)),
    ];
    final allLons = [
      ...pois.map((p) => p.lon),
      ...tracks.expand((t) => t.data.trackPoints.map((p) => p.lon)),
    ];
    final centerLat = allLats.isEmpty ? 46.0
        : allLats.reduce((a, b) => a + b) / allLats.length;
    final centerLon = allLons.isEmpty ? 2.0
        : allLons.reduce((a, b) => a + b) / allLons.length;

    // ── Photos par POI ────────────────────────────────────────────────────
    // Construire la liste des photos pour chaque POI (base64 local + URL remote)
    List<Map<String,dynamic>> _poiPhotos(PoiPoint p) {
      if (!_includePhotos) return [];
      final result = <Map<String,dynamic>>[];
      for (final path in p.localPhotos) {
        final data = photoCache[path];
        if (data != null) result.add({'src': data, 'local': true});
      }
      for (final url in p.photoUrls) {
        result.add({'src': url, 'local': false});
      }
      return result;
    }

    // ── JSON POI avec photos ──────────────────────────────────────────────
    final poisJson = jsonEncode(pois.asMap().entries.map((e) {
      final p = e.value;
      final photos = _poiPhotos(p);
      return {
        'n':      e.key + 1,
        'name':   p.name,
        'lat':    p.lat,
        'lon':    p.lon,
        'type':   p.type ?? 'poi',
        'desc':   p.description ?? '',
        'color':  _layerColorHex(p),
        'photos': photos,
      };
    }).toList());

    final tracksJson = jsonEncode(tracks.map((t) => {
      'name':  t.displayName,
      'color': '#${t.color.value.toRadixString(16).padLeft(8,'0').substring(2)}',
      'points':    t.data.trackPoints.map((p) => [p.lat, p.lon]).toList(),
      'waypoints': t.data.waypoints.map((w) =>
          {'lat': w.lat, 'lon': w.lon, 'name': w.name ?? ''}).toList(),
    }).toList());

    // ── Profil altimétrique ───────────────────────────────────────────────
    String profileHtml = '';
    if (_includeProfile && tracks.isNotEmpty) {
      final t   = tracks.first;
      final pts = t.data.trackPoints;
      if (pts.any((p) => p.ele != null)) {
        final eles = pts.map((p) => p.ele ?? 0.0).toList();
        final dists = <double>[0];
        for (int i = 1; i < pts.length; i++) {
          final dlat = (pts[i].lat - pts[i-1].lat) * 111.0;
          final dlon = (pts[i].lon - pts[i-1].lon) * 111.0 * _cosDeg(pts[i].lat);
          dists.add(dists.last + _sqrt(dlat*dlat + dlon*dlon));
        }
        final minE = eles.reduce((a,b) => a<b?a:b);
        final maxE = eles.reduce((a,b) => a>b?a:b);
        final totalDist = dists.last;
        final eleData = jsonEncode(pts.asMap().entries
            .map((e) => {'d': (dists[e.key]*10).round()/10, 'e': e.value.ele ?? 0})
            .toList());
        profileHtml = '''
<div class="profile-section">
  <h3>📈 ${_esc(t.displayName)}</h3>
  <div id="profile-chart"></div>
  <div class="profile-stats">
    <span>↧ ${minE.toStringAsFixed(0)} m</span>
    <span>↑ ${maxE.toStringAsFixed(0)} m</span>
    <span>↔ ${totalDist.toStringAsFixed(1)} km</span>
    <span>△ D+ ${_calcDPlus(eles).toStringAsFixed(0)} m</span>
  </div>
</div>
<script>
(function(){
  const D=$eleData;if(!D.length)return;
  const el=document.getElementById('profile-chart');
  const cv=document.createElement('canvas');
  cv.width=el.offsetWidth||800;cv.height=160;el.appendChild(cv);
  const c=cv.getContext('2d'),pad={t:8,r:8,b:24,l:40};
  const W=cv.width-pad.l-pad.r,H=cv.height-pad.t-pad.b;
  const mnD=D[0].d,mxD=D[D.length-1].d;
  const mnE=Math.min(...D.map(p=>p.e))*.98,mxE=Math.max(...D.map(p=>p.e))*1.02;
  const X=d=>pad.l+(d-mnD)/(mxD-mnD||1)*W;
  const Y=e=>pad.t+H-(e-mnE)/(mxE-mnE||1)*H;
  c.fillStyle='#0f1e3c';c.fillRect(0,0,cv.width,cv.height);
  c.strokeStyle='#1e3a5f';c.lineWidth=.5;
  for(let i=0;i<=4;i++){const y=pad.t+i*H/4;c.beginPath();c.moveTo(pad.l,y);c.lineTo(pad.l+W,y);c.stroke();
    const v=mxE-i*(mxE-mnE)/4;c.fillStyle='#667';c.font='9px sans-serif';c.textAlign='right';
    c.fillText(Math.round(v)+'m',pad.l-3,y+3);}
  c.beginPath();c.moveTo(X(D[0].d),Y(D[0].e));D.forEach(p=>c.lineTo(X(p.d),Y(p.e)));
  c.lineTo(X(D[D.length-1].d),pad.t+H);c.lineTo(X(D[0].d),pad.t+H);c.closePath();
  const g=c.createLinearGradient(0,pad.t,0,pad.t+H);
  g.addColorStop(0,'rgba(34,197,94,.6)');g.addColorStop(1,'rgba(34,197,94,.05)');
  c.fillStyle=g;c.fill();
  c.beginPath();c.strokeStyle='#22c55e';c.lineWidth=2;
  D.forEach((p,i)=>i===0?c.moveTo(X(p.d),Y(p.e)):c.lineTo(X(p.d),Y(p.e)));c.stroke();
  c.fillStyle='#667';c.font='9px sans-serif';c.textAlign='center';
  const step=Math.ceil((mxD-mnD)/5);
  for(let d=Math.ceil(mnD);d<=mxD;d+=step)c.fillText(d+'km',X(d),pad.t+H+14);
})();
</script>''';
      }
    }

    // ── Tile URL ──────────────────────────────────────────────────────────
    final tileUrl = _mapTile == 'satellite'
        ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
        : _mapTile == 'topo'
        ? 'https://tile.opentopomap.org/{z}/{x}/{y}.png'
        : 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
    final tileAttr = _mapTile == 'satellite' ? '© Esri'
        : _mapTile == 'topo' ? '© OpenTopoMap'
        : '© OpenStreetMap contributors';

    // ── Légende ───────────────────────────────────────────────────────────
    final allLayers = [
      ...widget.rootLayers.where((l) => l.visible),
      ...widget.folders.where((f) => f.visible)
          .expand((f) => f.layers.where((l) => l.visible)),
    ];
    final legendHtml = allLayers.map((l) {
      final hex = '#${l.color.value.toRadixString(16).padLeft(8,'0').substring(2)}';
      return '<div class="legend-item"><span class="ldot" style="background:$hex"></span>${_esc(l.label)} (${l.points.length})</div>';
    }).join('');
    final trackLegendHtml = tracks.map((t) {
      final hex = '#${t.color.value.toRadixString(16).padLeft(8,'0').substring(2)}';
      return '<div class="legend-item"><span class="lline" style="background:$hex"></span>${_esc(t.displayName)}</div>';
    }).join('');

    // ── Table POI ─────────────────────────────────────────────────────────
    final tableRows = pois.asMap().entries.map((e) {
      final i = e.key+1; final p = e.value;
      final hex = _layerColorHex(p);
      final photos = _poiPhotos(p);
      final thumbHtml = photos.isNotEmpty
          ? '<div class="thumb-row">'
            + photos.take(3).map((ph) =>
                '<img src="${ph['src']}" class="tbl-thumb" '
                'onclick="focusPoi(${i-1})" title="${_esc(p.name)}" />'
              ).join('')
            + '</div>'
          : '';
      return '<tr id="tbl-poi-${i-1}" onclick="focusPoi(${i-1})">'
          '<td><span class="badge" style="background:$hex">$i</span></td>'
          '<td><strong>${_esc(p.name)}</strong>'
          '${p.description?.isNotEmpty==true ? "<br><small>${_esc(p.description!)}</small>" : ""}'
          '$thumbHtml</td>'
          '<td class="coords">${p.lat.toStringAsFixed(5)}<br>${p.lon.toStringAsFixed(5)}</td>'
          '</tr>';
    }).join('');

    final title = _esc(widget.sessionLabel);

    return '''<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title — Road-book PulseGpx</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:#1a1a2e;color:#eee}

/* ── Header ── */
.header{background:linear-gradient(135deg,#0f3460,#16213e);
  padding:16px 20px 12px;border-bottom:3px solid #e4a010}
.header h1{font-size:1.5rem;font-weight:900;color:#fff}
.header .sub{color:#e4a010;font-size:.8rem;font-weight:700;text-transform:uppercase;
  letter-spacing:2px;margin-top:2px}
.stats{margin-top:8px;display:flex;gap:10px;flex-wrap:wrap}
.chip{background:rgba(255,255,255,.1);border-radius:20px;padding:3px 10px;
  font-size:.75rem;color:#ccc}

/* ── Layout ── */
.main-grid{display:grid;grid-template-columns:300px 1fr;height:calc(100vh - 88px);
  /* iOS Safari fix: forcer flex fallback si grid echoue */
  min-height:0}

/* ── Sidebar ── */
.sidebar{background:#16213e;overflow-y:auto;border-right:2px solid #0f3460;
  display:flex;flex-direction:column}
.sb-section{padding:12px 14px;border-bottom:1px solid #0f3460}
.sb-section h3{font-size:.7rem;text-transform:uppercase;letter-spacing:1.5px;
  color:#e4a010;margin-bottom:8px}

.poi-item{display:flex;align-items:flex-start;gap:8px;padding:6px 4px;
  border-bottom:1px solid #1e3060;cursor:pointer;border-radius:4px;
  transition:background .15s}
.poi-item:hover,.poi-item.active{background:rgba(228,160,16,.15)}
.poi-item:last-child{border-bottom:none}
.poi-num{min-width:24px;height:24px;border-radius:50%;display:flex;
  align-items:center;justify-content:center;font-size:.65rem;
  font-weight:900;color:#fff;flex-shrink:0;margin-top:2px}
.poi-info{flex:1;min-width:0}
.poi-name{font-size:.8rem;font-weight:700;color:#eee;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.poi-desc{font-size:.68rem;color:#888;margin-top:1px}
.poi-coords{font-size:.62rem;color:#445;font-family:monospace}

/* ── Miniatures sidebar ── */
.poi-thumbs{display:flex;gap:4px;margin-top:5px;flex-wrap:wrap}
.poi-thumb{width:52px;height:40px;object-fit:cover;border-radius:4px;
  border:1.5px solid #2a4080;cursor:pointer;transition:border-color .15s,transform .15s}
.poi-thumb:hover{border-color:#e4a010;transform:scale(1.05);z-index:2}
.poi-thumb.active-photo{border-color:#e4a010;box-shadow:0 0 6px #e4a010}

/* ── Map ── */
#map-container{position:relative;flex:1;min-height:0;-webkit-overflow-scrolling:touch}
#map{position:absolute;top:0;left:0;right:0;bottom:0;width:100%;height:100%}

/* ── Miniatures sur la carte (panneau flottant droite) ── */
#photo-panel{position:absolute;top:8px;right:8px;z-index:1000;
  background:rgba(22,33,62,.95);border:1px solid #0f3460;border-radius:8px;
  padding:8px;max-width:180px;max-height:calc(100% - 80px);
  overflow-y:auto;display:none;backdrop-filter:blur(4px)}
#photo-panel h4{font-size:.65rem;text-transform:uppercase;color:#e4a010;
  letter-spacing:1px;margin-bottom:6px}
.map-photo{width:100%;border-radius:5px;margin-bottom:5px;cursor:pointer;
  border:1.5px solid transparent;transition:border-color .15s}
.map-photo:hover{border-color:#e4a010}
.map-photo-name{font-size:.62rem;color:#aaa;margin-bottom:8px;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

/* ── Légende carte ── */
.map-legend{position:absolute;bottom:24px;right:10px;z-index:900;
  background:rgba(22,33,62,.92);border:1px solid #0f3460;
  border-radius:8px;padding:8px 12px;max-width:180px}
.map-legend h4{font-size:.65rem;text-transform:uppercase;color:#e4a010;
  letter-spacing:1px;margin-bottom:6px}
.legend-item{display:flex;align-items:center;gap:7px;font-size:.7rem;
  color:#ccc;margin-bottom:4px}
.ldot{width:11px;height:11px;border-radius:50%;flex-shrink:0}
.lline{width:18px;height:3px;border-radius:2px;flex-shrink:0}

/* ── Contrôles carte ── */
.map-ctrls{position:absolute;top:8px;left:44px;z-index:1000;display:flex;gap:5px}
.cbtn{background:rgba(22,33,62,.9);color:#eee;border:1px solid #0f3460;
  border-radius:5px;padding:4px 9px;font-size:.7rem;cursor:pointer}
.cbtn:hover,.cbtn.active{background:#e4a010;color:#000}

/* ── Bas de page ── */
.bottom-grid{display:grid;grid-template-columns:1fr 1fr;border-top:2px solid #0f3460}
.profile-section{background:#0f1e3c;padding:14px 20px;border-right:1px solid #0f3460}
.profile-section h3{font-size:.7rem;text-transform:uppercase;color:#e4a010;
  letter-spacing:1px;margin-bottom:8px}
#profile-chart{width:100%;height:160px}
.profile-stats{display:flex;gap:12px;margin-top:6px;flex-wrap:wrap}
.profile-stats span{font-size:.72rem;color:#aaa;background:#16213e;
  padding:2px 9px;border-radius:10px}
.table-section{background:#0f1e3c;padding:14px 20px;overflow-x:auto}
.table-section h3{font-size:.7rem;text-transform:uppercase;color:#e4a010;
  letter-spacing:1px;margin-bottom:8px}
table{width:100%;border-collapse:collapse;font-size:.72rem}
th{text-align:left;padding:5px 7px;color:#777;border-bottom:1px solid #1e3060;font-weight:600}
td{padding:5px 7px;border-bottom:1px solid #1a2a4a;vertical-align:top;cursor:pointer}
tr:hover td{background:rgba(228,160,16,.06)}
tr.tbl-active td{background:rgba(228,160,16,.12)}
.coords{font-family:monospace;font-size:.65rem;color:#445}
.badge{display:inline-flex;align-items:center;justify-content:center;
  width:20px;height:20px;border-radius:50%;font-size:.6rem;font-weight:900;color:#fff}
.thumb-row{display:flex;gap:3px;margin-top:4px;flex-wrap:wrap}
.tbl-thumb{width:44px;height:34px;object-fit:cover;border-radius:3px;
  border:1.5px solid #2a4080;cursor:pointer}
.tbl-thumb:hover{border-color:#e4a010}

/* ── Lightbox ── */
#lightbox{display:none;position:fixed;inset:0;background:rgba(0,0,0,.85);
  z-index:9999;align-items:center;justify-content:center;flex-direction:column}
#lightbox.open{display:flex}
#lightbox img{max-width:90vw;max-height:80vh;border-radius:8px;
  border:2px solid #e4a010}
#lightbox .lb-name{color:#eee;font-size:.85rem;margin-top:8px}
#lightbox .lb-close{position:absolute;top:16px;right:20px;font-size:1.8rem;
  color:#eee;cursor:pointer;line-height:1}

@media print{
  body{background:#fff;color:#000}
  .header{background:#003580!important;-webkit-print-color-adjust:exact}
  #photo-panel,.map-ctrls,.lb-close{display:none!important}
  #map{height:500px!important}
}
@media(max-width:768px){
  .main-grid{grid-template-columns:1fr}
  .sidebar{max-height:280px}
  .bottom-grid{grid-template-columns:1fr}
}
</style>
</head>
<body>

<div class="header">
  <h1>$title</h1>
  <div class="sub">Road-book · PulseGpx</div>
  <div class="stats">
    <span class="chip">📍 ${pois.length} POI</span>
    <span class="chip">🥾 ${tracks.length} tracé(s)</span>
    ${tracks.isNotEmpty ? '<span class="chip">📏 ${_totalDist(tracks).toStringAsFixed(0)} km</span>' : ''}
    ${pois.where((p) => p.hasPhotos).isNotEmpty ? '<span class="chip">📷 ${pois.where((p) => p.hasPhotos).length} POI avec photos</span>' : ''}
    <span class="chip">📅 ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}</span>
  </div>
</div>

<div class="main-grid">
  <!-- Sidebar -->
  <aside class="sidebar">
    ${pois.isNotEmpty ? '<div class="sb-section"><h3>📍 Points d\'intérêt</h3><ul style="list-style:none" id="poi-sidebar"></ul></div>' : ''}
    ${legendHtml.isNotEmpty || trackLegendHtml.isNotEmpty ? '''
    <div class="sb-section">
      <h3>Légende</h3>$trackLegendHtml$legendHtml
    </div>''' : ''}
    <div class="sb-section">
      <h3>Contrôles</h3>
      <div style="display:flex;flex-direction:column;gap:5px;margin-top:4px">
        <button class="cbtn" onclick="map.fitBounds(allBounds)" style="width:100%">🎯 Centrer tout</button>
        <button class="cbtn" onclick="window.print()" style="width:100%">🖨️ Imprimer</button>
      </div>
    </div>
  </aside>

  <!-- Carte -->
  <div style="position:relative">
    <div id="map-container"><div id="map"></div></div>

    <!-- Panneau photos flottant droite de la carte -->
    <div id="photo-panel">
      <h4 id="photo-panel-title">Photos</h4>
      <div id="photo-panel-imgs"></div>
    </div>

    <!-- Légende carte -->
    <div class="map-legend">
      <h4>Légende</h4>$trackLegendHtml$legendHtml
    </div>

    <div class="map-ctrls">
      <button class="cbtn active" id="btn-osm" onclick="switchTile('osm',this)">OSM</button>
      <button class="cbtn" id="btn-sat" onclick="switchTile('sat',this)">Satellite</button>
      <button class="cbtn" id="btn-topo" onclick="switchTile('topo',this)">Topo</button>
    </div>
  </div>
</div>

<!-- Bas de page -->
<div class="bottom-grid">
  $profileHtml
  ${pois.isNotEmpty ? '''
  <div class="table-section">
    <h3>📋 Liste des POI</h3>
    <table>
      <thead><tr><th>#</th><th>Nom / Photos</th><th>Coord.</th></tr></thead>
      <tbody>$tableRows</tbody>
    </table>
  </div>''' : '<div></div>'}
</div>

<!-- Lightbox -->
<div id="lightbox" onclick="closeLb()">
  <span class="lb-close" onclick="closeLb()">✕</span>
  <img id="lb-img" src="" alt="">
  <div class="lb-name" id="lb-name"></div>
</div>

<script>
const POIS   = $poisJson;
const TRACKS = $tracksJson;

// ── Carte ────────────────────────────────────────────────────────────────────
const map = L.map('map');
const TILES = {
  osm:  {url:'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',attr:'© OpenStreetMap contributors'},
  sat:  {url:'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',attr:'© Esri'},
  topo: {url:'https://tile.opentopomap.org/{z}/{x}/{y}.png',attr:'© OpenTopoMap'},
};
// crossOrigin:'' requis sur iOS Safari pour que les tuiles s'affichent
let currentTile = L.tileLayer(TILES.osm.url,{maxZoom:19,attribution:TILES.osm.attr,crossOrigin:''}).addTo(map);
// Forcer invalidateSize après chargement (fix Safari/iOS layout)
setTimeout(() => map.invalidateSize(), 100);

function switchTile(key,btn){
  map.removeLayer(currentTile);
  currentTile=L.tileLayer(TILES[key].url,{maxZoom:19,attribution:TILES[key].attr,crossOrigin:''}).addTo(map);
  document.querySelectorAll('.cbtn').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
}

// ── Tracés GPX ───────────────────────────────────────────────────────────────
const allBoundsPoints = [];
TRACKS.forEach(t=>{
  if(t.points.length<2)return;
  L.polyline(t.points,{color:t.color,weight:4,opacity:.85,lineJoin:'round',lineCap:'round'})
   .bindPopup('<b>'+t.name+'</b><br>'+t.points.length+' pts').addTo(map);
  t.points.forEach(p=>allBoundsPoints.push(p));
  t.waypoints.forEach(w=>{
    L.circleMarker([w.lat,w.lon],{radius:5,color:t.color,fillColor:'#fff',fillOpacity:1,weight:2})
     .bindPopup(w.name||'Waypoint').addTo(map);
  });
});

// ── Marqueurs POI ─────────────────────────────────────────────────────────────
const markers = [];
POIS.forEach((p,i)=>{
  // Icône : cercle coloré numéroté, avec clip photo en bordure si dispo
  const hasPhotos = p.photos && p.photos.length > 0;
  const photoRing = hasPhotos
    ? \`<div style="position:absolute;bottom:-4px;right:-4px;width:14px;height:14px;
        border-radius:50%;overflow:hidden;border:1.5px solid #fff;box-shadow:0 1px 3px rgba(0,0,0,.4)">
        <img src="\${p.photos[0].src}" style="width:100%;height:100%;object-fit:cover"></div>\`
    : '';
  const icon = L.divIcon({
    className:'',
    html:\`<div style="position:relative;width:28px;height:28px">
      <div style="width:28px;height:28px;border-radius:50%;background:\${p.color};
        border:2px solid #fff;box-shadow:0 2px 6px rgba(0,0,0,.4);
        display:flex;align-items:center;justify-content:center;
        font-size:11px;font-weight:900;color:#fff;cursor:pointer">\${p.n}</div>
      \${photoRing}
    </div>\`,
    iconSize:[28,28],iconAnchor:[14,14],popupAnchor:[0,-16],
  });

  const photoHtml = hasPhotos
    ? '<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:6px;max-width:200px">'
      + p.photos.slice(0,4).map((ph,pi)=>
          \`<img src="\${ph.src}" onclick="openLb('\${ph.src}','\${p.name}')"
            style="width:44px;height:36px;object-fit:cover;border-radius:3px;
            border:1.5px solid #aaa;cursor:pointer">\`
        ).join('')
      + '</div>'
    : '';

  const m = L.marker([p.lat,p.lon],{icon})
    .bindPopup(\`<b>\${p.n}. \${p.name}</b>
      \${p.desc?'<br><span style="font-size:11px">'+p.desc+'</span>':''}
      <br><small style="color:#888">\${p.lat.toFixed(5)}, \${p.lon.toFixed(5)}</small>
      \${photoHtml}\`)
    .addTo(map);

  // Au clic sur le marker : scroll sidebar + surlignage + affiche panneau photos
  m.on('click', ()=>{
    highlightPoi(i);
    if(p.photos && p.photos.length>0) showPhotoPanel(i);
  });

  markers.push(m);
  allBoundsPoints.push([p.lat,p.lon]);
});

// ── Sidebar POI ───────────────────────────────────────────────────────────────
const sidebar = document.getElementById('poi-sidebar');
if(sidebar){
  POIS.forEach((p,i)=>{
    const li=document.createElement('li');
    li.className='poi-item';
    li.id='sb-poi-'+i;

    const thumbsHtml = p.photos && p.photos.length
      ? '<div class="poi-thumbs">'
        + p.photos.slice(0,4).map((ph,pi)=>
            \`<img src="\${ph.src}" class="poi-thumb" data-poi="\${i}" data-ph="\${pi}"
              onclick="event.stopPropagation();openLb('\${ph.src}',p.name)"
              title="\${p.name} — photo \${pi+1}">\`
          ).join('')
        + '</div>'
      : '';

    li.innerHTML=\`
      <div class="poi-num" style="background:\${p.color}">\${p.n}</div>
      <div class="poi-info">
        <div class="poi-name">\${p.name}</div>
        \${p.desc?'<div class="poi-desc">'+p.desc+'</div>':''}
        <div class="poi-coords">\${p.lat.toFixed(5)}, \${p.lon.toFixed(5)}</div>
        \${thumbsHtml}
      </div>\`;

    li.onclick=()=>focusPoi(i);
    sidebar.appendChild(li);
  });
}

// ── Navigation POI ────────────────────────────────────────────────────────────
let activePoi = -1;

function focusPoi(i){
  map.setView([POIS[i].lat,POIS[i].lon],15,{animate:true});
  markers[i].openPopup();
  highlightPoi(i);
  if(POIS[i].photos && POIS[i].photos.length>0) showPhotoPanel(i);
}

function highlightPoi(i){
  // Sidebar
  document.querySelectorAll('.poi-item').forEach(el=>el.classList.remove('active'));
  const sbEl=document.getElementById('sb-poi-'+i);
  if(sbEl){sbEl.classList.add('active');sbEl.scrollIntoView({behavior:'smooth',block:'nearest'});}
  // Table
  document.querySelectorAll('tr[id^="tbl-poi-"]').forEach(el=>el.classList.remove('tbl-active'));
  const tblEl=document.getElementById('tbl-poi-'+i);
  if(tblEl){tblEl.classList.add('tbl-active');tblEl.scrollIntoView({behavior:'smooth',block:'nearest'});}
  activePoi=i;
}

// ── Panneau photos flottant sur la carte ──────────────────────────────────────
function showPhotoPanel(i){
  const p=POIS[i];
  if(!p.photos||!p.photos.length){hidePhotoPanel();return;}
  document.getElementById('photo-panel-title').textContent=p.name;
  const container=document.getElementById('photo-panel-imgs');
  container.innerHTML='';
  p.photos.forEach((ph,pi)=>{
    const img=document.createElement('img');
    img.src=ph.src; img.className='map-photo';
    img.title=p.name+' — photo '+(pi+1);
    img.onclick=()=>openLb(ph.src,p.name);
    const name=document.createElement('div');
    name.className='map-photo-name';
    name.textContent=p.name;
    container.appendChild(img);
    container.appendChild(name);
  });
  document.getElementById('photo-panel').style.display='block';
}

function hidePhotoPanel(){
  document.getElementById('photo-panel').style.display='none';
}

// Clic carte hors marker → ferme panneau photos
map.on('click',()=>hidePhotoPanel());

// ── Lightbox ──────────────────────────────────────────────────────────────────
function openLb(src,name){
  document.getElementById('lb-img').src=src;
  document.getElementById('lb-name').textContent=name;
  document.getElementById('lightbox').classList.add('open');
}
function closeLb(){document.getElementById('lightbox').classList.remove('open');}
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeLb();});

// ── Fit bounds ────────────────────────────────────────────────────────────────
const allBounds = allBoundsPoints.length>=2
  ? L.latLngBounds(allBoundsPoints)
  : L.latLngBounds([[${centerLat-.05},${centerLon-.05}],[${centerLat+.05},${centerLon+.05}]]);
map.fitBounds(allBounds,{padding:[16,16]});
</script>
</body>
</html>''';
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _esc(String s) => s
      .replaceAll('&','&amp;').replaceAll('<','&lt;')
      .replaceAll('>','&gt;').replaceAll('"','&quot;')
      .replaceAll("'","&#39;");

  String _layerColorHex(PoiPoint p) {
    for (final l in widget.rootLayers) {
      if (l.points.contains(p))
        return '#${l.color.value.toRadixString(16).padLeft(8,'0').substring(2)}';
    }
    for (final f in widget.folders) {
      for (final l in f.layers) {
        if (l.points.contains(p))
          return '#${l.color.value.toRadixString(16).padLeft(8,'0').substring(2)}';
      }
    }
    return '#e4a010';
  }

  double _totalDist(List<GpxTrack> tracks) {
    double d = 0;
    for (final t in tracks) {
      final pts = t.data.trackPoints;
      for (int i = 1; i < pts.length; i++) {
        final dlat = (pts[i].lat - pts[i-1].lat) * 111.0;
        final dlon = (pts[i].lon - pts[i-1].lon) * 111.0 * _cosDeg(pts[i].lat);
        d += _sqrt(dlat*dlat + dlon*dlon);
      }
    }
    return d;
  }

  double _calcDPlus(List<double> eles) {
    double d = 0;
    for (int i = 1; i < eles.length; i++) {
      final diff = eles[i] - eles[i-1];
      if (diff > 0) d += diff;
    }
    return d;
  }

  double _cosDeg(double deg) => _cos(deg * 3.14159265358979 / 180);

  double _cos(double x) {
    double r = 1, t = 1;
    for (int i = 1; i <= 8; i++) { t *= -x*x/(2*i*(2*i-1)); r += t; }
    return r;
  }

  double _sqrt(double x) {
    if (x <= 0) return 0;
    double s = x / 2;
    for (int i = 0; i < 20; i++) s = (s + x/s) / 2;
    return s;
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pois   = _allPoi;
    final tracks = _visibleTracks;
    final photosCount = pois.where((p) => p.hasPhotos).length;

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: const Text('Export Road-book',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Résumé session ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0f1e3c),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF0f3460)),
            ),
            child: Row(children: [
              const Icon(Icons.map_outlined, color: Color(0xFFe4a010), size: 34),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.sessionLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold,
                        fontSize: 14, color: Colors.white)),
                const SizedBox(height: 3),
                Text('${pois.length} POI · ${tracks.length} tracé(s)'
                    '${tracks.isNotEmpty ? " · ${_totalDist(tracks).toStringAsFixed(0)} km" : ""}'
                    '${photosCount > 0 ? " · 📷 $photosCount" : ""}',
                    style: const TextStyle(color: Colors.amber, fontSize: 11)),
              ])),
            ]),
          ),

          const SizedBox(height: 18),

          // ── Dossier de destination ──
          const Text('DESTINATION', style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold, color: Colors.amber, letterSpacing: 2)),
          const SizedBox(height: 8),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF0f3460)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Dossier sélectionné
              Row(children: [
                const Icon(Icons.folder, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _outputDir ?? 'Dossier par défaut (Documents/PulseGpx)',
                    style: TextStyle(
                      fontSize: 11,
                      color: _outputDir != null ? Colors.white70 : Colors.grey,
                      fontFamily: _outputDir != null ? 'monospace' : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: _pickDir,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Choisir…', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.amber,
                    side: const BorderSide(color: Colors.amber),
                    minimumSize: const Size(0, 38),
                  ),
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(
                  onPressed: _useBackupDir,
                  icon: const Icon(Icons.backup, size: 16),
                  label: const Text('Dossier backup', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white60,
                    side: const BorderSide(color: Colors.white24),
                    minimumSize: const Size(0, 38),
                  ),
                )),
              ]),
            ]),
          ),

          const SizedBox(height: 18),
          const Text('OPTIONS', style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold, color: Colors.amber, letterSpacing: 2)),
          const SizedBox(height: 8),

          _optTile('Tracés GPX', Icons.route, _includeTracks && tracks.isNotEmpty,
              tracks.isEmpty ? null : (v) => setState(() => _includeTracks = v)),
          _optTile('Points d\'intérêt (${pois.length})', Icons.place,
              _includePoi && pois.isNotEmpty,
              pois.isEmpty ? null : (v) => setState(() => _includePoi = v)),
          _optTile(
            photosCount > 0
                ? 'Miniatures ($photosCount POI avec photos)'
                : 'Miniatures (aucune photo)',
            Icons.photo_library,
            _includePhotos && photosCount > 0,
            photosCount == 0 ? null : (v) => setState(() => _includePhotos = v),
          ),
          _optTile('Marqueurs numérotés', Icons.format_list_numbered,
              _numberedMarkers, (v) => setState(() => _numberedMarkers = v)),
          _optTile('Profil altimétrique', Icons.show_chart,
              _includeProfile, (v) => setState(() => _includeProfile = v)),

          const SizedBox(height: 14),
          const Text('FOND DE CARTE', style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold, color: Colors.amber, letterSpacing: 2)),
          const SizedBox(height: 8),
          Row(children: [
            _tileBtn('OSM', 'osm'),
            const SizedBox(width: 8),
            _tileBtn('Satellite', 'satellite'),
            const SizedBox(width: 8),
            _tileBtn('Topo', 'topo'),
          ]),

          const SizedBox(height: 24),

          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade900.withOpacity(.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade700),
              ),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download),
              label: Text(_generating ? 'Génération…' : 'Générer le road-book HTML'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFe4a010),
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 52),
                textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ),

          if (_outputPath != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade900.withOpacity(.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade600),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('✅ Fichier généré !',
                    style: TextStyle(color: Colors.green,
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                Text(_outputPath!,
                    style: const TextStyle(fontSize: 10,
                        color: Colors.green, fontFamily: 'monospace')),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _open,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Ouvrir dans le navigateur'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green,
                      side: const BorderSide(color: Colors.green),
                    ),
                  )),
              ]),
            ),
          ],

          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  Widget _optTile(String label, IconData icon, bool value,
      ValueChanged<bool>? onChanged) =>
    Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF0f3460)),
      ),
      child: SwitchListTile(
        dense: true,
        title: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        secondary: Icon(icon, color: Colors.amber.shade600, size: 18),
        value: value, onChanged: onChanged,
        activeColor: Colors.amber,
        inactiveThumbColor: Colors.grey.shade600,
        inactiveTrackColor: Colors.grey.shade800,
      ),
    );

  Widget _tileBtn(String label, String key) {
    final sel = _mapTile == key;
    return Expanded(child: GestureDetector(
      onTap: () => setState(() => _mapTile = key),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFFe4a010) : const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: sel ? const Color(0xFFe4a010) : const Color(0xFF0f3460)),
        ),
        child: Text(label, textAlign: TextAlign.center,
            style: TextStyle(
                color: sel ? Colors.black : Colors.white60,
                fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                fontSize: 12)),
      ),
    ));
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// _RoadbookWebView — affiche le HTML road-book dans une WebView (mobile)
// ═════════════════════════════════════════════════════════════════════════════
class _RoadbookWebView extends StatefulWidget {
  final String filePath;
  const _RoadbookWebView({required this.filePath});
  @override State<_RoadbookWebView> createState() => _RoadbookWebViewState();
}

class _RoadbookWebViewState extends State<_RoadbookWebView> {
  late final WebViewController _ctrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => setState(() => _loading = false),
      ))
      ..loadFile(widget.filePath);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: const Color(0xFF003580),
      foregroundColor: Colors.white,
      title: const Text('Road-book', style: TextStyle(fontSize: 14)),
      actions: [
        IconButton(
          icon: const Icon(Icons.open_in_browser),
          tooltip: 'Ouvrir dans le navigateur',
          onPressed: () async {
            final uri = Uri.file(widget.filePath);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
      ],
    ),
    body: Stack(children: [
      WebViewWidget(controller: _ctrl),
      if (_loading) const LinearProgressIndicator(minHeight: 3),
    ]),
  );
}
