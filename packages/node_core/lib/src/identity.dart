import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'store.dart';

/// 节点身份：Ed25519 设备密钥对 + deviceId（公钥 SHA-256 前 16 hex）。
/// 密钥持久化在 store.meta 中，重装应用不换身份。
class NodeIdentity {
  NodeIdentity._(this.deviceId, this._keyPair, this._publicKeyBytes);

  static final Ed25519 _algo = Ed25519();

  final String deviceId;
  final SimpleKeyPair _keyPair;
  final List<int> _publicKeyBytes;

  String get publicKeyBase64 => base64Encode(_publicKeyBytes);

  /// 从 store 加载或首次生成密钥对。
  static Future<NodeIdentity> loadOrCreate(NodeStore store) async {
    final storedPriv = store.getMeta('device_priv_key');
    final storedPub = store.getMeta('device_pub_key');
    if (storedPriv != null && storedPub != null) {
      final priv = base64Decode(storedPriv);
      final pub = base64Decode(storedPub);
      final keyPair = SimpleKeyPairData(
        priv,
        publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      return NodeIdentity._(_deviceIdOf(pub), keyPair, pub);
    }

    final keyPair = await _algo.newKeyPair();
    final priv = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    store.setMeta('device_priv_key', base64Encode(priv));
    store.setMeta('device_pub_key', base64Encode(publicKey.bytes));
    return NodeIdentity._(
      _deviceIdOf(publicKey.bytes),
      keyPair,
      publicKey.bytes,
    );
  }

  static String _deviceIdOf(List<int> publicKeyBytes) =>
      crypto.sha256.convert(publicKeyBytes).toString().substring(0, 16);

  /// 用设备私钥对文本签名，返回 base64 签名。
  Future<String> sign(String data) async {
    final signature = await _algo.sign(utf8.encode(data), keyPair: _keyPair);
    return base64Encode(signature.bytes);
  }

  /// 验证某设备（按公钥）对文本的签名。
  static Future<bool> verify({
    required String publicKeyBase64,
    required String data,
    required String signatureBase64,
  }) async {
    try {
      final signature = Signature(
        base64Decode(signatureBase64),
        publicKey: SimplePublicKey(base64Decode(publicKeyBase64), type: KeyPairType.ed25519),
      );
      return await _algo.verify(utf8.encode(data), signature: signature);
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}
