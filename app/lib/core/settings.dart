import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-device settings: the HQ server address (e.g. a Cloudflare tunnel URL),
/// this phone's facility name, and the HQ downlink cursor. Wiped by "Reset this device".
class Settings {
  static const _store = FlutterSecureStorage();
  static const _kUrl = 'hq_url', _kFacility = 'facility', _kCursor = 'hq_cursor';

  String hqUrl = '';
  String facility = '';
  int cursor = 0;

  static Future<Settings> load() async {
    final s = Settings();
    s.hqUrl = await _store.read(key: _kUrl) ?? '';
    s.facility = await _store.read(key: _kFacility) ?? '';
    s.cursor = int.tryParse(await _store.read(key: _kCursor) ?? '') ?? 0;
    return s;
  }

  Future<void> setHqUrl(String url) async {
    hqUrl = normaliseUrl(url);
    await _store.write(key: _kUrl, value: hqUrl);
  }

  Future<void> setFacility(String name) async {
    facility = name.trim();
    await _store.write(key: _kFacility, value: facility);
  }

  Future<void> setCursor(int c) async {
    cursor = c;
    await _store.write(key: _kCursor, value: '$c');
  }

  /// Accepts "abc.trycloudflare.com" or a full URL; drops trailing slashes.
  static String normaliseUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
