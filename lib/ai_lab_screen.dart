import 'package:flutter/material.dart';

import 'agents/agents.dart';
import 'agents/model_catalog_service.dart';

class AiLabScreen extends StatefulWidget {
  const AiLabScreen({super.key});

  @override
  State<AiLabScreen> createState() => _AiLabScreenState();
}

class _AiLabScreenState extends State<AiLabScreen> {
  final _store = AgentConfigurationStore();
  List<AgentDefinition> _agents = [];
  List<SourceDefinition> _sources = SourceCatalog.defaults;
  final _modelCatalog = ModelCatalogService();
  final Map<String, List<AiModelInfo>> _modelsByProvider = {};
  final Map<String, bool> _loadingModelsByProvider = {};
  final Map<String, String?> _modelErrorsByProvider = {};
  final Map<String, String> _providerKeys = {};

  @override
  void initState() {
    super.initState();
    _loadAgents();
    _loadProviderKeys();
  }

  Future<void> _loadAgents() async {
    final saved = await _store.loadAgents();
    if (!mounted) return;
    setState(() => _agents = saved.isEmpty ? _defaultAgents() : saved);
  }


  Future<void> _loadProviderKeys() async {
    for (final provider in ProviderCatalog.definitions) {
      _providerKeys[provider.id] = await ProviderCredentials.load(provider.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _editProviderKey(String providerId, String providerName) async {
    final controller = TextEditingController(text: _providerKeys[providerId] ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clé API — $providerName'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Clé API',
            hintText: 'Laisser vide pour désactiver',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Enregistrer')),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await ProviderCredentials.save(providerId, value);
    if (!mounted) return;
    setState(() => _providerKeys[providerId] = value.trim());
  }

  Future<void> _editAgent(int index) async {
    final current = _agents[index];
    var providerId = current.providerId;
    var selectedModel = current.model;
    var models = _modelsByProvider[providerId] ?? const <AiModelInfo>[];

    Future<List<AiModelInfo>> loadModels(String id) async {
      final key = (_providerKeys[id] ?? '').trim();
      if (key.isEmpty) {
        throw Exception("Configurez d'abord la clé API de ce provider.");
      }
      final loaded = await _modelCatalog.fetchModels(providerId: id, apiKey: key);
      if (mounted) setState(() => _modelsByProvider[id] = loaded);
      return loaded;
    }

    if (models.isEmpty && (_providerKeys[providerId] ?? '').trim().isNotEmpty) {
      try {
        models = await loadModels(providerId);
      } catch (_) {
        // Le dialogue reste utilisable avec le modèle déjà configuré.
      }
    }

    if (!mounted) return;
    final result = await showDialog<AgentDefinition>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Configurer ${current.name}'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: providerId,
                  decoration: const InputDecoration(labelText: 'Provider'),
                  items: ProviderCatalog.definitions
                      .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged: (value) async {
                    if (value == null) return;
                    setDialogState(() {
                      providerId = value;
                      models = _modelsByProvider[value] ?? const <AiModelInfo>[];
                    });
                    if (models.isEmpty && (_providerKeys[value] ?? '').trim().isNotEmpty) {
                      try {
                        final loaded = await loadModels(value);
                        if (loaded.isNotEmpty) {
                          setDialogState(() {
                            models = loaded;
                            if (!loaded.any((m) => m.id == selectedModel)) {
                              selectedModel = loaded.first.id;
                            }
                          });
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      }
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (models.isNotEmpty)
                  DropdownButtonFormField<String>(
                    value: models.any((m) => m.id == selectedModel) ? selectedModel : null,
                    decoration: const InputDecoration(labelText: 'Modèle disponible'),
                    items: models
                        .map((m) => DropdownMenuItem(
                              value: m.id,
                              child: Text(m.name, overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => selectedModel = value);
                    },
                  )
                else
                  TextFormField(
                    initialValue: selectedModel,
                    decoration: const InputDecoration(
                      labelText: 'Modèle',
                      helperText: 'Configurez une clé API puis rechargez les modèles.',
                    ),
                    onChanged: (value) => selectedModel = value.trim(),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(
              onPressed: selectedModel.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                        context,
                        current.copyWith(providerId: providerId, model: selectedModel.trim()),
                      ),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    setState(() => _agents[index] = result);
    await _saveAgents();
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

  Future<void> _refreshModels(String providerId) async {
    final key = (_providerKeys[providerId] ?? '').trim();
    if (key.isEmpty) {
      setState(() => _modelErrorsByProvider[providerId] = 'Aucune clé API configurée.');
      return;
    }
    setState(() {
      _loadingModelsByProvider[providerId] = true;
      _modelErrorsByProvider[providerId] = null;
    });
    try {
      final models = await _modelCatalog.fetchModels(providerId: providerId, apiKey: key);
      if (!mounted) return;
      setState(() => _modelsByProvider[providerId] = models);
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelErrorsByProvider[providerId] = '$e');
    } finally {
      if (mounted) setState(() => _loadingModelsByProvider[providerId] = false);
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
  void dispose() {
    _modelCatalog.dispose();
    super.dispose();
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
            child: ListTile(
              leading: Switch(
                value: a.enabled,
                onChanged: (v) => _toggleAgent(i, v),
              ),
              title: Text(a.name),
              subtitle: Text('${a.description}\n${a.providerId} / ${a.model}'),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Configurer',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _editAgent(i),
              ),
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
        _providerCard('openrouter', 'OpenRouter', 'Modèles explicitement gratuits uniquement'),
        _providerCard('gemini', 'Google Gemini', 'Modèles accessibles avec votre Free Tier'),
        _providerCard('mistral', 'Mistral AI', 'Modèles disponibles pour votre compte'),
        _providerCard('groq', 'Groq', 'Modèles disponibles pour votre compte et ses quotas'),
        const SizedBox(height: 12),
        const Text(
          "Les modèles sont récupérés directement auprès de chaque provider. Aucun modèle payant OpenRouter n'est affiché.",
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 12),
        ...ProviderCatalog.definitions.map((provider) {
          final models = _modelsByProvider[provider.id] ?? const <AiModelInfo>[];
          final loading = _loadingModelsByProvider[provider.id] ?? false;
          final error = _modelErrorsByProvider[provider.id];
          return Card(
            child: ExpansionTile(
              title: Text(provider.name),
              subtitle: Text(models.isEmpty ? 'Aucun modèle chargé' : '${models.length} modèles disponibles'),
              trailing: IconButton(
                tooltip: 'Actualiser',
                onPressed: loading ? null : () => _refreshModels(provider.id),
                icon: loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                ...models.take(100).map((m) => ListTile(
                      dense: true,
                      leading: Icon(m.isFree ? Icons.check_circle_outline : Icons.info_outline),
                      title: Text(m.name),
                      subtitle: Text(m.id),
                      trailing: Text(m.costMode.label),
                    )),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _providerCard(String providerId, String name, String description) {
    final configured = (_providerKeys[providerId] ?? '').isNotEmpty;
    return Card(
      child: ListTile(
        leading: Icon(configured ? Icons.check_circle : Icons.radio_button_unchecked),
        title: Text(name),
        subtitle: Text(description),
        trailing: TextButton.icon(
          icon: const Icon(Icons.key_outlined),
          label: Text(configured ? 'Modifier' : 'Configurer'),
          onPressed: () => _editProviderKey(providerId, name),
        ),
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
