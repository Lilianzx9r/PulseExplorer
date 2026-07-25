import 'package:flutter/material.dart';
import 'poi_layer.dart';

/// Un dossier regroupant plusieurs couches POI
class PoiFolder {
  String         label;
  final String   id;
  bool           visible;
  bool           expanded;
  List<PoiLayer> layers;

  PoiFolder({
    required this.label,
    required this.layers,
    this.visible  = true,
    this.expanded = true,
    String? id,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
    'id': id, 'label': label,
    'visible': visible, 'expanded': expanded,
    'layers': layers.map((l) => l.toJson()).toList(),
  };

  factory PoiFolder.fromJson(Map<String, dynamic> j) => PoiFolder(
    id:       j['id'] ?? '',
    label:    j['label'] ?? 'Dossier',
    visible:  j['visible']  ?? true,
    expanded: j['expanded'] ?? true,
    layers:   (j['layers'] as List? ?? [])
        .map((e) => PoiLayer.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
