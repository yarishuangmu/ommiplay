import 'package:node_core/src/hlc.dart';
import 'package:test/test.dart';

void main() {
  test('tick 严格单调（同毫秒走计数器，跨毫秒清零）', () {
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final clock = HlcClock('node-a', now: () => now);

    final a = clock.tick(); // (1000, 0) 首个事件
    final b = clock.tick(); // (1000, 1) 同毫秒 → 计数器递增
    now = now.add(const Duration(milliseconds: 1));
    final c = clock.tick(); // (1001, 0) 跨毫秒 → 计数器清零

    expect(Hlc.parse(a) < Hlc.parse(b), isTrue);
    expect(Hlc.parse(b) < Hlc.parse(c), isTrue);
    expect(Hlc.parse(a).counter, 0);
    expect(Hlc.parse(b).counter, 1);
    expect(Hlc.parse(c).counter, 0);
    expect(Hlc.parse(c).physMs, 1001);
  });

  test('receive 保证本地新时间戳大于双方已知最大值（含时钟偏移）', () {
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final clock = HlcClock('node-a', now: () => now);
    final localBase = Hlc.parse(clock.tick());

    // 远端时钟"超前"本机 1 小时（偏移场景）。
    final remote = Hlc(1000 + 3600 * 1000, 5, 'node-b');

    final merged = Hlc.parse(clock.receive(remote.toString()));
    expect(merged.physMs, remote.physMs);
    expect(merged.counter, 6);
    expect(merged > localBase, isTrue);
    expect(merged > remote, isTrue);

    // 本机物理时间落后时，后续 tick 仍大于 merge 结果。
    final next = Hlc.parse(clock.tick());
    expect(next > merged, isTrue);
  });

  test('字符串编码字典序 == 时间序（跨节点、跨计数器）', () {
    final samples = <String>[
      Hlc(1000, 0, 'node-a').toString(),
      Hlc(1000, 1, 'node-a').toString(),
      Hlc(1000, 999999, 'node-b').toString(),
      Hlc(2000, 0, 'zzz').toString(),
      Hlc(15000000000000, 3, 'x').toString(),
    ];
    final sorted = List.of(samples)..sort();
    expect(sorted, samples, reason: '样本本身即按时间升序构造');
  });

  test('parse 往返', () {
    final original = Hlc(1699999999999, 42, 'device-abc');
    expect(Hlc.parse(original.toString()), original);
  });
}
