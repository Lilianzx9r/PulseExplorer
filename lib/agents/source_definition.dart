class SourceDefinition {
  final String id;
  final String name;
  final String description;
  final bool enabled;

  const SourceDefinition({
    required this.id,
    required this.name,
    required this.description,
    this.enabled = true,
  });

  SourceDefinition copyWith({bool? enabled}) => SourceDefinition(
        id: id,
        name: name,
        description: description,
        enabled: enabled ?? this.enabled,
      );
}

class SourceCatalog {
  static const defaults = <SourceDefinition>[
    SourceDefinition(id: 'osm', name: 'OpenStreetMap / Overpass', description: 'Objets géographiques et POI cartographiques.'),
    SourceDefinition(id: 'nominatim', name: 'Nominatim', description: 'Géocodage des lieux et des territoires.'),
    SourceDefinition(id: 'wikidata', name: 'Wikidata', description: 'Enrichissement structuré et identifiants de lieux.'),
    SourceDefinition(id: 'wikipedia', name: 'Wikipedia / Wikivoyage', description: 'Descriptions et contexte touristique.'),
    SourceDefinition(id: 'commons', name: 'Wikimedia Commons', description: 'Photos et médias associés aux lieux.'),
  ];
}
