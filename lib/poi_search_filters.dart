// ─────────────────────────────────────────────────────────────────────────────
// poi_search_filters.dart
//
// Filtres avancés appliqués côté client aux résultats Overpass déjà reçus :
// ouvert maintenant, rayon de recherche, accessible camping-car, avec
// parking, gratuit. Ce sont des filtres "best effort" qui dépendent
// entièrement de la qualité du tagging OSM sur chaque POI — un résultat non
// tagué n'est jamais exclu par excès de prudence (voir chaque méthode).
// ─────────────────────────────────────────────────────────────────────────────

/// Rayon de recherche prédéfini, en mètres. `null` = zone visible de la
/// carte (comportement historique, pas de rayon fixe).
class PoiSearchRadius {
  final String label;
  final double? meters;
  const PoiSearchRadius(this.label, this.meters);

  static const zoneVisible = PoiSearchRadius('Zone visible', null);
  static const options = [
    zoneVisible,
    PoiSearchRadius('500 m', 500),
    PoiSearchRadius('2 km', 2000),
    PoiSearchRadius('5 km', 5000),
    PoiSearchRadius('20 km', 20000),
  ];
}

class PoiSearchFilters {
  final bool openNowOnly;
  final bool motorhomeOnly;   // accessible / adapté camping-car
  final bool parkingOnly;     // parking sur place renseigné
  final bool freeOnly;        // gratuit (fee=no)

  const PoiSearchFilters({
    this.openNowOnly    = false,
    this.motorhomeOnly  = false,
    this.parkingOnly    = false,
    this.freeOnly       = false,
  });

  bool get isActive => openNowOnly || motorhomeOnly || parkingOnly || freeOnly;

  PoiSearchFilters copyWith({
    bool? openNowOnly,
    bool? motorhomeOnly,
    bool? parkingOnly,
    bool? freeOnly,
  }) => PoiSearchFilters(
        openNowOnly:   openNowOnly   ?? this.openNowOnly,
        motorhomeOnly: motorhomeOnly ?? this.motorhomeOnly,
        parkingOnly:   parkingOnly   ?? this.parkingOnly,
        freeOnly:      freeOnly      ?? this.freeOnly,
      );

  /// Teste si les tags OSM d'un POI passent les filtres actifs.
  /// Principe : en cas d'information manquante ou non tagguée, le POI est
  /// conservé (on ne masque pas un lieu simplement parce qu'OSM n'a pas
  /// l'info) — SAUF pour "ouvert maintenant", où l'absence d'info ne permet
  /// pas non plus d'exclure (même logique, cf. [OpeningHours.isOpenNow]).
  bool matches(Map<String, String> tags) {
    if (openNowOnly) {
      final open = OpeningHours.isOpenNow(tags['opening_hours'] ?? '');
      if (open == false) return false; // explicitement fermé → exclu
    }
    if (motorhomeOnly) {
      final ok = tags['motorhome'] == 'yes' ||
          tags['caravan'] == 'yes' ||
          tags['tourism'] == 'caravan_site';
      // Ici on est plus strict : "uniquement camping-car" doit être un tag
      // explicite, sinon le filtre ne sert à rien.
      if (!ok) return false;
    }
    if (parkingOnly) {
      final ok = tags['parking'] != null ||
          tags.containsKey('capacity:disabled') || // heuristique faible mais indicative
          tags['amenity'] == 'parking';
      if (!ok) return false;
    }
    if (freeOnly) {
      // fee=no explicite, ou pas de tag fee du tout pour les catégories où
      // c'est rarement payant (on reste permissif par défaut) — mais dès
      // qu'un tag fee=yes existe, on exclut.
      if (tags['fee'] == 'yes') return false;
    }
    return true;
  }
}

/// Évaluateur best-effort du tag OSM `opening_hours`. Couvre les formats les
/// plus courants (24/7, jours simples/plages, horaires multiples, "off").
/// Ne gère PAS les jours fériés (PH), ni les exceptions saisonnières
/// complexes — dans ces cas, retourne `null` (statut inconnu) plutôt qu'une
/// réponse hasardeuse.
class OpeningHours {
  OpeningHours._();

  static const _dayCodes = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

  /// true = ouvert, false = fermé, null = statut indéterminable.
  static bool? isOpenNow(String raw, {DateTime? now}) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s == '24/7') return true;

    final n = now ?? DateTime.now();
    bool? result;

    for (final group in s.split(';')) {
      final g = group.trim();
      if (g.isEmpty) continue;
      if (g.toUpperCase().contains('PH')) continue; // jours fériés : ignoré

      final match = _evalGroup(g, n);
      // En syntaxe opening_hours, les groupes suivants peuvent surcharger
      // les précédents pour le même jour — on garde donc le dernier match
      // applicable rencontré.
      if (match != null) result = match;
    }
    return result;
  }

  static bool? _evalGroup(String group, DateTime now) {
    final dayRegex = RegExp(
        r'^((?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?'
        r'(?:,(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?)*)'
        r'\s+(.+)$');
    final m = dayRegex.firstMatch(group);

    Set<int> days;
    String timeSpec;
    if (m != null) {
      days = _parseDays(m.group(1)!);
      timeSpec = m.group(2)!.trim();
    } else {
      days = {1, 2, 3, 4, 5, 6, 7}; // pas de jour précisé → tous les jours
      timeSpec = group;
    }

    if (!days.contains(now.weekday)) return null; // groupe non applicable aujourd'hui

    final t = timeSpec.toLowerCase();
    if (t == 'off' || t == 'closed') return false;
    if (t == '24/7' || t == '00:00-24:00') return true;

    final nowMinutes = now.hour * 60 + now.minute;
    for (final range in timeSpec.split(',')) {
      final rm = RegExp(r'^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$')
          .firstMatch(range.trim());
      if (rm == null) continue;
      final start = int.parse(rm.group(1)!) * 60 + int.parse(rm.group(2)!);
      final end   = int.parse(rm.group(3)!) * 60 + int.parse(rm.group(4)!);
      if (end > start) {
        if (nowMinutes >= start && nowMinutes < end) return true;
      } else {
        // Plage à cheval sur minuit (ex: 22:00-02:00)
        if (nowMinutes >= start || nowMinutes < end) return true;
      }
    }
    return false; // jour applicable mais aucune plage horaire ne couvre "now"
  }

  static Set<int> _parseDays(String spec) {
    final days = <int>{};
    for (final part in spec.split(',')) {
      if (part.contains('-')) {
        final bounds = part.split('-');
        final start = _dayCodes.indexOf(bounds[0]) + 1;
        final end   = _dayCodes.indexOf(bounds[1]) + 1;
        if (start == 0 || end == 0) continue;
        var d = start;
        while (true) {
          days.add(d);
          if (d == end) break;
          d = d == 7 ? 1 : d + 1;
        }
      } else {
        final d = _dayCodes.indexOf(part) + 1;
        if (d > 0) days.add(d);
      }
    }
    return days;
  }
}
