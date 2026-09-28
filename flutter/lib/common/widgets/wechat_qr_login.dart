import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:http/http.dart' as http;

import '../../common.dart';
import '../../models/platform_model.dart';

/// 微信扫码登录（对接 ERP 后端 /api/wechat/login/*）。
/// 取码 → 展示 → 轮询状态；CONFIRMED 后由 onLoginSuccess 复用
/// 登录框既有的 token 持久化路径。
class WechatQrLoginWidget extends StatefulWidget {
  final Future<void> Function(LoginResponse resp) onLoginSuccess;

  const WechatQrLoginWidget({Key? key, required this.onLoginSuccess})
      : super(key: key);

  @override
  State<WechatQrLoginWidget> createState() => _WechatQrLoginWidgetState();
}

class _WechatQrLoginWidgetState extends State<WechatQrLoginWidget> {
  static const _pollInterval = Duration(milliseconds: 1500);

  bool _expanded = false;
  bool _loading = false;
  bool _done = false;
  String? _errorMsg;
  String? _sceneId;
  String? _qrcodeBase64;
  String? _statusText;
  int? _expireSeconds;
  int _leftSeconds = 0;
  Timer? _pollTimer;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded && _sceneId == null) {
      _fetchQrcode();
    } else if (!_expanded) {
      _stopTimers();
    }
  }

  Future<String?> _apiServer() async => await bind.mainGetApiServer();

  Future<void> _fetchQrcode() async {
    if (_loading || _done) return;
    setState(() {
      _loading = true;
      _errorMsg = null;
      _statusText = null;
    });
    _stopTimers();
    try {
      final url = await _apiServer();
      final resp = await http.get(Uri.parse('$url/api/wechat/login/qrcode'));
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      final data = jsonDecode(resp.body);
      if (data['status'] == 'ERROR') {
        throw data['message'] ?? translate('Failed');
      }
      if (data['scene_id'] == null || data['qrcode_base64'] == null) {
        throw 'bad qrcode response';
      }
      if (!mounted) return;
      setState(() {
        _sceneId = data['scene_id'];
        _qrcodeBase64 = data['qrcode_base64'];
        _expireSeconds = data['expire_seconds'] ?? 300;
        _leftSeconds = _expireSeconds ?? 300;
        _statusText = translate('Waiting for scan...');
        _loading = false;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString();
      });
    }
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollStatus());
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_leftSeconds <= 0) {
        _stopTimers();
        if (mounted) {
          setState(() => _statusText = translate('QR code expired, tap to refresh'));
        }
        return;
      }
      if (mounted) setState(() => _leftSeconds -= 1);
    });
  }

  Future<void> _pollStatus() async {
    if (_sceneId == null || _done) return;
    try {
      final url = await _apiServer();
      final resp = await http
          .get(Uri.parse('$url/api/wechat/login/status?scene_id=$_sceneId'));
      if (resp.statusCode != 200) {
        return; // 瞬时错误，等待下轮
      }
      final data = jsonDecode(resp.body);
      final status = data['status']?.toString() ?? '';
      if (!mounted) return;
      switch (status) {
        case 'SCANNED':
          setState(() => _statusText =
              translate('Scanned, please confirm on your phone...'));
          break;
        case 'EXPIRED':
          _stopTimers();
          setState(() => _statusText =
              translate('QR code expired, tap to refresh'));
          break;
        case 'CONFIRMED':
          _stopTimers();
          if (data['access_token'] != null) {
            _done = true;
            widget.onLoginSuccess(LoginResponse(
                type: HttpType.kAuthResTypeToken,
                access_token: data['access_token'],
                user: data['user'] != null
                    ? UserPayload.fromJson(data['user'])
                    : null));
          } else {
            setState(() {
              _statusText = data['message'] ?? translate('Failed');
              _sceneId = null;
            });
          }
          break;
        case 'ERROR':
          _stopTimers();
          setState(() {
            _statusText = data['message'] ?? translate('Failed');
            _sceneId = null;
          });
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('wechat login status poll failed: $e');
    }
  }

  Widget _qrImage() {
    final raw = _qrcodeBase64 ?? '';
    const prefix = 'data:image/png;base64,';
    final base64Data =
        raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
    try {
      return Image.memory(base64Decode(base64Data), width: 180, height: 180);
    } catch (_) {
      return const SizedBox(
          width: 180, height: 180, child: Center(child: Text('bad image')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8.0),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
          ),
          onPressed: _done ? null : _toggle,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_expanded ? Icons.expand_less : Icons.qr_code, size: 18),
            const SizedBox(width: 4),
            Text(translate('WeChat scan login')),
          ]),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(bottom: 8.0),
            child: _loading
                ? const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()))
                : _errorMsg != null
                    ? Column(children: [
                        Text(_errorMsg!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.red)),
                        TextButton(
                          onPressed: _fetchQrcode,
                          child: Text(translate('Retry')),
                        ),
                      ])
                    : Column(children: [
                        GestureDetector(
                          onTap: _fetchQrcode,
                          child: _qrImage(),
                        ),
                        const SizedBox(height: 4),
                        Text(_statusText ?? '',
                            style: const TextStyle(fontSize: 12)),
                      ]),
          ),
      ],
    );
  }
}
