import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'agents/agents.dart';
import 'html_poi_extractor.dart';
import 'nominatim_helper.dart';
import 'ai_lab_screen.dart';

class _AgentDefinition {
  final String id;
  final String label;
  final String description;
  final String model;
  final DiscoveryAgent Function(AiProvider provider) create;

  const _AgentDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.model,
    required this.create,
  });
}

/// Interface de test multi-agents / multi-modèles.
class ExplorerScreen extends StatefulWidget {
  final BoundingBox? initialBounds;

  const ExplorerScreen({super.key, this.initialBounds});

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  final _queryController = TextEditingController();
  final _interestsController = TextEditingController();

  List<_AgentDefinition> _definitions = [];
  final Map<String, bool> _enabled = {};

  bool _osmEnabled = true;
  bool _running = false;

  DiscoveryRunResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();

    _queryController.text = HtmlPoiExtractor.lastRequest;

    final models = HtmlPoiExtractor.kFreeModels;
    final modelA = models.isNotEmpty
        ? models[0].id
        : HtmlPoiExtractor.selectedModel;
    final modelB = models.length > 1 ? models[1].id : modelA;

    _definitions = [
      _AgentDefinition(
        id: 'general-a',
        label: 'IA généraliste A',
        description: 'Exploration générale',
        model: modelA,
        create: (p) => MultiAiAgentFactory.general(p),
      ),
      _AgentDefinition(
        id: 'general-b',
        label: 'IA généraliste B',
        description: 'Même demande, autre modèle',
        model: modelB,
        create: (p) => MultiAiAgentFactory.general(p),
      ),
      _AgentDefinition(
        id: 'moto',
        label: 'Expert moto / routes',
        description: 'Cols, routes panoramiques et points de vue',
        model: modelA,
        create: (p) => MultiAiAgentFactory.motorcycling(p),
      ),
      _AgentDefinition(
        id: 'nature',
        label: 'Expert nature',
        description: 'Gorges, cascades, lacs, belvédères',
        model: modelB,
        create: (p) => MultiAiAgentFactory.nature(p),
      ),
      _AgentDefinition(
        id: 'heritage',
        label: 'Expert villages / patrimoine',
        description: 'Villages, monuments et patrimoine',
        model: modelA,
        create: (p) => MultiAiAgentFactory.heritage(p),
      ),
    ];

    for (final d in _definitions) {
      _enabled[d.id] = true;
    }

    _refreshFreeModels();
  }

  Future<void> _refreshFreeModels() async {
    if (!HtmlPoiExtractor.hasApiKey) return;
    try {
      final models = await OpenRouterProvider.fetchFreeModels(
        apiKey: HtmlPoiExtractor.apiKey,
      );
      if (!mounted || models.isEmpty) return;

      final modelA = models.first.id;
      final modelB = models.length > 1 ? models[1].id : modelA;
      setState(() {
        _definitions = [
          _AgentDefinition(
            id: 'general-a',
            label: 'IA généraliste A',
            description: 'Exploration générale',
            model: modelA,
            create: (p) => MultiAiAgentFactory.general(p),
          ),
          _AgentDefinition(
            id: 'general-b',
            label: 'IA généraliste B',
            description: 'Même demande, autre modèle gratuit',
            model: modelB,
            create: (p) => MultiAiAgentFactory.general(p),
          ),
          _AgentDefinition(
            id: 'moto',
            label: 'Expert moto / routes',
            description: 'Cols, routes panoramiques et points de vue',
            model: modelA,
            create: (p) => MultiAiAgentFactory.motorcycling(p),
          ),
          _AgentDefinition(
            id: 'nature',
            label: 'Expert nature',
            description: 'Gorges, cascades, lacs, belvédères',
            model: modelB,
            create: (p) => MultiAiAgentFactory.nature(p),
          ),
          _AgentDefinition(
            id: 'heritage',
            label: 'Expert villages / patrimoine',
            description: 'Villages, monuments et patrimoine',
            model: modelA,
            create: (p) => MultiAiAgentFactory.heritage(p),
          ),
        ];
        for (final d in _definitions) {
          _enabled.putIfAbsent(d.id, () => true);
        }
      });
    } catch (_) {
      // L'interface conserve les modèles de secours déjà disponibles.
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _interestsController.dispose();
    super.dispose();
  }

  Future<void> _runDiscovery() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() => _error = 'Saisissez une demande de découverte.');
      return;
    }

    final active = <DiscoveryAgent>[];

    if (HtmlPoiExtractor.hasApiKey) {
      for (final definition in _definitions) {
        if (_enabled[definition.id] != true) continue;

        final provider = OpenRouterProvider(model: definition.model);
        active.add(definition.create(provider));
      }
    }

    if (_osmEnabled) {
      active.add(OsmPoiAgent());
    }

    if (active.isEmpty) {
      setState(() => _error =
          'Aucun agent IA disponible. Configurez une clé OpenRouter ou activez '
          'un agent géographique avec une zone.');
      return;
    }

    if (_osmEnabled && widget.initialBounds == null && !HtmlPoiExtractor.hasApiKey) {
      setState(() => _error =
          'La recherche ne peut pas encore démarrer : aucun agent IA n’est '
          'configuré et aucune zone géographique n’est fournie pour OSM.');
      return;
    }

    final interests = _interestsController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    HtmlPoiExtractor.setLastRequest(query);

    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await AgentManager(active).discover(
        DiscoveryRequest(
          query: query,
          interests: interests,
          bounds: _toLatLngBounds(widget.initialBounds),
        ),
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _running = false;
      });
    }
  }

  LatLngBounds? _toLatLngBounds(BoundingBox? bbox) {
    if (bbox == null) return null;
    return LatLngBounds(
      LatLng(bbox.minLat, bbox.minLon),
      LatLng(bbox.maxLat, bbox.maxLon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explorer multi-agents'),
        actions: [
          IconButton(
            tooltip: 'Configurer agents, providers et sources',
            icon: const Icon(Icons.tune),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AiLabScreen()),
              );
            },
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${_result!.pois.length} POI',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          final form = _buildRequestPanel(context);
          final results = _buildResultsPanel(context);

          return wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 430, child: form),
                    const VerticalDivider(width: 1),
                    Expanded(child: results),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    form,
                    const SizedBox(height: 16),
                    results,
                  ],
                );
        },
      ),
    );
  }

  Widget _buildRequestPanel(BuildContext context) {
    final apiReady = HtmlPoiExtractor.hasApiKey;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nouvelle exploration',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'La même requête peut être envoyée à plusieurs modèles et agents spécialisés. Les résultats sont ensuite fusionnés.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _queryController,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'Votre demande',
              hintText:
                  'Ex. Je souhaite visiter le Vercors en moto avec les plus belles routes, villages et sites naturels.',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _interestsController,
            decoration: const InputDecoration(
              labelText: 'Centres d’intérêt',
              hintText: 'moto, nature, villages, routes panoramiques',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Agents IA en concurrence',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          if (!apiReady)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Aucune clé OpenRouter configurée : les agents IA sont indisponibles. L’agent OSM peut toutefois fonctionner si une zone est sélectionnée.',
                ),
              ),
            ),
          ..._definitions.map(
            (definition) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled[definition.id] ?? false,
              onChanged: apiReady
                  ? (v) => setState(
                        () => _enabled[definition.id] = v ?? false,
                      )
                  : null,
              title: Text(definition.label),
              subtitle: Text(
                '${definition.description}\n${_modelLabel(definition.model)}',
              ),
              isThreeLine: true,
              secondary: const Icon(Icons.auto_awesome),
            ),
          ),
          const Divider(),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _osmEnabled,
            onChanged: (v) => setState(() => _osmEnabled = v ?? false),
            title: const Text('OpenStreetMap / Overpass'),
            subtitle: Text(
              widget.initialBounds == null
                  ? 'Aucune zone sélectionnée : sélectionnez une zone pour activer la recherche OSM.'
                  : 'Recherche géographique dans ${widget.initialBounds!.displayName}',
            ),
            secondary: const Icon(Icons.map_outlined),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _running ? null : _runDiscovery,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.rocket_launch),
              label: Text(
                _running
                    ? 'Exploration en cours…'
                    : 'Lancer la compétition multi-agents',
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _modelLabel(String id) {
    for (final model in HtmlPoiExtractor.kFreeModels) {
      if (model.id == id) return model.label;
    }
    return id;
  }

  Widget _buildResultsPanel(BuildContext context) {
    final result = _result;
    if (result == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub_outlined, size: 64),
              SizedBox(height: 12),
              Text(
                'Les résultats de la compétition entre agents apparaîtront ici.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSummary(result),
        const SizedBox(height: 12),
        if (result.warnings.isNotEmpty) _buildWarnings(result.warnings),
        ...result.pois.map(_buildPoiCard),
      ],
    );
  }

  Widget _buildSummary(DiscoveryRunResult result) {
    final confirmed = result.pois.where((p) => p.agentCount >= 2).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _metric('POI retenus', '${result.pois.length}'),
            _metric('Confirmés par plusieurs agents', '$confirmed'),
            _metric('Agents exécutés', '${result.agentResults.length}'),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.grey)),
      ],
    );
  }

  Widget _buildWarnings(List<String> warnings) {
    return Card(
      color: Colors.amber.withOpacity(.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Informations',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            ...warnings.map((w) => Text('• $w')),
          ],
        ),
      ),
    );
  }

  Widget _buildPoiCard(ConsensusPoi poi) {
    final point = poi.point;
    final confidence = (poi.confidence * 100).round();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: CircleAvatar(child: Text('${poi.agentCount}')),
        title: Text(point.name),
        subtitle: Text(
          '${point.type ?? 'Lieu'} • Confiance $confidence%',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if ((point.description ?? '').isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(point.description!),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Coordonnées : ${point.lat.toStringAsFixed(5)}, ${point.lon.toStringAsFixed(5)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: poi.opinions
                  .map(
                    (o) => Chip(
                      avatar: const Icon(Icons.check, size: 16),
                      label: Text(o.agentName),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}
