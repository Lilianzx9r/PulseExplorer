import 'package:flutter/material.dart';

import '../agents/provider_key_store.dart';
import '../agents/provider_test_service.dart';

/// Dialogue générique de configuration d'un provider IA (clé API et/ou URL
/// de base pour les providers locaux comme Ollama / LM Studio).
///
/// Important : la validation/test n'est déclenchée que par une action
/// explicite de l'utilisateur (bouton "Tester la connexion"), jamais à
/// chaque frappe clavier, afin d'éviter d'afficher une erreur alors que la
/// clé est encore en cours de saisie.
class ProviderKeyDialog extends StatefulWidget {
  final String providerId;
  final String providerName;

  const ProviderKeyDialog({
    super.key,
    required this.providerId,
    required this.providerName,
  });

  /// Ouvre le dialogue et renvoie `true` si une modification a été
  /// enregistrée (clé et/ou URL).
  static Future<bool?> show(
    BuildContext context, {
    required String providerId,
    required String providerName,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => ProviderKeyDialog(
        providerId: providerId,
        providerName: providerName,
      ),
    );
  }

  @override
  State<ProviderKeyDialog> createState() => _ProviderKeyDialogState();
}

class _ProviderKeyDialogState extends State<ProviderKeyDialog> {
  final _store = ProviderKeyStore();
  final _testService = const ProviderTestService();
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  late final TextEditingController _modelController;

  bool get _isLocal => kLocalProviders.contains(widget.providerId);

  bool _obscure = true;
  bool _loading = true;
  bool _testing = false;
  bool _saving = false;
  ProviderTestResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(
      text: kDefaultTestModel[widget.providerId] ?? '',
    );
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final key = await _store.loadKey(widget.providerId);
    final baseUrl = await _store.loadBaseUrl(widget.providerId) ??
        kDefaultBaseUrl[widget.providerId] ??
        '';
    if (!mounted) return;
    setState(() {
      _keyController.text = key;
      _baseUrlController.text = baseUrl;
      _loading = false;
    });
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _lastResult = null;
    });
    final result = await _testService.test(
      providerId: widget.providerId,
      apiKey: _keyController.text,
      model: _modelController.text,
      baseUrl: _isLocal ? _baseUrlController.text : null,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _lastResult = result;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _store.saveKey(widget.providerId, _keyController.text);
    if (_isLocal) {
      await _store.saveBaseUrl(widget.providerId, _baseUrlController.text);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _removeKey() async {
    setState(() => _saving = true);
    await _store.clearKey(widget.providerId);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${_isLocal ? 'Provider local' : 'Clé API'} — ${widget.providerName}'),
      content: _loading
          ? const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isLocal) ...[
                    TextField(
                      controller: _baseUrlController,
                      decoration: const InputDecoration(
                        labelText: 'URL du serveur local',
                        helperText: 'Ex : http://localhost:11434/v1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _keyController,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: _isLocal ? 'Clé API (optionnelle)' : 'Clé API',
                      helperText: 'Collez votre clé, puis testez avant d\'enregistrer.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _modelController,
                    decoration: const InputDecoration(
                      labelText: 'Modèle utilisé pour le test',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: Text(_testing ? 'Test en cours…' : 'Tester la connexion'),
                    ),
                  ),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _lastResult!.success ? Icons.check_circle : Icons.error,
                          color: _lastResult!.success
                              ? Colors.green
                              : Theme.of(context).colorScheme.error,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_lastResult!.message)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
      actions: [
        if (!_loading && _keyController.text.trim().isNotEmpty)
          TextButton(
            onPressed: _saving ? null : _removeKey,
            child: const Text('Supprimer la clé'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: (_loading || _saving) ? null : _save,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
