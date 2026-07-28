import '../overpass_poi_service.dart';
import 'agent_result.dart';
import 'discovery_agent.dart';
import 'discovery_request.dart';

/// Agent géographique basé sur OpenStreetMap/Overpass.
///
/// Il ne "devine" pas les lieux : il recherche des objets géographiques
/// existants dans la zone fournie par la requête.
class OsmPoiAgent implements DiscoveryAgent {
  @override
  String get id => 'osm_overpass';

  @override
  String get name => 'Agent OpenStreetMap / Overpass';

  @override
  Future<AgentResult> execute(DiscoveryRequest request) async {
    final started = DateTime.now();

    if (request.bounds == null) {
      return AgentResult(
        agentId: id,
        agentName: name,
        points: const [],
        warnings: const [
          'Aucune zone géographique fournie : l’agent OSM est ignoré.',
        ],
        duration: DateTime.now().difference(started),
      );
    }

    try {
      final b = request.bounds!;
      final categories = kPoiCategories
          .map((c) => PoiCategory(
                id: c.id,
                label: c.label,
                emoji: c.emoji,
                overpassFilter: c.overpassFilter,
                color: c.color,
                selected: _isUsefulForRequest(c, request),
              ))
          .where((c) => c.selected)
          .toList();

      final results = await OverpassPoiService.search(
        minLat: b.south,
        maxLat: b.north,
        minLon: b.west,
        maxLon: b.east,
        categories: categories,
        limit: 300,
        sortOrigin: b.center,
      );

      return AgentResult(
        agentId: id,
        agentName: name,
        points: results.map((r) => r.toPoiPoint()).toList(),
        duration: DateTime.now().difference(started),
      );
    } catch (e) {
      return AgentResult(
        agentId: id,
        agentName: name,
        points: const [],
        warnings: ['Échec de l’agent OSM/Overpass : $e'],
        duration: DateTime.now().difference(started),
      );
    }
  }

  bool _isUsefulForRequest(PoiCategory category, DiscoveryRequest request) {
    if (request.interests.isEmpty) {
      return const {
        'viewpoint',
        'village',
        'peak',
        'waterfall',
        'lake',
        'castle',
        'monument',
        'attraction',
        'museum',
      }.contains(category.id);
    }

    final text = '${request.query} ${request.interests.join(' ')}'.toLowerCase();

    if (text.contains('moto')) {
      return const {
        'viewpoint',
        'peak',
        'waterfall',
        'lake',
        'village',
        'castle',
        'monument',
        'attraction',
      }.contains(category.id);
    }

    if (text.contains('nature') || text.contains('paysage')) {
      return const {
        'viewpoint',
        'peak',
        'waterfall',
        'lake',
        'cave',
      }.contains(category.id);
    }

    return const {
      'viewpoint',
      'village',
      'monument',
      'castle',
      'attraction',
      'museum',
    }.contains(category.id);
  }
}
