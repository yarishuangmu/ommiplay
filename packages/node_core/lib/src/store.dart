import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';


/// 本地持久化（SQLite，WAL）。M0 数据只存本机；M1 对等归集在记录上加 hlc 后升级。
class NodeStore {
  NodeStore._(this._db, this.path);

  final Database _db;
  final String path;

  static NodeStore open(String dataDir) {
    Directory(dataDir).createSync(recursive: true);
    final dbPath = p.join(dataDir, 'node.sqlite3');
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA foreign_keys=ON;');
    db.execute('CREATE TABLE IF NOT EXISTS meta('
        'k TEXT PRIMARY KEY, v TEXT NOT NULL);');
    db.execute('CREATE TABLE IF NOT EXISTS devices('
        'device_id TEXT PRIMARY KEY,'
        'name TEXT NOT NULL,'
        'kind TEXT NOT NULL,' // device（原生节点，Ed25519）| web（浏览器，令牌）
        'pub_key TEXT,' // kind=device 时必填
        'token_hash TEXT,' // kind=web 时必填
        'added_at TEXT NOT NULL,'
        'revoked INTEGER NOT NULL DEFAULT 0);');
    db.execute('CREATE TABLE IF NOT EXISTS progress('
        'item_key TEXT PRIMARY KEY,' // 文件路径或 URL
        'title TEXT,'
        'position_ms INTEGER NOT NULL,'
        'duration_ms INTEGER NOT NULL,'
        'updated_hlc TEXT NOT NULL);');
    return NodeStore._(db, dbPath);
  }

  String? getMeta(String key) {
    final rows = _db.select('SELECT v FROM meta WHERE k = ?;', [key]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  void setMeta(String key, String value) {
    _db.execute('INSERT INTO meta(k, v) VALUES(?, ?) '
        'ON CONFLICT(k) DO UPDATE SET v = excluded.v;', [key, value]);
  }

  void upsertDevice(DeviceRecord record) {
    _db.execute(
      'INSERT INTO devices(device_id, name, kind, pub_key, token_hash, added_at, revoked) '
      'VALUES(?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(device_id) DO UPDATE SET '
      'name = excluded.name, pub_key = COALESCE(excluded.pub_key, pub_key), '
      'token_hash = COALESCE(excluded.token_hash, token_hash), revoked = excluded.revoked;',
      [
        record.deviceId,
        record.name,
        record.kind,
        record.pubKey,
        record.tokenHash,
        record.addedAt.toIso8601String(),
        record.revoked ? 1 : 0,
      ],
    );
  }

  DeviceRecord? deviceById(String deviceId) {
    final rows = _db.select('SELECT * FROM devices WHERE device_id = ?;', [deviceId]);
    return rows.isEmpty ? null : _deviceFromRow(rows.first);
  }

  DeviceRecord? deviceByTokenHash(String tokenHash) {
    final rows = _db.select(
      'SELECT * FROM devices WHERE token_hash = ? AND revoked = 0;',
      [tokenHash],
    );
    return rows.isEmpty ? null : _deviceFromRow(rows.first);
  }

  List<DeviceRecord> listDevices() =>
      _db.select('SELECT * FROM devices ORDER BY added_at;').map(_deviceFromRow).toList();

  void revokeDevice(String deviceId) {
    _db.execute('UPDATE devices SET revoked = 1 WHERE device_id = ?;', [deviceId]);
  }

  /// 仅当新记录的 hlc 更新时写入（M1 对等归集沿用同一函数语义）。
  /// HLC 编码保证字典序==时间序，可直接字符串比较。
  void saveProgress({
    required String itemKey,
    required String? title,
    required int positionMs,
    required int durationMs,
    required String updatedHlc,
  }) {
    final rows = _db.select('SELECT updated_hlc FROM progress WHERE item_key = ?;', [itemKey]);
    if (rows.isNotEmpty) {
      final existing = rows.first['updated_hlc'] as String;
      if (updatedHlc.compareTo(existing) <= 0) return;
      _db.execute(
        'UPDATE progress SET title = ?, position_ms = ?, duration_ms = ?, updated_hlc = ? '
        'WHERE item_key = ?;',
        [title, positionMs, durationMs, updatedHlc, itemKey],
      );
      return;
    }
    _db.execute(
      'INSERT INTO progress(item_key, title, position_ms, duration_ms, updated_hlc) '
      'VALUES(?, ?, ?, ?, ?);',
      [itemKey, title, positionMs, durationMs, updatedHlc],
    );
  }

  ProgressRecord? progressOf(String itemKey) {
    final rows = _db.select('SELECT * FROM progress WHERE item_key = ?;', [itemKey]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ProgressRecord(
      itemKey: row['item_key'] as String,
      title: row['title'] as String?,
      positionMs: row['position_ms'] as int,
      durationMs: row['duration_ms'] as int,
      updatedHlc: row['updated_hlc'] as String,
    );
  }

  void close() => _db.close();

  DeviceRecord _deviceFromRow(Map<String, Object?> row) => DeviceRecord(
        deviceId: row['device_id'] as String,
        name: row['name'] as String,
        kind: row['kind'] as String,
        pubKey: row['pub_key'] as String?,
        tokenHash: row['token_hash'] as String?,
        addedAt: DateTime.parse(row['added_at'] as String),
        revoked: (row['revoked'] as int) == 1,
      );
}

class DeviceRecord {
  DeviceRecord({
    required this.deviceId,
    required this.name,
    required this.kind,
    this.pubKey,
    this.tokenHash,
    required this.addedAt,
    this.revoked = false,
  });

  final String deviceId;
  final String name;
  final String kind;
  final String? pubKey;
  final String? tokenHash;
  final DateTime addedAt;
  final bool revoked;
}

class ProgressRecord {
  ProgressRecord({
    required this.itemKey,
    required this.title,
    required this.positionMs,
    required this.durationMs,
    required this.updatedHlc,
  });

  final String itemKey;
  final String? title;
  final int positionMs;
  final int durationMs;
  final String updatedHlc;
}
