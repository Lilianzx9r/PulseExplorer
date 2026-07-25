import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart'
    show PmTilesVectorTileProvider;
import '../../tile_cache_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// vector_map_layer.dart
//
// Fond de carte VECTORIEL (PMTiles + vector_map_tiles, qui s'intègre
// directement dans flutter_map — même MapController, mêmes Marker/
// Polyline/PolygonLayer que le reste de l'app, donc AUCUN autre fichier de
// la couche navigation/POI n'a besoin d'être réécrit).
//
// Remplace le TileLayer raster (tile.openstreetmap.org PNG) qui était
// dupliqué dans onze écrans différents. Repli automatique et transparent
// sur ce même rendu raster tant qu'aucune source PMTiles n'est configurée
// (VectorMapConfig.pmtilesSource == null) — voir MIGRATION_NOTES.md pour
// le plan de bascule complet : c'est la PREMIÈRE tranche d'une migration
// en plusieurs étapes, pas un remplacement immédiat et total.
//
// Pourquoi un repli plutôt qu'un branchement direct : obtenir une vraie
// source PMTiles nécessite soit un fichier auto-hébergé (à générer via
// `pmtiles` / tippecanoe à partir d'un extrait OSM), soit une clé API
// Protomaps hébergée — aucune des deux n'est disponible dans cet
// environnement de développement. Le code est prêt ; il suffit de
// renseigner VectorMapConfig.pmtilesSource pour activer le rendu
// vectoriel partout d'un coup.
// ─────────────────────────────────────────────────────────────────────────────

class VectorMapConfig {
  VectorMapConfig._();

  /// URL (hébergée) ou chemin de fichier local vers une archive .pmtiles.
  /// null = mode raster (comportement actuel, inchangé) tant qu'aucune
  /// source n'a été renseignée.
  ///
  /// Exemples une fois une source disponible :
  ///   static String? pmtilesSource = 'https://mon-serveur/france.pmtiles';
  ///   static String? pmtilesSource = '/data/cartes/france.pmtiles'; // fichier préchargé
  static String? pmtilesSource;

  /// Fournit le thème de rendu (couleurs/styles appliqués aux tuiles
  /// vectorielles). Volontairement laissé à renseigner par vous plutôt que
  /// de référencer en dur une classe de thème par défaut : plusieurs
  /// tentatives (`ProtomapsThemes.light()`, à divers emplacements
  /// d'import) ont échoué à la compilation dans cet environnement sans
  /// retour de compilateur pour les corriger de façon fiable — la
  /// documentation en ligne du package ne reflète pas toujours exactement
  /// l'API de la version réellement résolue par `pub get`.
  ///
  /// Pour l'activer, dans votre IDE (avec autocomplétion réelle) :
  ///   1. Ouvrez un fichier .dart quelconque du projet.
  ///   2. Tapez `import 'package:vector_map_tiles/vector_map_tiles.dart';`
  ///      puis dans le code `ProtomapsThemes.` (ou `StyleReader(`,
  ///      `ThemeReader(`) et laissez l'autocomplétion vous montrer le nom
  ///      exact et le chemin d'import corrects pour VOTRE version installée.
  ///   3. Renseignez ici : `VectorMapConfig.themeBuilder = () => ...;`
  ///
  /// Tant que `themeBuilder` est `null`, AppMapLayer reste en mode raster
  /// même si `pmtilesSource` est renseigné (pas de rendu vectoriel sans
  /// thème) — voir MIGRATION_NOTES.md.
  static dynamic Function()? themeBuilder;
}

/// Fond de carte à utiliser dans le `children:` d'un FlutterMap — remplace
/// directement l'ancien bloc :
/// ```dart
/// TileLayer(
///   urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
///   userAgentPackageName: 'com.pulsegpx.app',
///   tileProvider: CachedOsmTileProvider(),
/// ),
/// ```
/// par :
/// ```dart
/// const AppMapLayer(),
/// ```
class AppMapLayer extends StatefulWidget {
  const AppMapLayer({super.key});

  @override
  State<AppMapLayer> createState() => _AppMapLayerState();
}

class _AppMapLayerState extends State<AppMapLayer> {
  Future<_VectorSetup>? _setup;

  @override
  void initState() {
    super.initState();
    // Le rendu vectoriel nécessite À LA FOIS une source PMTiles ET un
    // thème fourni par vous (voir VectorMapConfig.themeBuilder) — sans
    // l'un des deux, repli sur le raster.
    if (VectorMapConfig.pmtilesSource != null && VectorMapConfig.themeBuilder != null) {
      _setup = _load(VectorMapConfig.pmtilesSource!, VectorMapConfig.themeBuilder!);
    }
  }

  Future<_VectorSetup> _load(String source, dynamic Function() themeBuilder) async {
    final provider = await PmTilesVectorTileProvider.fromSource(source);
    final theme = themeBuilder();
    return _VectorSetup(provider, theme);
  }

  Widget _raster() => fm.TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.pulsegpx.app',
        tileProvider: CachedOsmTileProvider(),
      );

  @override
  Widget build(BuildContext context) {
    if (_setup == null) return _raster();
    return FutureBuilder<_VectorSetup>(
      future: _setup,
      builder: (context, snap) {
        // Pendant le chargement de la source PMTiles, ou en cas d'échec
        // (fichier introuvable, source hors-ligne...), repli sur le rendu
        // raster plutôt qu'un écran vide.
        if (snap.connectionState != ConnectionState.done ||
            snap.hasError || !snap.hasData) {
          return _raster();
        }
        return VectorTileLayer(
          theme: snap.data!.theme,
          tileProviders: TileProviders({'protomaps': snap.data!.provider}),
        );
      },
    );
  }
}

class _VectorSetup {
  final PmTilesVectorTileProvider provider;
  final dynamic theme; // type inféré (vector_tile_renderer.Theme) — jamais
                        // nommé explicitement pour éviter toute collision
                        // avec Theme de Flutter Material (même piège que
                        // Path/dart:ui vs Path/latlong2 rencontré plus tôt).
  const _VectorSetup(this.provider, this.theme);
}
