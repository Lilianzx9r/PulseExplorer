/// Résultat minimal d'une recherche de lieu auprès d'une [PoiSource],
/// indépendant du modèle interne `PoiPoint` utilisé pour l'affichage carte
/// (conversion faite par l'appelant, pour ne pas coupler les sources à
/// l'UI).
class PoiSourceResult {
  final String id;
  final String name;
  final double? lat;
  final double? lon;
  final String? category;
  final String sourceId;

  const PoiSourceResult({
    required this.id,
    required this.name,
    required this.sourceId,
    this.lat,
    this.lon,
    this.category,
  });
}

/// Détails enrichis d'un lieu, obtenus après un premier résultat de
/// recherche (description, liens, horaires si disponibles).
class PoiSourceDetails {
  final String id;
  final String? description;
  final String? officialWebsite;
  final String? openingHours;
  final List<String> imageUrls;

  const PoiSourceDetails({
    required this.id,
    this.description,
    this.officialWebsite,
    this.openingHours,
    this.imageUrls = const [],
  });
}

/// Abstraction commune à toutes les sources de données ouvertes
/// (OpenStreetMap, Overpass, Wikipedia, Wikidata, Wikimedia Commons,
/// OpenTripMap, GeoNames, DataTourisme, OpenRouteService, ...).
///
/// Chaque source est indépendante et peut être interrogée directement par
/// un agent, ou via un service d'enrichissement qui combine plusieurs
/// sources pour un même POI.
abstract class PoiSource {
  /// Identifiant stable de la source (ex. "wikidata", "overpass").
  String get id;

  /// Nom lisible affiché dans le Laboratoire IA / onglet Sources.
  String get name;

  /// Recherche de lieux correspondant à une requête libre, dans une zone
  /// géographique optionnelle (rayon en mètres autour de lat/lon).
  Future<List<PoiSourceResult>> search({
    required String query,
    double? lat,
    double? lon,
    double? radiusMeters,
    int limit = 20,
  });

  /// Détails enrichis d'un lieu déjà identifié par [search].
  Future<PoiSourceDetails?> details(String id);

  /// URLs d'images associées à un lieu, si la source en fournit.
  Future<List<String>> images(String id);

  /// Catégories/types que cette source est capable de renvoyer, utile pour
  /// afficher les capacités d'une source dans l'UI.
  List<String> categories();
}
