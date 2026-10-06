import 'package:node_core/src/plugin_manager.dart';
import 'package:test/test.dart';

void main() {
  group('UserScriptParser（GreaseMonkey v4 子集）', () {
    test('解析标准元数据', () {
      const src = '''
// ==UserScript==
// @name         iQiyi Boost
// @namespace    org.omniplay
// @version      0.1.0
// @match        https://www.iqiyi.com/*
// @run-at       document-start
// @description  demo
// ==/UserScript==
(function() { console.log('hi'); })();
''';
      final r = UserScriptParser.parse(src);
      expect(r.script.name, 'iQiyi Boost');
      expect(r.script.namespace, 'org.omniplay');
      expect(r.script.matches.single, 'https://www.iqiyi.com/*');
      expect(r.script.runAt, 'document-start');
      expect(r.script.code.contains("console.log('hi')"), isTrue);
      expect(r.warnings, isEmpty);
    });

    test('缺少 @match 给出提示但不抛', () {
      const src = '''
// ==UserScript==
// @name no match
// ==/UserScript==
noop;
''';
      final r = UserScriptParser.parse(src);
      expect(r.script.matches, isEmpty);
      expect(r.warnings.length, 1);
      expect(r.warnings.single, contains('@match'));
    });

    test('多行 @match', () {
      const src = '''
// ==UserScript==
// @name a
// @match https://a.com/*
// @match https://b.com/*
// ==/UserScript==
''';
      final r = UserScriptParser.parse(src);
      expect(r.script.matches, ['https://a.com/*', 'https://b.com/*']);
    });
  });
}