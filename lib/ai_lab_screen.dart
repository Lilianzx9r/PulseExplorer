import 'package:flutter/material.dart';

import 'agents/agents.dart';
import 'html_poi_extractor.dart';

class AiLabScreen extends StatefulWidget {
  const AiLabScreen({super.key});

  @override
  State<AiLabScreen> createState() => _AiLabScreenState();
}

class _AiLabScreenState extends State<AiLabScreen> {
  final _store = AgentConfigurationStore();
  List<AgentDefinition> _agents = [];
  List<SourceDefinition> _sources = SourceCatalog.defaults;
  List<OpenRouterModel> _freeModels = [];
  bool _loadingModels = false;
  String? _modelError;

  @override
  void initState() {
    super.initState();
    _loadAgents();
  }

  Future<void> _loadAgents() async {
    final saved = await _store.loadAgents();
    if (!mounted) return;
    setState(() => _agents = saved.isEmpty ? _defaultAgents() : saved);
  }

  List<AgentDefinition> _defaultAgents() => [
        const AgentDefinition(
          id: 'general',
          name: 'Exploration générale',
          description: 'Recherche large de lieux intéressants.',
          role: 'exploration générale',
          instructions: 'Identifie les lieux les plus intéressants et variés.',
          providerId: 'openrouter',
          model: 'openrouter/free',
        ),
        const AgentDefinition(
          id: 'moto',
          name: 'Expert moto',
          description: 'Routes panoramiques, cols et étapes à moto.',
          role: 'voyage à moto',
          instructions: 'Recherche routes panoramiques, cols et points de vue.',
          providerId: 'openrouter',
          model: 'openrouter/free',
        ),
        const AgentDefinition(
          id: 'nature',
          name: 'Expert nature',
          description: 'Gorges, cascades, lacs et belvédères.',
          role: 'nature et paysages',
          instructions: 'Recherche des sites naturels accessibles depuis la route ou après une courte marche.',
          providerId: 'openrouter',
          model: 'openrouter/free',
        ),
        const AgentDefinition(
          id: 'heritage',
          name: 'Expert patrimoine',
          description: 'Villages, monuments et histoire locale.',
          role: 'villages et patrimoine',
          instructions: 'Recherche villages remarquables, châteaux et patrimoine.',
          providerId: 'openrouter',
          model: 'openrouter/free',
        ),
      ];

  Future<void> _saveAgents() => _store.saveAgents(_agents);

  Future<void> _refreshOpenRouterModels() async {
    if (!HtmlPoiExtractor.hasApiKey) {
      setState(() => _modelError = 'Aucune clé OpenRouter configurée.');
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelError = null;
    });
    try {
      final models = await OpenRouterProvider.fetchFreeModels(
        apiKey: HtmlPoiExtractor.apiKey,
      );
      if (!mounted) return;
      setState(() => _freeModels = models);
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelError = '$e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _toggleAgent(int index, bool value) {
    setState(() => _agents[index] = _agents[index].copyWith(enabled: value));
    _saveAgents();
  }

  void _toggleSource(int index, bool value) {
    setState(() => _sources[index] = _sources[index].copyWith(enabled: value));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Laboratoire IA'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Agents', icon: Icon(Icons.smart_toy_outlined)),
              Tab(text: 'Providers', icon: Icon(Icons.cloud_outlined)),
              Tab(text: 'Sources', icon: Icon(Icons.public)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildAgentsTab(),
            _buildProvidersTab(),
            _buildSourcesTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentsTab() {
    if (_agents.isEmpty) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'Agents configurables',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Activez ou désactivez les rôles utilisés par Explorer.'),
        const SizedBox(height: 12),
        ..._agents.asMap().entries.map((entry) {
          final i = entry.key;
          final a = entry.value;
          return Card(
            child: SwitchListTile(
              value: a.enabled,
              onChanged: (v) => _toggleAgent(i, v),
              title: Text(a.name),
              subtitle: Text('${a.description}\n${a.providerId} / ${a.model}'),
              isThreeLine: true,
            ),
          );
        }),
      ],
    );
  }

  Widget _buildProvidersTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _providerCard(
          'OpenRouter',
          'Modèles gratuits dynamiques + openrouter/free',
          HtmlPoiExtractor.hasApiKey,
        ),
        _providerCard('Google Gemini', 'Free Tier selon le compte et le modèle', false),
        _providerCard('Mistral AI', 'Free Tier selon le compte', false),
        _providerCard('Groq', 'Free Tier selon le compte', false),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _loadingModels ? null : _refreshOpenRouterModels,
          icon: const Icon(Icons.refresh),
          label: Text(_loadingModels ? 'Recherche...' : 'Récupérer les modèles OpenRouter gratuits'),
        ),
        if (_modelError != null) ...[
          const SizedBox(height: 8),
          Text(_modelError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        if (_freeModels.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('${_freeModels.length} modèles gratuits détectés', style: const TextStyle(fontWeight: FontWeight.bold)),
          ..._freeModels.take(50).map((m) => ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle_outline),
                title: Text(m.name),
                subtitle: Text(m.id),
              )),
        ],
      ],
    );
  }

  Widget _providerCard(String name, String description, bool configured) {
    return Card(
      child: ListTile(
        leading: Icon(configured ? Icons.check_circle : Icons.radio_button_unchecked),
        title: Text(name),
        subtitle: Text(description),
        trailing: Text(configured ? 'Configuré' : 'À configurer'),
      ),
    );
  }

  Widget _buildSourcesTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('Sources activables', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ..._sources.asMap().entries.map((entry) {
          final i = entry.key;
          final s = entry.value;
          return Card(
            child: SwitchListTile(
              value: s.enabled,
              onChanged: (v) => _toggleSource(i, v),
              title: Text(s.name),
              subtitle: Text(s.description),
            ),
          );
        }),
      ],
    );
  }
}
