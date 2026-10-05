import 'dart:io';

import 'package:node_core/src/library.dart';
import 'package:node_core/src/sources.dart';
import 'package:node_core/src/stream_signer.dart';
import 'package:node_core/src/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('StreamSigner', () {
    final signer = StreamSigner('test-secret');

    test('sign → verify 往返', () {
      final token = signer.sign(sourceId: 'src1', path: 'dir/a.mkv');
      final verified = signer.verify(token);
      expect(verified, isNotNull);
      expect(verified!.sourceId, 'src1');
      expect(verified.path, 'dir/a.mkv');
    });

    test('过期令牌拒绝', () {
      final token = signer.sign(sourceId: 's', path: 'p', ttl: const Duration(milliseconds: -1));
      expect(signer.verify(token), isNull);
    });

    test('篡改令牌拒绝', () {
      final token = signer.sign(sourceId: 's', path: 'p');
      final tampered = '${token}x';
      expect(signer.verify(tampered), isNull);
      expect(signer.verify(token.toUpperCase().replaceRange(0, 1, 'Z')), isNull);
    });
  });

  group('Library', () {
    late Directory tempDir;
    late Library library;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('omniplay-lib-');
      Directory('${tempDir.path}/剧集').createSync();
      File('${tempDir.path}/剧集/a.mkv').writeAsBytesSync(List.filled(64, 1));
      File('${tempDir.path}/b.mp4').writeAsBytesSync(List.filled(32, 2));
      File('${tempDir.path}/.hidden').writeAsStringSync('x');
      library = Library([FolderSource(tempDir.path)]);
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('sources 以根路径哈希为 id', () {
      final sources = library.sources;
      expect(sources.length, 1);
      expect(sources.first.name, p.basename(tempDir.path));
      expect(sources.first.sourceId, isNotEmpty);
    });

    test('browse 目录优先、隐藏文件过滤、相对路径正确', () async {
      final source = library.sources.first;
      final entries = await library.browse(sourceId: source.sourceId, dirPath: '');
      expect(entries.map((e) => e.name), ['剧集', 'b.mp4']);
      expect(entries.first.isDir, isTrue);

      final sub = await library.browse(sourceId: source.sourceId, dirPath: '剧集');
      expect(sub.single.name, 'a.mkv');
      expect(sub.single.sizeBytes, 64);
    });

    test('路径越界被拒绝', () async {
      final source = library.sources.first;
      await expectLater(
        library.browse(sourceId: source.sourceId, dirPath: '../..'),
        throwsArgumentError,
      );
      await expectLater(
        library.resolveStream(sourceId: source.sourceId, path: '../../etc/passwd'),
        throwsArgumentError,
      );
    });

    test('resolveStream 返回本机文件流描述', () async {
      final source = library.sources.first;
      final ref = await library.resolveStream(sourceId: source.sourceId, path: 'b.mp4');
      expect(ref.kind, 'local');
      expect(File(ref.localPath!).existsSync(), isTrue);
    });
  });

  group('utils', () {
    test('detectLanAddress 回退不抛异常', () async {
      final address = await detectLanAddress();
      expect(address, isNotEmpty);
    });
  });
}
