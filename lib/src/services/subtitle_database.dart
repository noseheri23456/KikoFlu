import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 字幕文件数据库记录
///
/// 数据库只存储相对路径（相对于字幕库根目录），绝对路径在运行时动态拼接。
/// 这样即使 iOS 重装后沙盒 UUID 变化，或其他平台迁移下载目录，数据库无需更新。
class SubtitleFileRecord {
  final String fileName;
  final String relativePath;
  final String parentPath; // 父目录路径，用于懒加载索引
  final String category;
  final int? workId;
  final int fileSize;
  final List<int>? content; // 压缩后的内容
  final String? modifiedAt;
  final String? normalizedName;

  SubtitleFileRecord({
    required this.fileName,
    required this.relativePath,
    required this.parentPath,
    required this.category,
    this.workId,
    this.fileSize = 0,
    this.content,
    this.modifiedAt,
    this.normalizedName,
  });

  Map<String, dynamic> toMap() => {
        'file_name': fileName,
        'relative_path': relativePath,
        'parent_path': parentPath,
        'category': category,
        'work_id': workId,
        'file_size': fileSize,
        'content': content,
        'modified_at': modifiedAt,
        'normalized_name': normalizedName,
      };

  factory SubtitleFileRecord.fromMap(Map<String, dynamic> map) {
    return SubtitleFileRecord(
      fileName: map['file_name'] as String,
      relativePath: map['relative_path'] as String,
      parentPath: map['parent_path'] as String? ?? '',
      category: map['category'] as String,
      workId: map['work_id'] as int?,
      fileSize: (map['file_size'] as int?) ?? 0,
      content: map['content'] as List<int>?,
      modifiedAt: map['modified_at'] as String?,
      normalizedName: map['normalized_name'] as String?,
    );
  }
}

/// 字幕库数据库
class SubtitleDatabase {
  static final SubtitleDatabase instance = SubtitleDatabase._init();
  static Database? _database;

  SubtitleDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('subtitle_library.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final String dbPath;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final appDocDir = await getApplicationDocumentsDirectory();
      dbPath = p.join(appDocDir.path, 'KikoFlu');
      await Directory(dbPath).create(recursive: true);
    } else {
      dbPath = await getDatabasesPath();
    }
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 3,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE subtitle_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        relative_path TEXT NOT NULL UNIQUE,
        parent_path TEXT NOT NULL,
        category TEXT NOT NULL,
        work_id INTEGER,
        file_size INTEGER DEFAULT 0,
        content BLOB,
        modified_at TEXT,
        normalized_name TEXT,
        created_at TEXT DEFAULT (datetime('now'))
      )
    ''');

    await db.execute(
        'CREATE INDEX idx_files_parent ON subtitle_files(parent_path)');
    await db.execute(
        'CREATE INDEX idx_files_work_id ON subtitle_files(work_id)');
    await db.execute(
        'CREATE INDEX idx_files_category ON subtitle_files(category)');

    // FTS5 全文搜索虚拟表 (需要 sqlite 支持 fts5)
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE subtitle_search USING fts5(
          file_id UNINDEXED,
          file_name,
          content_text,
          tokenize='unicode61'
        )
      ''');
    } catch (e) {
      print('[SubtitleDatabase] FTS5 不受支持，跳过全文搜索表创建: $e');
    }

    await db.execute('''
      CREATE TABLE library_meta (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      // v3: 增加 content 和 parent_path，支持全文搜索
      // 因为用户不考虑迁移，我们直接清空重建，或者简单点直接删表重建
      await db.execute('DROP TABLE IF EXISTS subtitle_files');
      await db.execute('DROP TABLE IF EXISTS subtitle_search');
      await _createDB(db, newVersion);
    }
  }

  // ==================== CRUD ====================

  /// 插入记录并同步索引
  Future<int> insertFile(SubtitleFileRecord record, {String? plainText}) async {
    final db = await database;
    final id = await db.insert('subtitle_files', record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);

    if (plainText != null) {
      try {
        await db.insert('subtitle_search', {
          'file_id': id,
          'file_name': record.fileName,
          'content_text': plainText,
        });
      } catch (_) {}
    }
    return id;
  }

  /// 批量插入（事务）
  Future<void> insertFiles(List<SubtitleFileRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final record in records) {
        batch.insert('subtitle_files', record.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// 按相对路径删除并同步索引
  Future<void> deleteByRelativePath(String relativePath) async {
    final db = await database;
    final files = await db.query('subtitle_files',
        columns: ['id'], where: 'relative_path = ?', whereArgs: [relativePath]);
    if (files.isNotEmpty) {
      final id = files.first['id'];
      await db.delete('subtitle_files', where: 'id = ?', whereArgs: [id]);
      try {
        await db.delete('subtitle_search',
            where: 'file_id = ?', whereArgs: [id]);
      } catch (_) {}
    }
  }

  // ==================== 查询 (懒加载核心) ====================

  /// 获取指定目录下的文件
  Future<List<SubtitleFileRecord>> getFilesByParent(String parentPath) async {
    final db = await database;
    final results = await db.query('subtitle_files',
        where: 'parent_path = ?',
        whereArgs: [parentPath],
        orderBy: 'file_name');
    return results.map((m) => SubtitleFileRecord.fromMap(m)).toList();
  }

  /// 获取指定目录下的子目录名
  Future<List<String>> getSubFolders(String parentPath) async {
    final db = await database;
    // 技巧：查询 parent_path 以当前路径开头的记录，提取下一级目录
    final prefix = parentPath.isEmpty ? '' : (parentPath.endsWith('/') ? parentPath : '$parentPath/');
    
    // 我们需要提取 relative_path 中 prefix 之后的第一段
    final results = await db.rawQuery('''
      SELECT DISTINCT 
        CASE 
          WHEN INSTR(SUBSTR(relative_path, LENGTH(?) + 1), '/') > 0
          THEN SUBSTR(SUBSTR(relative_path, LENGTH(?) + 1), 1, 
               INSTR(SUBSTR(relative_path, LENGTH(?) + 1), '/') - 1)
          ELSE ''
        END as folder_name
      FROM subtitle_files 
      WHERE relative_path LIKE ?
    ''', [prefix, prefix, '$prefix%']);

    return results
        .map((r) => r['folder_name'] as String)
        .where((name) => name.isNotEmpty)
        .toList();
  }

  /// 全文搜索
  Future<List<Map<String, dynamic>>> searchContent(String query) async {
    final db = await database;
    try {
      return await db.rawQuery('''
        SELECT f.id, f.file_name, f.relative_path, f.category, f.work_id
        FROM subtitle_search s
        JOIN subtitle_files f ON s.file_id = f.id
        WHERE subtitle_search MATCH ?
        ORDER BY rank
      ''', [query]);
    } catch (e) {
      // 如果 FTS5 不可用，退回到简单的文件名搜索
      return await db.query('subtitle_files',
          where: 'file_name LIKE ?',
          whereArgs: ['%$query%'],
          limit: 100);
    }
  }

  /// 获取单条内容
  Future<List<int>?> getContent(int id) async {
    final db = await database;
    final results = await db.query('subtitle_files',
        columns: ['content'], where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return results.first['content'] as List<int>?;
  }

  /// 按相对路径前缀删除（用于删除目录下所有文件）
  Future<int> deleteByRelativePathPrefix(String relativePrefix) async {
    final db = await database;
    // 确保路径以 / 结尾，避免误删同前缀的其他目录
    final prefix =
        relativePrefix.endsWith('/') ? relativePrefix : '$relativePrefix/';
    return await db.delete('subtitle_files',
        where: 'relative_path LIKE ?', whereArgs: ['$prefix%']);
  }

  /// 重命名路径（支持文件和文件夹）
  Future<void> renamePath(String oldRelativePath, String newRelativePath) async {
    final db = await database;
    
    // 1. 检查是否是精确文件匹配
    final count = await db.update(
      'subtitle_files',
      {
        'relative_path': newRelativePath,
        'parent_path': _extractParentPathFromRelativePath(newRelativePath),
        'file_name': newRelativePath.split('/').last,
        'category': _extractCategoryFromRelativePath(newRelativePath),
        'work_id': _extractWorkIdFromRelativePath(newRelativePath),
      },
      where: 'relative_path = ?',
      whereArgs: [oldRelativePath],
    );

    // 2. 如果不是文件或需要批量更新文件夹下的内容
    if (count == 0 || true) { // 即使更新了文件，也尝试更新其下属（如果是文件夹）
      final oldPrefix = oldRelativePath.endsWith('/') ? oldRelativePath : '$oldRelativePath/';
      final newPrefix = newRelativePath.endsWith('/') ? newRelativePath : '$newRelativePath/';
      
      final files = await db.query('subtitle_files',
          where: 'relative_path LIKE ?', whereArgs: ['$oldPrefix%']);

      if (files.isNotEmpty) {
        final batch = db.batch();
        for (final file in files) {
          final oldPath = file['relative_path'] as String;
          final newPath = oldPath.replaceFirst(oldRelativePath, newRelativePath);
          batch.update(
            'subtitle_files',
            {
              'relative_path': newPath,
              'parent_path': _extractParentPathFromRelativePath(newPath),
              'category': _extractCategoryFromRelativePath(newPath),
              'work_id': _extractWorkIdFromRelativePath(newPath),
            },
            where: 'id = ?',
            whereArgs: [file['id']],
          );
        }
        await batch.commit(noResult: true);
      }
    }
  }

  static String _extractParentPathFromRelativePath(String relativePath) {
    final lastSlash = relativePath.lastIndexOf('/');
    if (lastSlash > 0) {
      return relativePath.substring(0, lastSlash);
    }
    return '';
  }

  // ==================== 查询 ====================

  /// 获取所有文件记录
  Future<List<Map<String, dynamic>>> getAllFiles() async {
    final db = await database;
    return await db.query('subtitle_files', orderBy: 'relative_path');
  }

  /// 按 workId 查询
  Future<List<SubtitleFileRecord>> getFilesByWorkId(int workId) async {
    final db = await database;
    final results = await db.query('subtitle_files',
        where: 'work_id = ?', whereArgs: [workId]);
    return results.map((m) => SubtitleFileRecord.fromMap(m)).toList();
  }

  /// 按分类查询
  Future<List<SubtitleFileRecord>> getFilesByCategory(
      String category) async {
    final db = await database;
    final results = await db.query('subtitle_files',
        where: 'category = ?', whereArgs: [category]);
    return results.map((m) => SubtitleFileRecord.fromMap(m)).toList();
  }

  /// 获取所有不重复的 workId
  Future<Set<int>> getDistinctWorkIds() async {
    final db = await database;
    final results = await db.rawQuery(
        'SELECT DISTINCT work_id FROM subtitle_files WHERE work_id IS NOT NULL');
    return results
        .map((r) => r['work_id'] as int)
        .toSet();
  }

  /// 获取已解析目录下的文件夹名列表
  Future<List<String>> getParsedFolderNames(String parsedCategory) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT DISTINCT 
        CASE 
          WHEN INSTR(SUBSTR(relative_path, LENGTH(?) + 2), '/') > 0
          THEN SUBSTR(SUBSTR(relative_path, LENGTH(?) + 2), 1, 
               INSTR(SUBSTR(relative_path, LENGTH(?) + 2), '/') - 1)
          ELSE SUBSTR(relative_path, LENGTH(?) + 2)
        END as folder_name
      FROM subtitle_files 
      WHERE category = ?
    ''', [parsedCategory, parsedCategory, parsedCategory, parsedCategory, parsedCategory]);
    return results
        .map((r) => r['folder_name'] as String)
        .where((name) => name.isNotEmpty && name.contains('.') == false)
        .toList();
  }

  /// 获取统计信息（文件数 + 总大小）
  Future<Map<String, int>> getStatsRaw() async {
    final db = await database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) as total_files, COALESCE(SUM(file_size), 0) as total_size FROM subtitle_files');
    return {
      'totalFiles': (result.first['total_files'] as int?) ?? 0,
      'totalSize': (result.first['total_size'] as int?) ?? 0,
    };
  }

  /// 获取文件记录数量
  Future<int> getFileCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM subtitle_files')) ??
        0;
  }

  /// 获取不重复的文件夹数量（从 relative_path 推算）
  Future<int> getFolderCount() async {
    final db = await database;
    // 提取 relative_path 中所有目录层级，去重计数
    // 例如 "已解析/RJ123/sub/a.vtt" → "已解析", "已解析/RJ123", "已解析/RJ123/sub"
    final results = await db.query('subtitle_files', columns: ['relative_path']);
    final folderPaths = <String>{};
    for (final row in results) {
      final relativePath = row['relative_path'] as String;
      final parts = relativePath.split('/');
      for (int i = 1; i < parts.length; i++) {
        folderPaths.add(parts.sublist(0, i).join('/'));
      }
    }
    return folderPaths.length;
  }

  // ==================== 元数据 ====================

  Future<String?> getMeta(String key) async {
    final db = await database;
    final results = await db.query('library_meta',
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (results.isEmpty) return null;
    return results.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await database;
    await db.insert('library_meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ==================== 维护 ====================

  /// 清空所有记录
  Future<void> clear() async {
    final db = await database;
    await db.delete('subtitle_files');
  }

  // ==================== 工具方法 ====================

  static final _workIdRegex = RegExp(r'[RrBbVv][Jj]0*(\d+)');

  /// 从相对路径提取分类（第一级目录）
  static String _extractCategoryFromRelativePath(String relativePath) {
    final firstSlash = relativePath.indexOf('/');
    if (firstSlash > 0) {
      return relativePath.substring(0, firstSlash);
    }
    return '';
  }

  /// 从相对路径提取 workId
  static int? _extractWorkIdFromRelativePath(String relativePath) {
    // 相对路径格式: "已解析/RJ1003058/track.vtt"
    final parts = relativePath.split('/');
    if (parts.length < 2) return null;
    // 检查第二级目录名
    final match = _workIdRegex.firstMatch(parts[1]);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }
}
