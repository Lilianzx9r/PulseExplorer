/// Paramètres de zoom pour l'affichage des POI
/// Stockés en mémoire (persistés via session_store si besoin)
class PoiZoomSettings {
  double zoomLabel; // zoom minimum pour afficher le nom
  double zoomThumb; // zoom minimum pour afficher la miniature photo

  PoiZoomSettings({
    this.zoomLabel = 10.0,
    this.zoomThumb = 13.0,
  });

  Map<String, dynamic> toJson() => {
    'zoomLabel': zoomLabel,
    'zoomThumb': zoomThumb,
  };

  factory PoiZoomSettings.fromJson(Map<String, dynamic> j) => PoiZoomSettings(
    zoomLabel: (j['zoomLabel'] as num?)?.toDouble() ?? 10.0,
    zoomThumb: (j['zoomThumb'] as num?)?.toDouble() ?? 13.0,
  );
}
