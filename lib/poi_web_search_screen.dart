import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_dirs.dart';
import 'package:webview_flutter/webview_flutter.dart';

class PoiWebSearchScreen extends StatefulWidget {
  final String poiName;
  final double lat;
  final double lon;

  const PoiWebSearchScreen({
    super.key,
    required this.poiName,
    required this.lat,
    required this.lon,
  });

  @override
  State<PoiWebSearchScreen> createState() => _PoiWebSearchScreenState();
}

class _PoiWebSearchScreenState extends State<PoiWebSearchScreen>
    with SingleTickerProviderStateMixin {

  late TabController _tabs;
  WebViewController? _webCtrl;
  bool _webLoading = true;

  // Wikimedia Commons
  List<_WikimediaPhoto> _wmPhotos = [];
  bool   _wmLoading  = false;
  String? _wmError;
  int    _wmPage     = 0;

  // Wikipedia
  List<_WikiResult>  _wikiResults = [];
  bool               _wikiLoading = false;
  String?            _wikiError;
  _WikiResult?       _selectedArticle;

  // Photos sélectionnées (chemins locaux téléchargés)
  final List<String> _selectedLocalPaths = [];
  final List<String> _selectedUrls       = [];
  String? _pendingDescription;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);

    // WebView uniquement sur Android/iOS
    if (Platform.isAndroid || Platform.isIOS) {
      _webCtrl = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onPageStarted: (_) => setState(() => _webLoading = true),
          onPageFinished: (_) async {
            setState(() => _webLoading = false);
            // Injecter JS pour intercepter les appuis longs sur les images
            await _injectImageLongPress();
          },
        ))
        ..addJavaScriptChannel('ImageCapture',
            onMessageReceived: (msg) => _onImageCaptured(msg.message))
        ..loadRequest(Uri.parse(_ddgUrl(widget.poiName)));
    }

    _searchWikimedia();
    _searchWikipedia();
  }

  @override
  void dispose() { _tabs.dispose(); super.dispose(); }

  String _ddgUrl(String q) =>
      'https://duckduckgo.com/?q=${Uri.encodeComponent(q)}&iax=images&ia=images';
  String _webUrl(String q) =>
      'https://www.google.com/search?q=${Uri.encodeComponent(q)}&hl=fr';

  Widget _browserButton(String label, String url) => SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      icon: const Icon(Icons.open_in_new, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      onPressed: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    ),
  );

  // ── JS injection : appui long sur image → capture URL ────────────────────
  Future<void> _injectImageLongPress() async {
    await _webCtrl?.runJavaScript(r"""
      (function() {
        if (window.__imgLongPressInjected) return;
        window.__imgLongPressInjected = true;
        let timer = null;
        document.addEventListener('touchstart', function(e) {
          const img = e.target.closest('img');
          if (!img) return;
          timer = setTimeout(function() {
            const src = img.src || img.dataset.src || img.getAttribute('data-original') || '';
            if (src && src.startsWith('http')) {
              ImageCapture.postMessage(src);
            }
          }, 600);
        }, true);
        document.addEventListener('touchend',   function() { clearTimeout(timer); }, true);
        document.addEventListener('touchmove',  function() { clearTimeout(timer); }, true);
      })();
    """);
  }

  // URL capturée par appui long → télécharger l'image
  Future<void> _onImageCaptured(String url) async {
    if (url.isEmpty) return;
    _showDownloadDialog(url);
  }

  // ── Wikimedia Commons ─────────────────────────────────────────────────────
  Future<void> _searchWikimedia({bool nextPage = false}) async {
    if (!nextPage) setState(() { _wmLoading = true; _wmError = null; _wmPhotos = []; _wmPage = 0; });
    try {
      final offset = nextPage ? _wmPage * 20 : 0;
      final resp = await http.get(Uri.parse(
        'https://commons.wikimedia.org/w/api.php'
        '?action=query&format=json'
        '&generator=search&gsrsearch=${Uri.encodeComponent(widget.poiName)}'
        '&gsrnamespace=6&gsrlimit=20&gsroffset=$offset'
        '&prop=imageinfo'
        '&iiprop=url|extmetadata'
        '&iiurlwidth=400'
      ), headers: {
        'User-Agent': 'PulseGpx/1.0 (educational)',
      }).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data  = json.decode(resp.body) as Map;
        final pages = (data['query']?['pages'] as Map?)?.values.toList() ?? [];
        final photos = pages.map((p) {
          final m   = p as Map;
          final ii  = (m['imageinfo'] as List?)?.firstOrNull as Map?;
          final ext = ii?['extmetadata'] as Map?;
          final desc = (ext?['ImageDescription']?['value'] as String? ?? '')
              .replaceAll(RegExp(r'<[^>]+>'), '').trim();
          return _WikimediaPhoto(
            title:       (m['title'] as String? ?? '').replaceFirst('File:', ''),
            url:         ii?['url'] as String? ?? '',
            thumbUrl:    ii?['thumburl'] as String? ?? ii?['url'] as String? ?? '',
            description: desc,
          );
        }).where((p) => p.thumbUrl.isNotEmpty).toList();

        setState(() {
          if (nextPage) _wmPhotos.addAll(photos);
          else _wmPhotos = photos;
          _wmPage++;
        });
      } else {
        setState(() => _wmError = 'Wikimedia HTTP ${resp.statusCode}');
      }
    } catch (e) {
      setState(() => _wmError = e.toString());
    } finally {
      setState(() => _wmLoading = false);
    }
  }

  // ── Wikipedia ─────────────────────────────────────────────────────────────
  Future<void> _searchWikipedia() async {
    setState(() { _wikiLoading = true; _wikiError = null; });
    try {
      var r = await _wikiQuery(widget.poiName, 'fr');
      if (r.isEmpty) r = await _wikiQuery(widget.poiName, 'en');
      setState(() => _wikiResults = r);
    } catch (e) {
      setState(() => _wikiError = e.toString());
    } finally {
      setState(() => _wikiLoading = false);
    }
  }

  Future<List<_WikiResult>> _wikiQuery(String q, String lang) async {
    final resp = await http.get(
      Uri.parse('https://$lang.wikipedia.org/api/rest_v1/page/search/title'
          '?q=${Uri.encodeComponent(q)}&limit=8'),
      headers: {'User-Agent': 'PulseGpx/1.0'},
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return [];
    final pages = (json.decode(resp.body)['pages'] as List? ?? []);
    return pages.map((p) => _WikiResult(
      title: p['title'] ?? '', description: p['description'] ?? '',
      key: p['key'] ?? '', lang: lang,
      thumbnail: p['thumbnail']?['url'] as String?,
    )).toList();
  }

  Future<void> _loadArticle(_WikiResult r) async {
    setState(() { _wikiLoading = true; _selectedArticle = null; });
    try {
      final resp = await http.get(
        Uri.parse('https://${r.lang}.wikipedia.org/api/rest_v1/page/summary/'
            '${Uri.encodeComponent(r.key)}'),
        headers: {'User-Agent': 'PulseGpx/1.0'},
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final d = json.decode(resp.body) as Map;
        setState(() => _selectedArticle = _WikiResult(
          title: d['title'] ?? r.title,
          description: d['extract'] ?? r.description,
          key: r.key, lang: r.lang,
          thumbnail: d['thumbnail']?['source'] as String? ?? r.thumbnail,
          pageUrl: d['content_urls']?['mobile']?['page'] as String?,
        ));
      }
    } catch (_) {
      setState(() => _selectedArticle = r);
    } finally {
      setState(() => _wikiLoading = false);
    }
  }

  // ── Télécharger une image ─────────────────────────────────────────────────
  void _showDownloadDialog(String url) {
    showModalBottomSheet(context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        // Aperçu
        Container(
          height: 150,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade200),
          clipBehavior: Clip.antiAlias,
          child: Image.network(url, fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image, size: 48, color: Colors.grey)),
        ),
        const SizedBox(height: 8),
        Text(url.length > 60 ? '...${url.substring(url.length - 60)}' : url,
            style: const TextStyle(fontSize: 10, color: Colors.grey),
            textAlign: TextAlign.center),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.download, color: Colors.blue),
          title: const Text('Télécharger et ajouter au POI'),
          onTap: () async {
            Navigator.pop(context);
            await _downloadImage(url);
          },
        ),
        ListTile(
          leading: const Icon(Icons.link, color: Colors.teal),
          title: const Text('Ajouter comme lien (URL)'),
          onTap: () {
            Navigator.pop(context);
            setState(() {
              if (!_selectedUrls.contains(url)) _selectedUrls.add(url);
            });
            _showSnack('URL ajoutée', Colors.teal);
          },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }

  Future<void> _downloadImage(String url) async {
    _showSnack('Téléchargement...', Colors.blue);
    try {
      final resp = await http.get(Uri.parse(url),
          headers: {'User-Agent': 'PulseGpx/1.0'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');

      final dirPath  = await AppDirs.importDir();
      final fileName = 'poi_photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file     = File('$dirPath/$fileName');
      await file.writeAsBytes(resp.bodyBytes);

      setState(() => _selectedLocalPaths.add(file.path));
      _showSnack('Photo ajoutée !', Colors.green);
    } catch (e) {
      _showSnack('Erreur : $e', Colors.red);
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), backgroundColor: color,
      duration: const Duration(seconds: 2)));
  }

  void _apply() => Navigator.pop(context, {
    'localPhotos': _selectedLocalPaths,
    'photoUrls':   _selectedUrls,
    'description': _pendingDescription,
  });

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final hasSelection = _selectedLocalPaths.isNotEmpty ||
        _selectedUrls.isNotEmpty || _pendingDescription != null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: Text(widget.poiName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            overflow: TextOverflow.ellipsis),
        actions: [
          if (hasSelection)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: _apply,
              child: Text(
                'Appliquer'
                '${_selectedLocalPaths.isNotEmpty ? " (${_selectedLocalPaths.length}📷)" : ""}'
                '${_selectedUrls.isNotEmpty ? " +${_selectedUrls.length}🔗" : ""}',
                style: const TextStyle(fontSize: 11)),
            ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.image, size: 16),      text: 'DuckDuckGo'),
            Tab(icon: Icon(Icons.photo_library, size: 16), text: 'Wikimedia'),
            Tab(icon: Icon(Icons.search, size: 16),     text: 'Web'),
            Tab(icon: Icon(Icons.menu_book, size: 16),  text: 'Wikipedia'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _buildDdgTab(),
          _buildWikimediaTab(),
          _buildWebTab(),
          _buildWikiTab(),
        ],
      ),
    );
  }

  // ── Onglet DuckDuckGo Images ──────────────────────────────────────────────
  Widget _buildDdgTab() {
    return Column(children: [
      Container(
        color: Colors.orange.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          const Icon(Icons.touch_app, size: 14, color: Colors.orange),
          const SizedBox(width: 6),
          const Expanded(child: Text(
            'Appui long sur une image → télécharger ou copier l\'URL',
            style: TextStyle(fontSize: 11, color: Colors.orange))),
          TextButton(onPressed: _changeQuery,
              child: const Text('Modifier', style: TextStyle(fontSize: 11))),
        ]),
      ),
      Expanded(child: Stack(children: [
        if (_webCtrl != null)
          WebViewWidget(controller: _webCtrl!)
        else
          _DesktopSearchPanel(poiName: widget.poiName, onImageUrl: (url) {
            setState(() {
              if (!_selectedUrls.contains(url)) _selectedUrls.add(url);
            });
            _showSnack('URL ajoutée', Colors.teal);
          }),
        if (_webLoading && _webCtrl != null)
          const LinearProgressIndicator(minHeight: 3),
      ])),
    ]);
  }

  // ── Onglet Wikimedia Commons ──────────────────────────────────────────────
  Widget _buildWikimediaTab() {
    if (_wmLoading && _wmPhotos.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 12),
        Text('Recherche Wikimedia Commons...', style: TextStyle(color: Colors.grey)),
      ]));
    }
    if (_wmError != null && _wmPhotos.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: Colors.orange, size: 40),
        const SizedBox(height: 8),
        Text(_wmError!, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.refresh),
            label: const Text('Réessayer'), onPressed: _searchWikimedia),
      ]));
    }
    if (_wmPhotos.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.image_not_supported, size: 40, color: Colors.grey),
        const SizedBox(height: 8),
        const Text('Aucune photo trouvée', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.refresh),
            label: const Text('Réessayer'), onPressed: _searchWikimedia),
      ]));
    }

    return Column(children: [
      // Compteur sélection
      if (_selectedLocalPaths.isNotEmpty)
        Container(color: Colors.green.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 14),
            const SizedBox(width: 6),
            Text('${_selectedLocalPaths.length} photo(s) téléchargée(s)',
                style: const TextStyle(fontSize: 11, color: Colors.green)),
          ])),
      Expanded(child: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, crossAxisSpacing: 3, mainAxisSpacing: 3),
        itemCount: _wmPhotos.length + 1, // +1 pour "Charger plus"
        itemBuilder: (_, i) {
          if (i == _wmPhotos.length) {
            return Center(child: _wmLoading
                ? const CircularProgressIndicator()
                : TextButton(
                    onPressed: () => _searchWikimedia(nextPage: true),
                    child: const Text('+ Charger\nplus',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11))));
          }
          final p = _wmPhotos[i];
          final selected = _selectedLocalPaths.any((path) => path.contains(
              p.title.replaceAll(' ', '_').substring(0,
                  p.title.length.clamp(0, 20))));
          return GestureDetector(
            onTap: () => _showWikimediaPhoto(p),
            child: Stack(fit: StackFit.expand, children: [
              Image.network(p.thumbUrl, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.image, color: Colors.grey))),
              if (selected)
                Container(color: Colors.green.withOpacity(0.4),
                    child: const Icon(Icons.check, color: Colors.white, size: 32)),
            ]),
          );
        },
      )),
    ]);
  }

  void _showWikimediaPhoto(_WikimediaPhoto p) {
    showModalBottomSheet(context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6, maxChildSize: 0.9, minChildSize: 0.4,
        expand: false,
        builder: (_, ctrl) => Column(children: [
          Container(height: 4, width: 40, margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2))),
          Expanded(child: ListView(controller: ctrl, padding: const EdgeInsets.all(12),
            children: [
              // Photo pleine
              ClipRRect(borderRadius: BorderRadius.circular(8),
                child: Image.network(p.url.isNotEmpty ? p.url : p.thumbUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      Image.network(p.thumbUrl, fit: BoxFit.contain))),
              const SizedBox(height: 10),
              Text(p.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              if (p.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(p.description, style: const TextStyle(fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: FilledButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Télécharger'),
                  onPressed: () async {
                    Navigator.pop(context);
                    await _downloadImage(p.url.isNotEmpty ? p.url : p.thumbUrl);
                  },
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Copier URL'),
                  onPressed: () {
                    Navigator.pop(context);
                    final url = p.url.isNotEmpty ? p.url : p.thumbUrl;
                    setState(() { if (!_selectedUrls.contains(url)) _selectedUrls.add(url); });
                    _showSnack('URL ajoutée', Colors.teal);
                  },
                )),
              ]),
            ],
          )),
        ]),
      ),
    );
  }

  // ── Onglet Web général ────────────────────────────────────────────────────
  Widget _buildWebTab() {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.open_in_browser, size: 48, color: Colors.blue.shade300),
          const SizedBox(height: 12),
          const Text('Ouvrir dans le navigateur :',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 12),
          _browserButton('🌐  Recherche Google',
              'https://www.google.com/search?q=${Uri.encodeComponent(widget.poiName)}&hl=fr'),
          const SizedBox(height: 8),
          _browserButton('🗺️  OpenStreetMap',
              'https://www.openstreetmap.org/search?query=${Uri.encodeComponent(widget.poiName)}'),
        ]),
      ));
    }
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(_webUrl(widget.poiName)));
    return WebViewWidget(controller: ctrl);
  }

  // ── Onglet Wikipedia ──────────────────────────────────────────────────────
  Widget _buildWikiTab() {
    if (_wikiLoading) return const Center(child: CircularProgressIndicator());
    if (_selectedArticle != null) return _buildArticle(_selectedArticle!);
    if (_wikiResults.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.search_off, size: 40, color: Colors.grey),
        const SizedBox(height: 8),
        Text(_wikiError ?? 'Aucun article trouvé',
            style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.refresh),
            label: const Text('Réessayer'), onPressed: _searchWikipedia),
      ]));
    }
    return ListView.separated(
      itemCount: _wikiResults.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = _wikiResults[i];
        return ListTile(
          leading: r.thumbnail != null
              ? ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: Image.network(r.thumbnail!, width: 48, height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.article, size: 36)))
              : const Icon(Icons.article, size: 36, color: Colors.grey),
          title: Text(r.title,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          subtitle: r.description.isNotEmpty
              ? Text(r.description, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11))
              : null,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _loadArticle(r),
        );
      },
    );
  }

  Widget _buildArticle(_WikiResult a) {
    return Column(children: [
      Container(color: Colors.grey.shade100,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: () => setState(() => _selectedArticle = null),
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          const SizedBox(width: 4),
          Expanded(child: Text(a.title,
              style: const TextStyle(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis)),
          TextButton.icon(
            icon: const Icon(Icons.notes, size: 14),
            label: const Text('Description', style: TextStyle(fontSize: 11)),
            onPressed: () {
              final s = a.description.split('. ');
              setState(() => _pendingDescription =
                  s.take(3).join('. ') + (s.length > 3 ? '.' : ''));
              _showSnack('Description prête → Appliquer', Colors.blue);
            },
          ),
        ]),
      ),
      Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [
        if (a.thumbnail != null) ...[
          Center(child: ClipRRect(borderRadius: BorderRadius.circular(8),
              child: Image.network(a.thumbnail!, fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: FilledButton.icon(
              icon: const Icon(Icons.download, size: 14),
              label: const Text('Télécharger', style: TextStyle(fontSize: 12)),
              onPressed: () => _downloadImage(a.thumbnail!),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.link, size: 14),
              label: const Text('URL', style: TextStyle(fontSize: 12)),
              onPressed: () {
                setState(() { if (!_selectedUrls.contains(a.thumbnail)) _selectedUrls.add(a.thumbnail!); });
                _showSnack('URL ajoutée', Colors.teal);
              },
            )),
          ]),
          const SizedBox(height: 12),
        ],
        Text(a.description, style: const TextStyle(fontSize: 14, height: 1.5)),
      ])),
    ]);
  }

  Future<void> _changeQuery() async {
    final ctrl = TextEditingController(text: widget.poiName);
    final q = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Recherche images'),
        content: TextField(controller: ctrl, autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    if (q != null && q.isNotEmpty) {
      _webCtrl?.loadRequest(Uri.parse(_ddgUrl(q)));
    }
  }
}

class _WikimediaPhoto {
  final String title, url, thumbUrl, description;
  _WikimediaPhoto({required this.title, required this.url,
      required this.thumbUrl, required this.description});
}

class _WikiResult {
  final String title, description, key, lang;
  final String? thumbnail, pageUrl;
  _WikiResult({required this.title, required this.description,
      required this.key, required this.lang, this.thumbnail, this.pageUrl});
}

// ═════════════════════════════════════════════════════════════════════════════
// _DesktopSearchPanel — recherche images/web intégrée sur desktop (sans WebView)
// Utilise l'API Wikimedia Commons + DuckDuckGo Instant Answer
// ═════════════════════════════════════════════════════════════════════════════
class _DesktopSearchPanel extends StatefulWidget {
  final String         poiName;
  final void Function(String url) onImageUrl;
  const _DesktopSearchPanel({required this.poiName, required this.onImageUrl});
  @override State<_DesktopSearchPanel> createState() => _DesktopSearchPanelState();
}

class _DesktopSearchPanelState extends State<_DesktopSearchPanel>
    with SingleTickerProviderStateMixin {

  late final TabController _tabs;
  late final TextEditingController _queryCtrl;
  bool _loading = false;
  List<_WikimediaPhoto> _images = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabs     = TabController(length: 2, vsync: this);
    _queryCtrl = TextEditingController(text: widget.poiName);
    _search();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() { _loading = true; _error = null; });
    try {
      final q = _queryCtrl.text.trim();
      if (q.isEmpty) return;
      final results = await _WikimediaSearcher.search(q, limit: 24);
      setState(() { _images = results; });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _loading = false; });
    }
  }

  /// Bouton compact pour ouvrir une recherche dans le navigateur externe
  Widget _webLinkBtn(String label, String url) => InkWell(
    onTap: () async {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    },
    borderRadius: BorderRadius.circular(4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Barre de recherche
      Container(
        color: Colors.blue.shade50,
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(child: TextField(
            controller: _queryCtrl,
            decoration: InputDecoration(
              hintText: 'Rechercher des images…',
              isDense: true,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _loading
                  ? const Padding(padding: EdgeInsets.all(10),
                      child: SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : null,
            ),
            onSubmitted: (_) => _search(),
          )),
          const SizedBox(width: 8),
          FilledButton(onPressed: _loading ? null : _search,
              child: const Text('OK')),
          const SizedBox(width: 8),
          // Liens navigateur externe
          PopupMenuButton<String>(
            icon: const Icon(Icons.open_in_new, size: 18),
            tooltip: 'Ouvrir dans le navigateur',
            onSelected: (url) async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            itemBuilder: (_) {
              final q = Uri.encodeComponent(_queryCtrl.text.trim());
              return [
                PopupMenuItem(value: 'https://commons.wikimedia.org/w/index.php?search=$q',
                    child: const Text('🖼️ Wikimedia Commons')),
                PopupMenuItem(value: 'https://www.google.com/search?q=$q&tbm=isch',
                    child: const Text('🔍 Google Images')),
                PopupMenuItem(value: 'https://duckduckgo.com/?q=$q&iax=images&ia=images',
                    child: const Text('🦆 DuckDuckGo Images')),
                PopupMenuItem(value: 'https://fr.wikipedia.org/wiki/Special:Search?search=$q',
                    child: const Text('📚 Wikipedia')),
              ];
            },
          ),
        ]),
      ),

      if (_error != null)
        Padding(padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12))),

      // Accès direct à la page web de recherche d'images (comme avant)
      Container(
        color: Colors.orange.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          const Icon(Icons.open_in_browser, size: 14, color: Colors.orange),
          const SizedBox(width: 6),
          const Expanded(child: Text(
            'Ouvrir la recherche complète dans le navigateur :',
            style: TextStyle(fontSize: 11, color: Colors.deepOrange))),
          _webLinkBtn('🦆 DuckDuckGo',
              'https://duckduckgo.com/?q=${Uri.encodeComponent(_queryCtrl.text.trim())}&iax=images&ia=images'),
          const SizedBox(width: 4),
          _webLinkBtn('🔍 Google',
              'https://www.google.com/search?q=${Uri.encodeComponent(_queryCtrl.text.trim())}&tbm=isch'),
        ]),
      ),

      // Grille d'images
      Expanded(child: _images.isEmpty && !_loading
          ? const Center(child: Text('Aucune image trouvée',
              style: TextStyle(color: Colors.grey)))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6,
                childAspectRatio: 1.2,
              ),
              itemCount: _images.length,
              itemBuilder: (ctx, i) {
                final img = _images[i];
                return GestureDetector(
                  onTap: () => widget.onImageUrl(img.url.isNotEmpty ? img.url : img.thumbUrl),
                  child: Stack(fit: StackFit.expand, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        img.thumbUrl, fit: BoxFit.cover,
                        errorBuilder: (_,__,___) => const Icon(Icons.broken_image),
                      ),
                    ),
                    Positioned(bottom: 0, left: 0, right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
                        ),
                        child: Text(img.title.replaceAll(RegExp(r'\.(jpg|jpeg|png|svg|webp)$',
                            caseSensitive: false), ''),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 9)),
                      )),
                    Positioned(top: 4, right: 4,
                      child: GestureDetector(
                        onTap: () {
                          final url = img.url.isNotEmpty ? img.url : img.thumbUrl;
                          widget.onImageUrl(url);
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('URL ajoutée'),
                                duration: Duration(seconds: 1)));
                        },
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                              color: Colors.teal, shape: BoxShape.circle),
                          child: const Icon(Icons.add, size: 12, color: Colors.white),
                        ),
                      )),
                  ]),
                );
              },
            )),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _WikimediaSearcher — helper statique pour _DesktopSearchPanel
// ─────────────────────────────────────────────────────────────────────────────
class _WikimediaSearcher {
  /// Utilise l'API Action de Wikimedia Commons (stable, contrairement à
  /// api.wikimedia.org/core/v1/commons/search/files qui retourne 404).
  static Future<List<_WikimediaPhoto>> search(String query, {int limit = 20}) async {
    final resp = await http.get(Uri.parse(
      'https://commons.wikimedia.org/w/api.php'
      '?action=query&format=json'
      '&generator=search&gsrsearch=${Uri.encodeComponent(query)}'
      '&gsrnamespace=6&gsrlimit=$limit'
      '&prop=imageinfo'
      '&iiprop=url|extmetadata'
      '&iiurlwidth=400'
    ), headers: {
      'User-Agent': 'PulseGpx/1.0 (educational)',
    }).timeout(const Duration(seconds: 12));

    if (resp.statusCode != 200) {
      throw Exception('Wikimedia HTTP ${resp.statusCode}');
    }
    final data  = json.decode(resp.body) as Map;
    final pages = (data['query']?['pages'] as Map?)?.values.toList() ?? [];

    return pages.map((p) {
      final m   = p as Map;
      final ii  = (m['imageinfo'] as List?)?.firstOrNull as Map?;
      final ext = ii?['extmetadata'] as Map?;
      final title = (m['title'] as String? ?? '').replaceFirst('File:', '');
      final desc  = (ext?['ImageDescription']?['value'] as String? ?? '')
          .replaceAll(RegExp(r'<[^>]+>'), '').trim();
      return _WikimediaPhoto(
        title:       title,
        url:         ii?['url'] as String? ?? '',
        thumbUrl:    ii?['thumburl'] as String? ?? ii?['url'] as String? ?? '',
        description: desc,
      );
    }).where((p) => p.thumbUrl.isNotEmpty).toList();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
