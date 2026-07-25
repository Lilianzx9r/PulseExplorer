import 'package:flutter_map/flutter_map.dart';

/// Requête commune adressée aux agents de découverte.
class DiscoveryRequest {
  final String query;
  final String? context;
  final LatLngBounds? bounds;
  final List<String> interests;

  const DiscoveryRequest({
    required this.query,
    this.context,
    this.bounds,
    this.interests = const [],
  });

  DiscoveryRequest copyWith({
    String? query,
    String? context,
    LatLngBounds? bounds,
    List<String>? interests,
  }) =>
      DiscoveryRequest(
        query: query ?? this.query,
        context: context ?? this.context,
        bounds: bounds ?? this.bounds,
        interests: interests ?? this.interests,
      );
}
