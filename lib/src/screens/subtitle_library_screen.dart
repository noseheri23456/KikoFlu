import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/subtitle_library_service.dart';
import '../services/subtitle_database.dart';
import '../widgets/text_preview_screen.dart';
import '../providers/audio_provider.dart';
import '../providers/lyric_provider.dart';
import '../utils/file_icon_utils.dart';
import '../utils/snackbar_util.dart';
import '../../l10n/app_localizations.dart';

/// Maps disk folder names to localized display names.
String _localizedFolderTitle(BuildContext context, String diskName) {
  final s = S.of(context);
  switch (diskName) {
    case SubtitleLibraryService.parsedFolderName:
      return s.subtitleFolderParsed;
    case SubtitleLibraryService.savedFolderName:
      return s.subtitleFolderSaved;
    case SubtitleLibraryService.unknownFolderName:
      return s.subtitleFolderUnknown;
    default:
      return diskName;
  }
}

/// 字幕库界面
class SubtitleLibraryScreen extends ConsumerStatefulWidget {
  const SubtitleLibraryScreen({super.key});

  @override
  ConsumerState<SubtitleLibraryScreen> createState() =>
      _SubtitleLibraryScreenState();
}

class _SubtitleLibraryScreenState extends ConsumerState<SubtitleLibraryScreen> {
  List<Map<String, dynamic>> _files = [];
  bool _isLoading = true;
  String? _errorMessage;
  LibraryStats? _stats;
  final bool _isSelectionMode = false;
  final Set<String> _selectedPaths = {}; 

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  String _currentPath = ''; 
  final List<String> _navigationStack = []; 

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _navigateTo(String relativePath) {
    setState(() {
      _navigationStack.add(_currentPath);
      _currentPath = relativePath;
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
      _selectedPaths.clear();
    });
    _loadFiles();
  }

  void _navigateUp() {
    if (_navigationStack.isNotEmpty) {
      setState(() {
        _currentPath = _navigationStack.removeLast();
        _selectedPaths.clear();
      });
      _loadFiles();
    }
  }

  Future<void> _loadFiles({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (forceRefresh) {
        await SubtitleLibraryService.clearCache();
      }

      final items = await SubtitleLibraryService.getItemsInPath(_currentPath);
      final stats = await SubtitleLibraryService.getStats();

      setState(() {
        _files = items;
        _stats = stats;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = S.of(context).loadFailed;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleSearch(String query) async {
    if (query.isEmpty) {
      _loadFiles();
      return;
    }

    setState(() {
      _isLoading = true;
      _searchQuery = query;
    });

    try {
      final results = await SubtitleDatabase.instance.searchContent(query);
      setState(() {
        _files = results.map((r) => {
          'type': 'text',
          'title': r['file_name'] as String,
          'path': r['relative_path'] as String,
          'size': (r['file_size'] as int?) ?? 0,
          'modified': r['modified_at'] as String?,
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '搜索失败';
      });
    }
  }

  void _showImportOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: Text(S.of(context).importSubtitleFile),
              onTap: () { Navigator.pop(context); _importFile(); },
            ),
            if (!Platform.isIOS)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(S.of(context).importFolder),
                onTap: () { Navigator.pop(context); _importFolder(); },
              ),
            ListTile(
              leading: const Icon(Icons.archive),
              title: Text(S.of(context).importArchive),
              onTap: () { Navigator.pop(context); _importArchive(); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFile() async {
    _showLoading();
    final result = await SubtitleLibraryService.importSubtitleFile();
    Navigator.pop(context);
    if (result.success) {
      _loadFiles();
      SnackBarUtil.showSuccess(context, result.message);
    } else {
      SnackBarUtil.showError(context, result.message);
    }
  }

  Future<void> _importFolder() async {
    final progress = _showProgress(S.of(context).preparingImport);
    final result = await SubtitleLibraryService.importFolder(onProgress: progress);
    Navigator.pop(context);
    if (result.success) {
      _loadFiles();
      SnackBarUtil.showSuccess(context, result.message);
    } else {
      SnackBarUtil.showError(context, result.message);
    }
  }

  Future<void> _importArchive() async {
    final progress = _showProgress(S.of(context).preparingExtract);
    final result = await SubtitleLibraryService.importArchive(onProgress: progress);
    Navigator.pop(context);
    if (result.success) {
      _loadFiles();
      SnackBarUtil.showSuccess(context, result.message);
    } else {
      SnackBarUtil.showError(context, result.message);
    }
  }

  void _showLoading() {
    showDialog(context: context, barrierDismissible: false, builder: (context) => const Center(child: CircularProgressIndicator()));
  }

  void Function(String) _showProgress(String msg) {
    final notifier = ValueNotifier(msg);
    showDialog(context: context, barrierDismissible: false, builder: (context) => AlertDialog(content: ValueListenableBuilder(valueListenable: notifier, builder: (context, v, _) => Text(v.toString()))));
    return (s) => notifier.value = s;
  }

  void _showFileOptions(Map<String, dynamic> item, String path) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.subtitles), title: Text(S.of(context).loadAsSubtitle), onTap: () { Navigator.pop(context); _loadLyricManually(item); }),
            ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: Text(S.of(context).delete), onTap: () { Navigator.pop(context); _deleteItem(item); }),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final title = (item['title'] ?? '') as String;
    final path = (item['path'] ?? '') as String;
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: Text(S.of(context).confirmDelete), content: Text(S.of(context).deleteItemConfirm(title)), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.of(context).cancel)), TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.of(context).delete))]));
    if (ok == true) {
      if (await SubtitleLibraryService.delete(path)) { _loadFiles(); SnackBarUtil.showSuccess(context, S.of(context).deleteSuccess); }
    }
  }

  Future<void> _loadLyricManually(Map<String, dynamic> item) async {
    final path = (item['path'] ?? '') as String;
    final track = ref.read(currentTrackProvider).value;
    if (track == null) { SnackBarUtil.showError(context, S.of(context).noAudioCannotLoadSubtitle); return; }
    try {
      await ref.read(lyricControllerProvider.notifier).loadLyricFromLibrary(path);
      SnackBarUtil.showSuccess(context, S.of(context).subtitleLoadSuccess(item['title'] ?? ''));
    } catch (e) { SnackBarUtil.showError(context, S.of(context).subtitleLoadFailed(e.toString())); }
  }

  List<Widget> _buildItemList(List<Map<String, dynamic>> items) {
    return items.map((item) {
      final isFolder = item['type'] == 'folder';
      final path = (item['path'] ?? '') as String;
      final title = (item['title'] ?? '') as String;
      return ListTile(
        leading: Icon(isFolder ? Icons.folder : Icons.text_snippet, color: isFolder ? Colors.amber : Colors.grey),
        title: Text(isFolder ? _localizedFolderTitle(context, title) : title),
        onTap: () => isFolder ? _navigateTo(path) : _previewFile(path),
        trailing: isFolder ? null : IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _showFileOptions(item, path)),
      );
    }).toList();
  }

  void _previewFile(String path) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => TextPreviewScreen(title: path.split('/').last, textUrl: 'library://$path', workId: null, onSavedToLibrary: () => _loadFiles())));
  }

  @override
  Widget build(BuildContext context) {
    final breadcrumbs = <Widget>[InkWell(onTap: () => setState(() { _currentPath = ''; _navigationStack.clear(); _loadFiles(); }), child: Text(S.of(context).subtitleLibrary, style: const TextStyle(color: Colors.blue)))];
    if (_currentPath.isNotEmpty) {
      final parts = _currentPath.split('/');
      String acc = '';
      for (int i = 0; i < parts.length; i++) {
        acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
        final target = acc;
        breadcrumbs.add(const Text(' > '));
        breadcrumbs.add(InkWell(onTap: i == parts.length - 1 ? null : () => _jumpToPath(target), child: Text(parts[i])));
      }
    }

    return WillPopScope(
      onWillPop: () async {
        if (_currentPath.isEmpty && _navigationStack.isEmpty) return true;
        _navigateUp();
        return false;
      },
      child: Scaffold(
        floatingActionButton: FloatingActionButton(onPressed: _showImportOptions, child: const Icon(Icons.add)),
        body: Column(
          children: [
            Container(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (_isSearching) Expanded(child: TextField(controller: _searchController, decoration: const InputDecoration(hintText: '搜索...', border: InputBorder.none), onSubmitted: _handleSearch)) else const Spacer(),
                IconButton(icon: Icon(_isSearching ? Icons.close : Icons.search), onPressed: () => setState(() { _isSearching = !_isSearching; if (!_isSearching) _loadFiles(); })),
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => _loadFiles(forceRefresh: true)),
              ]),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: breadcrumbs)),
            ])),
            if (_navigationStack.isNotEmpty) ListTile(leading: const Icon(Icons.arrow_back), title: Text(S.of(context).back), onTap: _navigateUp),
            Expanded(child: _isLoading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: () => _loadFiles(forceRefresh: true), child: ListView(children: _buildItemList(_files)))),
          ],
        ),
      ),
    );
  }

  void _jumpToPath(String path) {
    setState(() {
      final parts = path.split('/');
      _navigationStack.clear();
      String acc = '';
      for (int i = 0; i < parts.length - 1; i++) {
        _navigationStack.add(acc);
        acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
      }
      _currentPath = path;
    });
    _loadFiles();
  }
}
