import 'dart:io';

import 'package:node_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late NodeStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('omniplay-store-');
    store = NodeStore.open(tempDir.path);
  });

  tearDown(() {
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  test('meta 读写与覆盖', () {
    expect(store.getMeta('none'), isNull);
    store.setMeta('k', 'v1');
    store.setMeta('k', 'v2');
    expect(store.getMeta('k'), 'v2');
  });

  test('设备记录 upsert 与吊销', () {
    store.upsertDevice(DeviceRecord(
      deviceId: 'dev-1',
      name: '手机',
      kind: 'device',
      pubKey: 'PUBKEY',
      addedAt: DateTime.now(),
    ));
    store.upsertDevice(DeviceRecord(
      deviceId: 'dev-1',
      name: '我的手机',
      kind: 'device',
      addedAt: DateTime.now(),
    ));
    // upsert 保留首次的公钥。
    final device = store.deviceById('dev-1')!;
    expect(device.name, '我的手机');
    expect(device.pubKey, 'PUBKEY');

    expect(store.deviceByTokenHash('nope'), isNull);
    store.revokeDevice('dev-1');
    expect(store.deviceById('dev-1')!.revoked, isTrue);
  });

  test('web 令牌按哈希查找', () {
    store.upsertDevice(DeviceRecord(
      deviceId: 'web-x',
      name: '浏览器',
      kind: 'web',
      tokenHash: 'HASH123',
      addedAt: DateTime.now(),
    ));
    expect(store.deviceByTokenHash('HASH123')!.deviceId, 'web-x');
    store.revokeDevice('web-x');
    expect(store.deviceByTokenHash('HASH123'), isNull);
  });

  test('进度按 HLC 字典序只增更新（合并语义的本地版）', () {
    String hlc(int phys, int counter, String node) =>
        '${phys.toString().padLeft(15, '0')}.${counter.toString().padLeft(6, '0')}.$node';

    store.saveProgress(
        itemKey: '/m/a.mkv', title: 'A', positionMs: 100, durationMs: 1000, updatedHlc: hlc(1, 0, 'n1'));
    // 旧时间戳：不覆盖。
    store.saveProgress(
        itemKey: '/m/a.mkv', title: 'A', positionMs: 50, durationMs: 1000, updatedHlc: hlc(1, 0, 'n0'));
    expect(store.progressOf('/m/a.mkv')!.positionMs, 100);
    // 更新时间戳：覆盖（进度取最远由上层 max 保证，这里验证"只认更新"）。
    store.saveProgress(
        itemKey: '/m/a.mkv', title: 'A', positionMs: 800, durationMs: 1000, updatedHlc: hlc(2, 0, 'n0'));
    expect(store.progressOf('/m/a.mkv')!.positionMs, 800);
  });
}
