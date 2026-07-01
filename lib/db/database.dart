import 'dart:io' show Platform, Directory, File;
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/ad_sample.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();

  Database? _db;
  String _basePath = '';

  String get basePath => _basePath;

  Future<void> init() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      _basePath = dir.path;
    } else {
      _basePath = Directory.current.path;
    }

    final dbPath = p.join(_basePath, 'ad_fingerprints.db');

    if (Platform.isAndroid || Platform.isIOS) {
      _db = await sqlite.openDatabase(
        dbPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS ad_samples (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              video_path TEXT,
              start_frame_hash TEXT NOT NULL,
              end_frame_hash TEXT NOT NULL,
              duration REAL NOT NULL,
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
          ''');
        },
      );
    } else {
      sqfliteFfiInit();
      _db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS ad_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                video_path TEXT,
                start_frame_hash TEXT NOT NULL,
                end_frame_hash TEXT NOT NULL,
                duration REAL NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
              )
            ''');
          },
        ),
      );
    }
  }

  Future<List<AdSample>> getSamples() async {
    final db = _db!;
    final maps = await db.query('ad_samples', orderBy: 'name');
    return maps.map((m) => AdSample.fromMap(m)).toList();
  }

  Future<int> addSample(AdSample sample) async {
    final db = _db!;
    return db.insert('ad_samples', sample.toMap());
  }

  Future<int> deleteSample(int id) async {
    final db = _db!;
    final sample = await db.query('ad_samples', where: 'id = ?', whereArgs: [id]);
    if (sample.isNotEmpty) {
      await _deleteSampleImages(sample.first['name'] as String);
    }
    return db.delete('ad_samples', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteSampleByName(String name) async {
    final db = _db!;
    await db.delete('ad_samples', where: 'name = ?', whereArgs: [name]);
    await _deleteSampleImages(name);
  }

  Future<void> _deleteSampleImages(String name) async {
    final dir = Directory(p.join(_basePath, 'sample'));
    if (!dir.existsSync()) return;

    for (final prefix in ['temp_start_', 'temp_end_']) {
      final file = File(p.join(dir.path, '$prefix$name.jpg'));
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<Directory> getSampleDir() async {
    final dir = Directory(p.join(_basePath, 'sample'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String sampleImagePath(String name, {required bool isStart}) {
    final prefix = isStart ? 'temp_start_' : 'temp_end_';
    return p.join(_basePath, 'sample', '$prefix$name.jpg');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
