import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/subtitle_library_service.dart';
import '../services/subtitle_database.dart';
import '../providers/settings_provider.dart';
import '../widgets/text_preview_screen.dart';
import '../providers/audio_provider.dart';
import '../providers/lyric_provider.dart';
import '../widgets/responsive_dialog.dart';
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
  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = {}; // 选中的相对路径

  // 搜索相关
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  String _currentPath = ''; // 当前相对路径
  final List<String> _navigationStack = []; // 导航栈

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

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedPaths.clear();
      }
    });
  }

  void _navigateTo(String relativePath) {
    setState(() {
      _navigationStack.add(_currentPath);
      _currentPath = relativePath;
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
      _selectedPaths.clear();
      _isSelectionMode = false;
    });
    _loadFiles();
  }

  void _navigateUp() {
    if (_navigationStack.isNotEmpty) {
      setState(() {
        _currentPath = _navigationStack.removeLast();
        _selectedPaths.clear();
        _isSelectionMode = false;
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
          'title': r['file_name'],
          'path': r['relative_path'],
          'size': r['file_size'] ?? 0,
          'modified': r['modified_at'],
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

  Future<void> _importFile() async {
    _showSimpleLoadingDialog(S.of(context).importingSubtitleFile);
    final result = await SubtitleLibraryService.importSubtitleFile();
    if (!mounted) return;
    Navigator.of(context).pop();

    if (result.success) {
      await _loadFiles();
      SnackBarUtil.showSuccess(context, result.message);
    } else {
      SnackBarUtil.showError(context, result.message);
    }
  }

  void _showSimpleLoadingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(message),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importFolder() async {
    final updateProgress = _showProgressDialog(S.of(context).preparingImport);
    final result = await SubtitleLibraryService.importFolder(onProgress: updateProgress);
    if (!mounted) return;
    Navigator.of(context).pop();

    if (result.success) {
      await _loadFiles();
      SnackBarUtil.showSuccess(context, result.message);
    } else {
      SnackBarUtil.showError(context, result.message);
    }
  }

  Future<void> _importArchive() async {
    final updateProgress = _showProgressDialog(S.of(context).preparingExtract);
    final result = await SubtitleLibraryService.importArchive(onProgress: updateProgress);
    if (!mounted) return;
    Navigator.of(context).pop();

    if (result.success) {
      await _loadFiles();
      SnackBarUtil.showSuccess(context, result.message);
    } else {
      SnackBarUtil.showError(context, result.message);
    }
  }

  void Function(String)? _showProgressDialog(String initialMessage) {
    final ValueNotifier<String> progressNotifier = ValueNotifier(initialMessage);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: progressNotifier,
            builder: (context, message, child) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
    return (String message) {
      if (mounted) progressNotifier.value = message;
    };
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
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showFileOptions(Map<String, dynamic> item, String path) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item['type'] == 'text')
              ListTile(
                leading: const Icon(Icons.subtitles, color: Colors.orange),
                title: Text(S.of(context).loadAsSubtitle),
                onTap: () { Navigator.pop(context); _loadLyricManually(item); },
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text(S.of(context).delete, style: const TextStyle(color: Colors.red)),
              onTap: () { Navigator.pop(context); _deleteItem(item); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final title = (item['title'] ?? '未知') as String;
    final path = (item['path'] ?? '') as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.of(context).confirmDelete),
        content: Text(S.of(context).deleteItemConfirm(title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.of(context).cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), style: TextButton.styleFrom(foregroundColor: Colors.red), child: Text(S.of(context).delete)),
        ],
      ),
    );
    if (confirmed != true) return;
    final success = await SubtitleLibraryService.delete(path);
    if (success) {
      await _loadFiles();
      SnackBarUtil.showSuccess(context, S.of(context).deleteSuccess);
    }
  }

  Future<void> _loadLyricManually(Map<String, dynamic> item) async {
    final title = (item['title'] ?? '未知文件') as String;
    final path = (item['path'] ?? '') as String;
    final currentTrack = ref.read(currentTrackProvider).value;

    if (currentTrack == null) {
      SnackBarUtil.showError(context, S.of(context).noAudioCannotLoadSubtitle);
      return;
    }

    try {
      await ref.read(lyricControllerProvider.notifier).loadLyricFromLibrary(path);
      SnackBarUtil.showSuccess(context, S.of(context).subtitleLoadSuccess(title));
    } catch (e) {
      SnackBarUtil.showError(context, S.of(context).subtitleLoadFailed(e.toString()));
    }
  }

  List<Widget> _buildItemList(List<Map<String, dynamic>> items) {
    return items.map((item) {
      final isFolder = item['type'] == 'folder';
      final path = (item['path'] ?? '') as String;
      final title = (item['title'] ?? '') as String;
      final isSelected = _selectedPaths.contains(path);

      return InkWell(
        onTap: () {
          if (_isSelectionMode) {
            setState(() => isSelected ? _selectedPaths.remove(path) : _selectedPaths.add(path));
          } else if (isFolder) {
            _navigateTo(path);
          } else {
            _previewFile(path);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(isFolder ? Icons.folder : Icons.text_snippet, color: isFolder ? Colors.amber : Colors.grey),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  isFolder ? _localizedFolderTitle(context, title) : title,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isFolder) IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _showFileOptions(item, path)),
              if (_isSelectionMode) Icon(isSelected ? Icons.check_circle : Icons.radio_button_unchecked, color: isSelected ? Colors.blue : Colors.grey),
            ],
          ),
        ),
      );
    }).toList();
  }

  Future<void> _previewFile(String path) async {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => TextPreviewScreen(
      title: path.split('/').last,
      textUrl: 'library://$path',
      workId: null,
      onSavedToLibrary: () => _loadFiles(),
    )));
  }

  void _resetToRoot() {
    setState(() { _currentPath = ''; _navigationStack.clear(); });
    _loadFiles();
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

  Widget _buildTopBar() {
    List<Widget> breadcrumbs = [
      InkWell(onTap: _resetToRoot, child: Text(S.of(context).subtitleLibrary, style: const TextStyle(color: Colors.blue))),
    ];
    if (_currentPath.isNotEmpty) {
      final parts = _currentPath.split('/');
      String pathAcc = '';
      for (int i = 0; i < parts.length; i++) {
        pathAcc = pathAcc.isEmpty ? parts[i] : '$pathAcc/${parts[i]}';
        final targetPath = pathAcc;
        breadcrumbs.add(const Text(' > '));
        breadcrumbs.add(InkWell(onTap: i == parts.length - 1 ? null : () => _jumpToPath(targetPath), child: Text(parts[i], style: TextStyle(fontWeight: i == parts.length - 1 ? FontWeight.bold : FontWeight.normal))));
      }
    }

    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_isSearching)
                Expanded(child: TextField(controller: _searchController, decoration: const InputDecoration(hintText: '搜索字幕内容...', border: InputBorder.none), onSubmitted: _handleSearch))
              else
                const Spacer(),
              IconButton(icon: Icon(_isSearching ? Icons.close : Icons.search), onPressed: () => setState(() { _isSearching = !_isSearching; if (!_isSearching) _loadFiles(); })),
              IconButton(icon: const Icon(Icons.refresh), onPressed: () => _loadFiles(forceRefresh: true)),
            ],
          ),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: breadcrumbs)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentPath.isEmpty && _navigationStack.isEmpty,
      onPopInvoked: (didPop) { if (!didPop) _navigateUp(); },
      child: Scaffold(
        floatingActionButton: FloatingActionButton(onPressed: _showImportOptions, child: const Icon(Icons.add)),
        body: Column(
          children: [
            _buildTopBar(),
            if (_navigationStack.isNotEmpty) ListTile(leading: const Icon(Icons.arrow_back), title: Text(S.of(context).back), onTap: _navigateUp),
            Expanded(
              child: _isLoading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: () => _loadFiles(forceRefresh: true), child: ListView(children: _buildItemList(_files))),
            ),
          ],
        ),
      ),
    );
  }
}
