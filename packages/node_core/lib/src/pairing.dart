import 'dart:math';

/// 家庭配对（A2）：节点侧 PIN 的生成与校验。
/// PIN 5 分钟有效；原生设备配对（Ed25519 公钥互换）与 Web 配对（随机令牌）共用。
class PairingService {
  static final Random _random = Random.secure();

  String? _pin;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 生成新 PIN（6 位数字），5 分钟有效。播放器 UI 展示给用户。
  String newPin() {
    final pin = List.generate(6, (_) => _random.nextInt(10)).join();
    _pin = pin;
    _expiresAt = DateTime.now().add(const Duration(minutes: 5));
    return pin;
  }

  /// 当前有效 PIN（未过期则原样返回，过期则 null）。
  String? get currentPin {
    if (_pin == null) return null;
    if (DateTime.now().isAfter(_expiresAt)) {
      _pin = null;
      return null;
    }
    return _pin;
  }

  bool validatePin(String pin) {
    final current = currentPin;
    if (current == null) return false;
    if (current != pin) return false;
    // 一次性：配对成功即作废。
    _pin = null;
    return true;
  }

  // —— 扫码配对（M0-β）：QR 里携带一次性加入令牌，效果等同 PIN ——
  String? _joinToken;
  DateTime _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  String newJoinToken() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    _joinToken = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 5));
    return _joinToken!;
  }

  String? get currentJoinToken {
    if (_joinToken == null) return null;
    if (DateTime.now().isAfter(_tokenExpiresAt)) {
      _joinToken = null;
      return null;
    }
    return _joinToken;
  }

  bool validateJoinToken(String token) {
    if (currentJoinToken == null || currentJoinToken != token) return false;
    _joinToken = null;
    return true;
  }
}
