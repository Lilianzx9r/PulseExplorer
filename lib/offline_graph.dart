import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'navigation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// offline_graph.dart
//
// Graphe routier OSM hors-ligne :
//   1. Téléchargement via Overpass API (ways highway=*)
//   2. Construction d'un graphe de nœuds/arêtes
//   3. Algorithme A* pour calculer un itinéraire
//   4. Stockage sur disque (JSON) pour réutilisation
// ─────────────────────────────────────────────────────────────────────────────

class _Node {
  final int    id;
  final double lat, lon;
  const _Node(this.id, this.lat, this.lon);
}

class _Edge {
  final int    to;
  final double costM;
  final String highway;
  final bool   oneway;
  const _Edge(this.to, this.costM, this.highway, {this.oneway = false});
}

class OfflineGraph {
  final Map<int, _Node> nodes;
  final Map<int, List<_Edge>> adjacency;
  final double minLat, maxLat, minLon, maxLon;

  OfflineGraph({
    required this.nodes,
    required this.adjacency,
    required this.minLat, required this.maxLat,
    required this.minLon, required this.maxLon,
  });

  static const profiles = ['walking', 'cycling', 'driving'];

  bool coversPoint(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;

  // ── Téléchargement Overpass ────────────────────────────────────────────────
  static Future<OfflineGraph?> download(
    double minLat, double maxLat, double minLon, double maxLon, {
    String profile = 'walking',
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Requête Overpass en cours…');

    final filter = switch(profile) {
      'driving' => '["highway"~"motorway|trunk|primary|secondary|tertiary|unclassified|residential|service"]',
      'cycling' => '["highway"~"cycleway|path|track|primary|secondary|tertiary|unclassified|residential|service"]["bicycle"!="no"]',
      _         => '["highway"~"footway|path|pedestrian|steps|track|residential|service|unclassified|primary|secondary|tertiary"]["foot"!="no"]',
    };

    final bbox = '$minLat,$minLon,$maxLat,$maxLon';
    final query = '[out:json][timeout:60];'
        'way$filter($bbox);'
        'out geom;';

    try {
      final resp = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        body: {'data': query},
        headers: {'User-Agent': 'PulseGpx/1.0'},
      ).timeout(const Duration(seconds: 90));

      if (resp.statusCode != 200) {
        onStatus?.call('Erreur Overpass : ${resp.statusCode}');
        return null;
      }

      onStatus?.call('Construction du graphe…');
      final data = json.decode(resp.body) as Map;
      final elements = (data['elements'] as List?) ?? [];

      return _buildGraph(
          elements, minLat, maxLat, minLon, maxLon, profile, onStatus);
    } catch (e) {
      onStatus?.call('Erreur : $e');
      return null;
    }
  }

  static OfflineGraph _buildGraph(
      List elements, double minLat, double maxLat,
      double minLon, double maxLon, String profile,
      void Function(String)? onStatus) {
    final nodes     = <int, _Node>{};
    final adjacency = <int, List<_Edge>>{};

    int processed = 0;
    for (final el in elements) {
      if (el['type'] != 'way') continue;
      final tags    = (el['tags'] as Map?) ?? {};
      final highway = tags['highway']?.toString() ?? '';
      final oneway  = tags['oneway']?.toString() == 'yes' ||
                      tags['oneway']?.toString() == '1';

      final geom = el['geometry'] as List?;
      if (geom == null || geom.length < 2) continue;

      final wayNodeIds = <int>[];
      for (int i = 0; i < geom.length; i++) {
        final g = geom[i] as Map;
        final syntheticId = (el['id'] as int) * 10000 + i;
        final node = _Node(syntheticId,
            (g['lat'] as num).toDouble(), (g['lon'] as num).toDouble());
        nodes[syntheticId] = node;
        wayNodeIds.add(syntheticId);
      }

      for (int i = 0; i < wayNodeIds.length - 1; i++) {
        final fromId = wayNodeIds[i];
        final toId   = wayNodeIds[i + 1];
        final nA = nodes[fromId]!;
        final nB = nodes[toId]!;
        final dist = NavigationService.distanceM(
            LatLng(nA.lat, nA.lon), LatLng(nB.lat, nB.lon));

        adjacency.putIfAbsent(fromId, () => []);
        adjacency[fromId]!.add(_Edge(toId, dist, highway, oneway: oneway));

        if (!oneway) {
          adjacency.putIfAbsent(toId, () => []);
          adjacency[toId]!.add(_Edge(fromId, dist, highway));
        }
      }

      processed++;
      if (processed % 200 == 0) {
        onStatus?.call('Traitement : $processed/${elements.length} voies…');
      }
    }

    onStatus?.call('Graphe prêt : ${nodes.length} nœuds, ${adjacency.length} arêtes');
    return OfflineGraph(nodes: nodes, adjacency: adjacency,
        minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
  }

  // ── Sérialisation ──────────────────────────────────────────────────────────
  Map<String, dynamic> toJson() => {
    'bbox': [minLat, maxLat, minLon, maxLon],
    'nodes': nodes.map((k, v) => MapEntry(k.toString(), [v.lat, v.lon])),
    'adj': adjacency.map((k, edges) => MapEntry(k.toString(),
        edges.map((e) => [e.to, e.costM, e.highway, e.oneway ? 1 : 0]).toList())),
  };

  factory OfflineGraph.fromJson(Map<String, dynamic> d) {
    final bbox = d['bbox'] as List;
    final rawNodes = d['nodes'] as Map;
    final rawAdj   = d['adj']   as Map;

    final nodes = <int, _Node>{};
    rawNodes.forEach((k, v) {
      final id = int.parse(k);
      nodes[id] = _Node(id, (v as List)[0].toDouble(), v[1].toDouble());
    });

    final adj = <int, List<_Edge>>{};
    rawAdj.forEach((k, v) {
      final fromId = int.parse(k);
      adj[fromId] = (v as List).map((e) =>
          _Edge(e[0] as int, (e[1] as num).toDouble(),
              e[2] as String, oneway: e[3] == 1)).toList();
    });

    return OfflineGraph(
      nodes: nodes, adjacency: adj,
      minLat: (bbox[0] as num).toDouble(), maxLat: (bbox[1] as num).toDouble(),
      minLon: (bbox[2] as num).toDouble(), maxLon: (bbox[3] as num).toDouble(),
    );
  }

  static Future<File> _graphFile(String profile) async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/PulseGpx/offline_graphs');
    await dir.create(recursive: true);
    return File('${dir.path}/$profile.json');
  }

  Future<void> save(String profile) async {
    final file = await _graphFile(profile);
    await file.writeAsString(json.encode(toJson()));
  }

  static Future<OfflineGraph?> load(String profile) async {
    try {
      final file = await _graphFile(profile);
      if (!file.existsSync()) return null;
      final data = json.decode(await file.readAsString()) as Map<String, dynamic>;
      return OfflineGraph.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, double>> graphSizesMb() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/PulseGpx/offline_graphs');
    final result = <String, double>{};
    if (!dir.existsSync()) return result;
    await for (final f in dir.list()) {
      if (f is File) {
        final name = f.path.split('/').last.replaceAll('.json', '');
        result[name] = await f.length() / 1024 / 1024;
      }
    }
    return result;
  }

  static Future<void> deleteGraph(String profile) async {
    final file = await _graphFile(profile);
    if (file.existsSync()) await file.delete();
  }

  // ── A* ────────────────────────────────────────────────────────────────────
  int? nearestNode(double lat, double lon) {
    int? best;
    double bestDist = double.infinity;
    for (final n in nodes.values) {
      final d = _haversineM(lat, lon, n.lat, n.lon);
      if (d < bestDist) { bestDist = d; best = n.id; }
    }
    return best;
  }

  NavRoute? route(LatLng from, LatLng to, String profile, String targetName) {
    final startId = nearestNode(from.latitude, from.longitude);
    final endId   = nearestNode(to.latitude, to.longitude);
    if (startId == null || endId == null) return null;

    final gScore = <int, double>{startId: 0.0};
    final fScore = <int, double>{
      startId: _haversineM(nodes[startId]!.lat, nodes[startId]!.lon,
                           nodes[endId]!.lat,   nodes[endId]!.lon),
    };
    final cameFrom = <int, int>{};
    final open = _PriorityQueue<int>(
        (a, b) => (fScore[a] ?? double.infinity)
            .compareTo(fScore[b] ?? double.infinity));
    open.add(startId);

    int iterations = 0;
    while (open.isNotEmpty && iterations++ < 100000) {
      final current = open.removeFirst();
      if (current == endId) {
        return _reconstructPath(cameFrom, endId, startId, profile, targetName);
      }

      final edges = adjacency[current] ?? [];
      for (final edge in edges) {
        final tentative = (gScore[current] ?? double.infinity) + edge.costM;
        if (tentative < (gScore[edge.to] ?? double.infinity)) {
          cameFrom[edge.to] = current;
          gScore[edge.to]   = tentative;
          final endNode = nodes[endId]!;
          final toNode  = nodes[edge.to]!;
          fScore[edge.to] = tentative +
              _haversineM(toNode.lat, toNode.lon, endNode.lat, endNode.lon);
          open.add(edge.to);
        }
      }
    }
    return null;
  }

  NavRoute _reconstructPath(Map<int, int> cameFrom, int endId, int startId,
      String profile, String targetName) {
    var path = <int>[];
    int current = endId;
    while (current != startId) {
      path.add(current);
      current = cameFrom[current]!;
    }
    path.add(startId);
    path = path.reversed.toList();

    final geometry = path.map((id) {
      final n = nodes[id]!;
      return LatLng(n.lat, n.lon);
    }).toList();

    double totalDist = 0;
    for (int i = 0; i < path.length - 1; i++) {
      final a = nodes[path[i]]!, b = nodes[path[i + 1]]!;
      totalDist += _haversineM(a.lat, a.lon, b.lat, b.lon);
    }

    final speedMs = switch(profile) {
      'driving' => 13.9,
      'cycling' => 4.2,
      _         => 1.4,
    };
    final totalDur = totalDist / speedMs;
    final steps = _generateSteps(path, targetName, speedMs);

    return NavRoute(
      geometry:        geometry,
      steps:           steps,
      totalDistanceM:  totalDist,
      totalDurationS:  totalDur,
      isOffline:       true,
      isGraphRoute:    true,
    );
  }

  List<NavStep> _generateSteps(List<int> path, String targetName, double speedMs) {
    final steps = <NavStep>[];
    if (path.isEmpty) return steps;

    steps.add(NavStep(
      instruction: 'Départ (itinéraire hors-ligne)',
      distanceM:   0,
      durationS:   0,
      location:    LatLng(nodes[path.first]!.lat, nodes[path.first]!.lon),
      maneuver:    'depart',
    ));

    double segDist = 0;
    for (int i = 1; i < path.length - 1; i++) {
      final prev = nodes[path[i - 1]]!;
      final curr = nodes[path[i]]!;
      final next = nodes[path[i + 1]]!;
      segDist += _haversineM(prev.lat, prev.lon, curr.lat, curr.lon);

      final bearIn  = _bearing(prev.lat, prev.lon, curr.lat, curr.lon);
      final bearOut = _bearing(curr.lat, curr.lon, next.lat, next.lon);
      final turn    = ((bearOut - bearIn + 540) % 360) - 180;

      if (turn.abs() > 30) {
        final dir = turn < -30 ? 'Tournez à gauche' : 'Tournez à droite';
        steps.add(NavStep(
          instruction: '$dir (${segDist.round()} m)',
          distanceM:   segDist,
          durationS:   segDist / speedMs,
          location:    LatLng(curr.lat, curr.lon),
          maneuver:    turn < 0 ? 'turn-left' : 'turn-right',
        ));
        segDist = 0;
      }
    }

    if (path.length > 1) {
      final last = nodes[path.last]!;
      steps.add(NavStep(
        instruction: 'Arrivée : $targetName',
        distanceM:   0,
        durationS:   0,
        location:    LatLng(last.lat, last.lon),
        maneuver:    'arrive',
      ));
    }

    return steps;
  }

  static double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat/2) * math.sin(dLat/2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
        math.sin(dLon/2) * math.sin(dLon/2);
    return 2 * R * math.asin(math.sqrt(a));
  }

  static double _bearing(double lat1, double lon1, double lat2, double lon2) {
    final dLon = (lon2 - lon1) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2 * math.pi / 180);
    final x = math.cos(lat1 * math.pi / 180) * math.sin(lat2 * math.pi / 180) -
        math.sin(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

// ── PriorityQueue minimale (privée — pas de conflit avec d'autres libs) ─────
class _PriorityQueue<T> {
  final Comparator<T> _compare;
  final List<T> _heap = [];

  _PriorityQueue(this._compare);

  bool get isNotEmpty => _heap.isNotEmpty;
  bool get isEmpty    => _heap.isEmpty;

  void add(T item) {
    _heap.add(item);
    _bubbleUp(_heap.length - 1);
  }

  T removeFirst() {
    final first = _heap[0];
    final last  = _heap.removeLast();
    if (_heap.isNotEmpty) { _heap[0] = last; _siftDown(0); }
    return first;
  }

  void _bubbleUp(int i) {
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_compare(_heap[i], _heap[parent]) < 0) {
        final tmp = _heap[i]; _heap[i] = _heap[parent]; _heap[parent] = tmp;
        i = parent;
      } else break;
    }
  }

  void _siftDown(int i) {
    while (true) {
      int smallest = i;
      final l = 2 * i + 1, r = 2 * i + 2;
      if (l < _heap.length && _compare(_heap[l], _heap[smallest]) < 0) smallest = l;
      if (r < _heap.length && _compare(_heap[r], _heap[smallest]) < 0) smallest = r;
      if (smallest == i) break;
      final tmp = _heap[i]; _heap[i] = _heap[smallest]; _heap[smallest] = tmp;
      i = smallest;
    }
  }
}
