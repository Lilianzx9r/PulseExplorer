import 'package:flutter/material.dart';

class PoiPoint {
  final String       name;
  final double       lat;
  final double       lon;
  final String?      description;
  final String?      type;
  final List<String> photoUrls;    // URLs photos en ligne
  final List<String> localPhotos;  // chemins photos locales

  const PoiPoint({
    required this.name,
    required this.lat,
    required this.lon,
    this.description,
    this.type,
    this.photoUrls  = const [],
    this.localPhotos = const [],
  });

  bool get hasPhotos  => photoUrls.isNotEmpty || localPhotos.isNotEmpty;
  bool get hasDetails => description != null && description!.isNotEmpty;

  PoiPoint copyWith({
    String? name, double? lat, double? lon,
    String? description, String? type,
    List<String>? photoUrls, List<String>? localPhotos,
  }) => PoiPoint(
    name:        name        ?? this.name,
    lat:         lat         ?? this.lat,
    lon:         lon         ?? this.lon,
    description: description ?? this.description,
    type:        type        ?? this.type,
    photoUrls:   photoUrls   ?? this.photoUrls,
    localPhotos: localPhotos ?? this.localPhotos,
  );

  Map<String, dynamic> toJson() => {
    'name': name, 'lat': lat, 'lon': lon,
    'description': description, 'type': type,
    'photoUrls': photoUrls, 'localPhotos': localPhotos,
  };

  factory PoiPoint.fromJson(Map<String, dynamic> j) => PoiPoint(
    name:        j['name']        ?? '',
    lat:         (j['lat']  as num).toDouble(),
    lon:         (j['lon']  as num).toDouble(),
    description: j['description'],
    type:        j['type'],
    photoUrls:   (j['photoUrls']   as List? ?? []).cast<String>(),
    localPhotos: (j['localPhotos'] as List? ?? []).cast<String>(),
  );
}

class PoiLayer {
  String         label;
  List<PoiPoint> points;
  Color          color;
  bool           visible;
  final String   id;

  PoiLayer({
    required this.label,
    required this.points,
    required this.color,
    this.visible = true,
    String? id,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
    'id': id, 'label': label,
    'color': color.value, 'visible': visible,
    'points': points.map((p) => p.toJson()).toList(),
  };

  factory PoiLayer.fromJson(Map<String, dynamic> j) => PoiLayer(
    id:      j['id'] ?? '',
    label:   j['label'] ?? 'POI',
    color:   Color(j['color'] as int),
    visible: j['visible'] ?? true,
    points:  (j['points'] as List)
        .map((p) => PoiPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
  );
}

const List<Color> kPoiColors = [
  Color(0xFF00BCD4), Color(0xFFFF5722), Color(0xFF9C27B0),
  Color(0xFF4CAF50), Color(0xFFFF9800), Color(0xFF2196F3),
  Color(0xFFE91E63), Color(0xFF795548), Color(0xFF607D8B),
];

Color poiColorForIndex(int i) => kPoiColors[i % kPoiColors.length];
