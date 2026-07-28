import 'package:flutter/material.dart';

import 'agents/agents.dart';
import 'agents/provider_key_store.dart';
import 'agents/provider_test_service.dart' show kLocalProviders;
import 'html_poi_extractor.dart';
import 'widgets/provider_key_dialog.dart';

class AiLabScreen extends StatefulWidget {
  const AiLabScreen({super.key});

  @override
  State<AiLabScreen> createState() => _AiLabScreenState();
}

class _AiLabScreenState extends State<AiLabScreen> {
  final _store = AgentConfigurationStore();
  final _keyStore = ProviderKeyStore();
  List<AgentDefinition> _agents = [];
  List<SourceDefinition> _sources = SourceCatalog.defaults;
  List<OpenRouterModel> _freeModels = [];
  bool _loadingModels = false;
  String? _modelError;

  /// État réel de configuration par provider (id -> clé présente ?).
  Map<String, bool> _providerConfigured = {};
  bool _loadingProviders = true;

  @override
  void initState() {
    super.initState();
    _loadAgents();
    _loadProviderStatus();
  }

  Future<void> _loadAgents() async {
    final saved = await _store.loadAgents();
    if (!mounted) return;
    setState(() => _agents = saved.isEmpty ? _defaultAgents() : saved);
  }

  Future<void> _loadProviderStatus() async {
    setState(() => _loadingProviders = true);
    final keys = await _keyStore.loadAll();
    final baseUrls = await _keyStore.loadAllBaseUrls();
    if (!mounted) return;
    setState(() {
      _providerConfigured = {
        for (final def in ProviderCatalog.definitions)
          def.id: kLocalProviders.contains(def.id)
              ? (baseUrls[def.id]?.trim().isNotEmpty ?? false)
              : (keys[def.id]?.trim().isNotEmpty ?? false),
        // OpenRouter reste également considéré configuré si une clé a été
        // saisie via l'onglet "Analyser un blog" (compat. historique).
        'openrouter': (keys['openrouter']?.trim().isNotEmpty ?? false) ||
            HtmlPoiExtractor.hasApiKey,
      };
      _loadingProviders = false;
    });
  }

  /// Catalogue par défaut : les 15 agents thématiques de l'architecture
  /// cible (`AgentPresets`). L'utilisateur peut désactiver ceux qu'il ne
  /// souhaite pas utiliser depuis l'onglet Agents ; ses choix sont ensuite
  /// persistés par `AgentConfigurationStore` et prennent le pas sur ce
  /// catalogue par défaut au chargement suivant.
  List<AgentDefinition> _defaultAgents() => AgentPresets.all;

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

  Future<void> _openProviderKeyDialog(String providerId, String providerName) async {
    final changed = await ProviderKeyDialog.show(
      context,
      providerId: providerId,
      providerName: providerName,
    );
    if (changed == true) {
      // Compat. historique : garde HtmlPoiExtractor synchronisé pour
      // OpenRouter, utilisé ailleurs dans l'app (analyse de blog, etc.).
      if (providerId == 'openrouter') {
        final key = await _keyStore.loadKey('openrouter');
        HtmlPoiExtractor.setApiKey(key);
      }
      await _loadProviderStatus();
    }
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
    if (_loadingProviders) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'Providers IA',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Touchez un provider pour saisir, tester et enregistrer sa clé API.'),
        const SizedBox(height: 12),
        _providerCard(
          id: 'openrouter',
          name: 'OpenRouter',
          description: 'Modèles gratuits dynamiques + openrouter/free',
        ),
        ...ProviderCatalog.definitions
            .where((def) => def.id != 'openrouter')
            .map((def) => _providerCard(
                  id: def.id,
                  name: def.name,
                  description: def.description,
                )),
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

  Widget _providerCard({
    required String id,
    required String name,
    required String description,
  }) {
    final configured = _providerConfigured[id] ?? false;
    return Card(
      child: ListTile(
        leading: Icon(configured ? Icons.check_circle : Icons.radio_button_unchecked),
        title: Text(name),
        subtitle: Text(description),
        trailing: Text(configured ? 'Configuré' : 'À configurer'),
        onTap: () => _openProviderKeyDialog(id, name),
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
