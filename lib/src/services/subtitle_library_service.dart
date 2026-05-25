import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'download_path_service.dart';
import 'subtitle_database.dart';
import '../utils/file_icon_utils.dart';

/// 字幕库管理服务
class SubtitleLibraryService {
  static const String _libraryFolderName = 'subtitle_library';

  // 自动分配目录名称
  static const String parsedFolderName = '已解析';
  static const String unknownFolderName = '未知作品';
  static const String savedFolderName = '已保存';

  // 数据库初始化标志
  static bool _dbInitialized = false;
  static Future<void>? _dbInitFuture;

  static final _cacheUpdateController = StreamController<void>.broadcast();
  static Stream<void> get onCacheUpdated => _cacheUpdateController.stream;

  /// 检查匹配结果
  static (bool, double) checkMatch(String subtitleFileName, String audioFileName) {
    final lowerSubtitle = subtitleFileName.toLowerCase();
    final lowerAudio = audioFileName.toLowerCase();
    final textExtensions = ['.vtt', '.srt', '.txt', '.lrc', '.ass', '.ssa'];

    String? subtitleContentName;
    for (final ext in textExtensions) {
      if (lowerSubtitle.endsWith(ext)) {
        subtitleContentName = lowerSubtitle.substring(0, lowerSubtitle.length - ext.length);
        break;
      }
    }
    if (subtitleContentName == null) return (false, 0.0);

    final audioBaseName = removeAudioExtension(lowerAudio);
    final subtitleBaseName = removeAudioExtension(subtitleContentName);

    if (audioBaseName == subtitleBaseName) return (true, 1.0);

    final normalizedAudio = _normalizeForMatching(audioBaseName);
    final normalizedSubtitle = _normalizeForMatching(subtitleBaseName);
    if (normalizedAudio.isEmpty || normalizedSubtitle.isEmpty) return (false, 0.0);
    if (normalizedAudio == normalizedSubtitle) return (true, 1.0);

    final similarity = _calculateSimilarity(normalizedAudio, normalizedSubtitle);
    final threshold = normalizedAudio.length < 10 ? 0.9 : 0.85;
    return (similarity >= threshold, similarity);
  }

  static bool isSubtitleForAudio(String subtitleFileName, String audioFileName) {
    return checkMatch(subtitleFileName, audioFileName).$1;
  }

  static String _normalizeForMatching(String fileName) {
    var result = fileName;
    result = result.replaceAll(RegExp(r'\（.*?\）'), '');
    result = result.replaceAll(RegExp(r'\(.*?\)'), '');
    result = result.replaceAll(RegExp(r'\[.*?\]'), '');
    result = result.replaceAll(RegExp(r'【.*?】'), '');
    final suffixesToRemove = ['_se无', '_se', '_se有', '_seなし', '_nose', '_se無し', '_se有り', '_seあり', '_se_off', 'se无', 'se有', 'seなし', 'nose', 'se無し', 'se有り', 'seあり', 'se_off'];
    for (final suffix in suffixesToRemove) {
      if (result.toLowerCase().endsWith(suffix)) {
        result = result.substring(0, result.length - suffix.length);
      }
    }
    result = result.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\u3040-\u309f\u30a0-\u30ff]'), '');
    return result.trim();
  }

  static double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final distance = _levenshteinDistance(s1, s2);
    final maxLength = s1.length > s2.length ? s1.length : s2.length;
    return 1.0 - (distance / maxLength);
  }

  static int _levenshteinDistance(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;
    List<int> v0 = List<int>.generate(s2.length + 1, (i) => i);
    List<int> v1 = List<int>.filled(s2.length + 1, 0);
    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < s2.length; j++) {
        int cost = (s1.codeUnitAt(i) == s2.codeUnitAt(j)) ? 0 : 1;
        v1[j + 1] = [v1[j] + 1, v0[j + 1] + 1, v0[j] + cost].reduce((c, n) => c < n ? c : n);
      }
      for (int j = 0; j <= s2.length; j++) v0[j] = v1[j];
    }
    return v1[s2.length];
  }

  static String removeAudioExtension(String fileName) {
    final audioExtensions = ['.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wma', '.mp4', '.m4b'];
    final lowerName = fileName.toLowerCase();
    for (final ext in audioExtensions) {
      if (lowerName.endsWith(ext)) return fileName.substring(0, fileName.length - ext.length);
    }
    return fileName;
  }

  static Future<void> clearCache() async {
    final libraryDir = await getSubtitleLibraryDirectory();
    await _rebuildDatabase(libraryDir);
    _cacheUpdateController.add(null);
  }

  static Future<void> ensureInitialized() => _ensureDatabase();

  static Future<void> _ensureDatabase() async {
    if (_dbInitialized) return;
    _dbInitFuture ??= _initDatabase();
    await _dbInitFuture;
  }

  static Future<void> _initDatabase() async {
    if (_dbInitialized) return;
    final libraryDir = await getSubtitleLibraryDirectory();
    final fileCount = await SubtitleDatabase.instance.getFileCount();
    if (fileCount == 0) await _rebuildDatabase(libraryDir);
    _dbInitialized = true;
  }

  static Future<void> _rebuildDatabase(Directory libraryDir) async {
    await SubtitleDatabase.instance.clear();
    final records = <SubtitleFileRecord>[];
    await _scanDirectoryForRecords(libraryDir, libraryDir.path, records);
    if (records.isNotEmpty) await SubtitleDatabase.instance.insertFiles(records);
  }

  static Future<void> _scanDirectoryForRecords(Directory dir, String rootPath, List<SubtitleFileRecord> records) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (entity.path.split(Platform.pathSeparator).last.startsWith('.')) continue;
          await _scanDirectoryForRecords(entity, rootPath, records);
        } else if (entity is File && FileIconUtils.isLyricFile(entity.path)) {
          final bytes = await entity.readAsBytes();
          final relativePath = _toRelativePath(entity.path.substring(rootPath.length + 1));
          records.add(SubtitleFileRecord(
            fileName: entity.path.split(Platform.pathSeparator).last,
            relativePath: relativePath,
            parentPath: _extractParentPath(relativePath),
            category: _extractCategory(relativePath),
            workId: _extractWorkIdFromPath(relativePath),
            fileSize: bytes.length,
            content: GZipEncoder().encode(bytes),
            modifiedAt: (await entity.stat()).modified.toIso8601String(),
            normalizedName: _computeNormalizedName(entity.path.split(Platform.pathSeparator).last),
          ));
        }
      }
    } catch (_) {}
  }

  static String _toRelativePath(String raw) => Platform.isWindows ? raw.replaceAll('\\', '/') : raw;

  static int? _extractWorkIdFromPath(String relativePath) {
    final match = RegExp(r'[RrBbVv][Jj]0*(\d+)').firstMatch(relativePath);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  static String _extractCategory(String relativePath) {
    final firstSlash = relativePath.indexOf('/');
    return firstSlash > 0 ? relativePath.substring(0, firstSlash) : '';
  }

  static String _extractParentPath(String relativePath) {
    final lastSlash = relativePath.lastIndexOf('/');
    return lastSlash > 0 ? relativePath.substring(0, lastSlash) : '';
  }

  static String _decodeText(List<int> bytes) {
    try { return utf8.decode(bytes); } catch (_) {
      try { return gbk_bytes.decode(bytes); } catch (_) { return latin1.decode(bytes); }
    }
  }

  static String _computeNormalizedName(String fileName) {
    final exts = ['.vtt', '.srt', '.txt', '.lrc', '.ass', '.ssa'];
    String base = fileName.toLowerCase();
    for (final ext in exts) { if (base.endsWith(ext)) { base = base.substring(0, base.length - ext.length); break; } }
    return _normalizeForMatching(removeAudioExtension(base));
  }

  static Future<List<Map<String, dynamic>>> getItemsInPath(String relativePath) async {
    await _ensureDatabase();
    final normalized = _toRelativePath(relativePath);
    final subFolders = await SubtitleDatabase.instance.getSubFolders(normalized);
    final files = await SubtitleDatabase.instance.getFilesByParent(normalized);
    final List<Map<String, dynamic>> items = [];
    for (final f in subFolders) items.add({'type': 'folder', 'title': f, 'path': normalized.isEmpty ? f : '$normalized/$f'});
    for (final f in files) items.add({'type': 'text', 'title': f.fileName, 'path': f.relativePath, 'size': f.fileSize, 'modified': f.modifiedAt});
    return items;
  }

  static Future<String?> getSubtitleContent(String relativePath) async {
    await _ensureDatabase();
    final db = await SubtitleDatabase.instance.database;
    final results = await db.query('subtitle_files', columns: ['content'], where: 'relative_path = ?', whereArgs: [relativePath]);
    if (results.isEmpty || results.first['content'] == null) return null;
    final decompressed = GZipDecoder().decodeBytes(results.first['content'] as List<int>);
    return _decodeText(decompressed);
  }

  static Future<ImportResult> importSubtitleFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['vtt', 'srt', 'lrc', 'txt', 'ass', 'ssa'], allowMultiple: true);
      if (result == null || result.files.isEmpty) return ImportResult(success: false, message: '未选择文件');
      int count = 0;
      for (final f in result.files) {
        if (f.path == null) continue;
        final bytes = await File(f.path!).readAsBytes();
        final relPath = '$savedFolderName/${f.name}';
        await SubtitleDatabase.instance.insertFile(SubtitleFileRecord(
          fileName: f.name, relativePath: relPath, parentPath: savedFolderName, category: savedFolderName,
          fileSize: bytes.length, content: GZipEncoder().encode(bytes), modifiedAt: DateTime.now().toIso8601String(),
          normalizedName: _computeNormalizedName(f.name),
        ), plainText: _decodeText(bytes));
        count++;
      }
      _cacheUpdateController.add(null);
      return ImportResult(success: true, message: '成功导入 $count 个文件', importedCount: count);
    } catch (e) { return ImportResult(success: false, message: '导入失败: $e'); }
  }

  static Future<ImportResult> importFolder({Function(String)? onProgress}) async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null) return ImportResult(success: false, message: '未选择文件夹');
      final sourceDir = Directory(path);
      final stats = _ImportStats();
      await _processDirectoryRecursively(sourceDir, '', stats, onProgress: onProgress);
      _cacheUpdateController.add(null);
      return ImportResult(success: stats.successCount > 0, message: '成功导入 ${stats.successCount} 个文件', importedCount: stats.successCount);
    } catch (e) { return ImportResult(success: false, message: '导入失败: $e'); }
  }

  static Future<void> _processDirectoryRecursively(Directory dir, String relativePath, _ImportStats stats, {Function(String)? onProgress}) async {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        await _processDirectoryRecursively(entity, relativePath.isEmpty ? name : '$relativePath/$name', stats, onProgress: onProgress);
      } else if (entity is File && FileIconUtils.isLyricFile(entity.path)) {
        final bytes = await entity.readAsBytes();
        final fileName = entity.path.split(Platform.pathSeparator).last;
        final relPath = relativePath.isEmpty ? fileName : '$relativePath/$fileName';
        String category = unknownFolderName;
        final workId = _extractWorkIdFromPath(relPath);
        if (workId != null) category = parsedFolderName;
        final finalRelPath = '$category/$relPath';
        
        await SubtitleDatabase.instance.insertFile(SubtitleFileRecord(
          fileName: fileName, relativePath: finalRelPath, parentPath: _extractParentPath(finalRelPath),
          category: category, workId: workId, fileSize: bytes.length, content: GZipEncoder().encode(bytes),
          modifiedAt: DateTime.now().toIso8601String(), normalizedName: _computeNormalizedName(fileName),
        ), plainText: _decodeText(bytes));
        stats.successCount++;
        if (stats.successCount % 50 == 0) onProgress?.call('已处理 ${stats.successCount} 个文件...');
      }
    }
  }

  static Future<ImportResult> importArchive({Function(String)? onProgress}) async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
      if (result == null || result.files.isEmpty || result.files.first.path == null) return ImportResult(success: false, message: '未选择压缩包');
      final bytes = await File(result.files.first.path!).readAsBytes();
      final stats = _ImportStats();
      await _processArchiveBytes(bytes, 'zip', '', stats, depth: 0, onProgress: onProgress);
      _cacheUpdateController.add(null);
      return ImportResult(success: stats.successCount > 0, message: '成功导入 ${stats.successCount} 个文件', importedCount: stats.successCount);
    } catch (e) { return ImportResult(success: false, message: '导入失败: $e'); }
  }

  static Future<void> _processArchiveBytes(List<int> bytes, String ext, String relativePath, _ImportStats stats, {required int depth, Function(String)? onProgress}) async {
    if (depth > 10) return;
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      String name = file.name;
      try { name = gbk_bytes.decode(latin1.encode(file.name)); } catch (_) {}
      final fileName = name.split('/').last;
      final content = file.content as List<int>;
      if (fileName.toLowerCase().endsWith('.zip')) {
        await _processArchiveBytes(content, 'zip', relativePath.isEmpty ? name.replaceAll('.zip','') : '$relativePath/${name.replaceAll('.zip','')}', stats, depth: depth + 1, onProgress: onProgress);
      } else if (FileIconUtils.isLyricFile(fileName)) {
        final relPath = relativePath.isEmpty ? name : '$relativePath/$name';
        String category = unknownFolderName;
        final workId = _extractWorkIdFromPath(relPath);
        if (workId != null) category = parsedFolderName;
        final finalRelPath = '$category/$relPath';
        await SubtitleDatabase.instance.insertFile(SubtitleFileRecord(
          fileName: fileName, relativePath: finalRelPath, parentPath: _extractParentPath(finalRelPath),
          category: category, workId: workId, fileSize: content.length, content: GZipEncoder().encode(content),
          modifiedAt: DateTime.now().toIso8601String(), normalizedName: _computeNormalizedName(fileName),
        ), plainText: _decodeText(content));
        stats.successCount++;
        if (stats.successCount % 50 == 0) onProgress?.call('已处理 ${stats.successCount} 个文件...');
      }
    }
  }

  static Future<bool> delete(String relativePath) async {
    try {
      await _ensureDatabase();
      await SubtitleDatabase.instance.deleteByRelativePath(relativePath);
      await SubtitleDatabase.instance.deleteByRelativePathPrefix('$relativePath/');
      _cacheUpdateController.add(null);
      return true;
    } catch (_) { return false; }
  }

  static Future<bool> rename(String oldPath, String newName) async {
    try {
      await _ensureDatabase();
      final lastSlash = oldPath.lastIndexOf('/');
      final parent = lastSlash > 0 ? oldPath.substring(0, lastSlash) : '';
      await SubtitleDatabase.instance.renamePath(oldPath, parent.isEmpty ? newName : '$parent/$newName');
      _cacheUpdateController.add(null);
      return true;
    } catch (_) { return false; }
  }

  static Future<bool> move(String src, String target) async {
    try {
      await _ensureDatabase();
      final name = src.split('/').last;
      await SubtitleDatabase.instance.renamePath(src, target.isEmpty ? name : '$target/$name');
      _cacheUpdateController.add(null);
      return true;
    } catch (_) { return false; }
  }

  static Future<LibraryStats> getStats({bool forceRefresh = false}) async {
    await _ensureDatabase();
    if (forceRefresh) await _rebuildDatabase(await getSubtitleLibraryDirectory());
    final raw = await SubtitleDatabase.instance.getStatsRaw();
    return LibraryStats(totalFiles: raw['totalFiles']!, totalSize: raw['totalSize']!, folderCount: await SubtitleDatabase.instance.getFolderCount());
  }

  static Future<Directory> getSubtitleLibraryDirectory() async {
    final downloadDir = await DownloadPathService.getDownloadDirectory();
    final dir = Directory('${downloadDir.path}/$_libraryFolderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

class ImportResult {
  final bool success;
  final String message;
  final int importedCount;
  final int errorCount;
  ImportResult({required this.success, required this.message, this.importedCount = 0, this.errorCount = 0});
}

class LibraryStats {
  final int totalFiles;
  final int totalSize;
  final int folderCount;
  LibraryStats({required this.totalFiles, required this.totalSize, required this.folderCount});
  String get sizeFormatted {
    if (totalSize < 1024) return '$totalSize B';
    if (totalSize < 1024*1024) return '${(totalSize/1024).toStringAsFixed(1)} KB';
    if (totalSize < 1024*1024*1024) return '${(totalSize/(1024*1024)).toStringAsFixed(1)} MB';
    return '${(totalSize/(1024*1024*1024)).toStringAsFixed(1)} GB';
  }
}

class _ImportStats { int successCount = 0; int errorCount = 0; int skippedCount = 0; }
