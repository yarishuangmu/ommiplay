/// HLC（Hybrid Logical Clock，混合逻辑时钟）。
///
/// 字符串编码 `"<phys 15位零填充>.<counter 6位零填充>.<nodeId>"`，
/// 保证**字典序 == 时间序**，且物理时钟偏移不影响合并次序（风险 R10）。
class Hlc implements Comparable<Hlc> {
  Hlc(this.physMs, this.counter, this.nodeId);

  final int physMs;
  final int counter;
  final String nodeId;

  static Hlc now(String nodeId) => Hlc(DateTime.now().millisecondsSinceEpoch, 0, nodeId);

  static Hlc parse(String encoded) {
    final parts = encoded.split('.');
    if (parts.length < 3) throw FormatException('非法 HLC：$encoded');
    return Hlc(int.parse(parts[0]), int.parse(parts[1]), parts.skip(2).join('.'));
  }

  Hlc copyWith({int? physMs, int? counter}) =>
      Hlc(physMs ?? this.physMs, counter ?? this.counter, nodeId);

  /// 本地事件后调用：物理时间前进时清零计数器，否则计数器 +1。
  Hlc tick({DateTime? nowOverride}) {
    final nowMs = (nowOverride ?? DateTime.now()).millisecondsSinceEpoch;
    if (nowMs > physMs) return Hlc(nowMs, 0, nodeId);
    return Hlc(physMs, counter + 1, nodeId);
  }

  /// 收到远端事件后调用：保证新时间戳 > 双方已知最大值。
  Hlc receive(Hlc remote, {DateTime? nowOverride}) {
    final nowMs = (nowOverride ?? DateTime.now()).millisecondsSinceEpoch;
    final maxPhys = [nowMs, physMs, remote.physMs].reduce((a, b) => a > b ? a : b);
    if (maxPhys == physMs && maxPhys == remote.physMs) {
      return Hlc(maxPhys, [counter, remote.counter].reduce((a, b) => a > b ? a : b) + 1, nodeId);
    }
    if (maxPhys == physMs) return Hlc(maxPhys, counter + 1, nodeId);
    if (maxPhys == remote.physMs) return Hlc(maxPhys, remote.counter + 1, nodeId);
    return Hlc(maxPhys, 0, nodeId);
  }

  @override
  int compareTo(Hlc other) {
    if (physMs != other.physMs) return physMs.compareTo(other.physMs);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) => other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(physMs, counter, nodeId);

  @override
  String toString() =>
      '${physMs.toString().padLeft(15, '0')}.${counter.toString().padLeft(6, '0')}.$nodeId';
}

/// 每节点持有 single 实例；tick()/receive() 返回的新时间戳严格单调。
/// [now] 可注入（测试用），默认取系统时间。
class HlcClock {
  HlcClock(String nodeId, {DateTime Function()? now})
      : _nodeId = nodeId,
        _now = now ?? DateTime.now;

  final String _nodeId;
  final DateTime Function() _now;

  /// 惰性初始化：首次事件才取时钟，避免构造时刻污染测试注入的时间线。
  Hlc? _last;

  String get nodeId => _nodeId;

  Hlc get current => _last ?? Hlc(_now().millisecondsSinceEpoch, 0, _nodeId);

  String tick() {
    final nowMs = _now().millisecondsSinceEpoch;
    final last = _last;
    _last = last == null
        ? Hlc(nowMs, 0, _nodeId)
        : nowMs > last.physMs
            ? Hlc(nowMs, 0, _nodeId)
            : Hlc(last.physMs, last.counter + 1, _nodeId);
    return _last!.toString();
  }

  String receive(String remoteEncoded) {
    final remote = Hlc.parse(remoteEncoded);
    final nowMs = _now().millisecondsSinceEpoch;
    final last = _last;
    _last = last == null
        ? Hlc(nowMs > remote.physMs ? nowMs : remote.physMs, remote.counter + 1, _nodeId)
        : (() {
            final maxPhys = [nowMs, last.physMs, remote.physMs].reduce((a, b) => a > b ? a : b);
            if (maxPhys == last.physMs && maxPhys == remote.physMs) {
              return Hlc(maxPhys, last.counter > remote.counter ? last.counter + 1 : remote.counter + 1, _nodeId);
            }
            if (maxPhys == last.physMs) return Hlc(maxPhys, last.counter + 1, _nodeId);
            if (maxPhys == remote.physMs) return Hlc(maxPhys, remote.counter + 1, _nodeId);
            return Hlc(maxPhys, 0, _nodeId);
          })();
    return _last!.toString();
  }
}
