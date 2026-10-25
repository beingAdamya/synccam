import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The installed app version (from pubspec `version:`), loaded at startup.
class AppVersion {
  static String current = '0.0.0';

  static Future<void> load() async {
    try {
      current = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
  }
}

/// Minimal semantic version: `v1.2.3`, `1.2.3`, `1.2.3-beta.1`.
class SemVer implements Comparable<SemVer> {
  SemVer(this.major, this.minor, this.patch, [this.pre = '']);

  final int major, minor, patch;
  final String pre;

  static final _re = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?');

  static SemVer? tryParse(String? s) {
    final m = _re.firstMatch(s?.trim() ?? '');
    if (m == null) return null;
    return SemVer(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4] ?? '');
  }

  @override
  int compareTo(SemVer o) {
    for (final (a, b) in [(major, o.major), (minor, o.minor), (patch, o.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    // A pre-release (1.2.0-beta) sorts before its release (1.2.0).
    if (pre.isEmpty != o.pre.isEmpty) return pre.isEmpty ? 1 : -1;
    return pre.compareTo(o.pre);
  }

  bool operator >(SemVer o) => compareTo(o) > 0;

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-$pre'}';
}

class ReleaseInfo {
  ReleaseInfo({
    required this.tag,
    required this.version,
    required this.name,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
    this.ipaUrl,
  });

  final String tag;
  final SemVer version;
  final String name;
  final String notes;
  final String pageUrl;
  final String? apkUrl;
  final String? ipaUrl;
}

/// Checks the public GitHub Releases of this repo for a newer version.
///
/// Releases are created by the `release` job in .github/workflows/build.yml
/// whenever a `v*` tag is pushed. Pre-releases count, since every build so
/// far is marked as one.
class UpdateChecker {
  static const repo = 'beingAdamya/synccam';
  static const _cacheKey = 'update.cache';
  static const _cacheAtKey = 'update.cacheAt';
  static const _skipKey = 'update.skip';

  /// Unauthenticated GitHub API calls are limited to 60 an hour per IP, and a
  /// whole rig on one hotspot shares an IP, so reuse a recent answer.
  static const cacheFor = Duration(hours: 1);

  /// Pure selection logic: the newest non-draft release above [current].
  static ReleaseInfo? pickNewest(List<dynamic> releases, String current) {
    final installed = SemVer.tryParse(current);
    if (installed == null) return null;
    ReleaseInfo? best;
    for (final r in releases.whereType<Map<String, dynamic>>()) {
      if (r['draft'] == true) continue;
      final tag = r['tag_name'] as String? ?? '';
      final v = SemVer.tryParse(tag);
      if (v == null || !(v > installed)) continue;
      if (best != null && !(v > best.version)) continue;
      String? asset(String suffix) {
        for (final a in (r['assets'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
          final name = a['name'] as String? ?? '';
          if (name.endsWith(suffix)) return a['browser_download_url'] as String?;
        }
        return null;
      }

      best = ReleaseInfo(
        tag: tag,
        version: v,
        name: r['name'] as String? ?? tag,
        notes: r['body'] as String? ?? '',
        pageUrl: r['html_url'] as String? ?? 'https://github.com/$repo/releases/tag/$tag',
        apkUrl: asset('.apk'),
        ipaUrl: asset('.ipa'),
      );
    }
    return best;
  }

  /// Returns a newer release, or null if up to date, skipped, or offline.
  static Future<ReleaseInfo?> check() async {
    final prefs = await SharedPreferences.getInstance();
    var body = prefs.getString(_cacheKey);
    final at = prefs.getInt(_cacheAtKey) ?? 0;
    final fresh = DateTime.now().millisecondsSinceEpoch - at < cacheFor.inMilliseconds;
    if (body == null || !fresh) {
      final fetched = await _fetch();
      if (fetched != null) {
        body = fetched;
        await prefs.setString(_cacheKey, fetched);
        await prefs.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
      }
    }
    if (body == null) return null;
    try {
      final newest = pickNewest(jsonDecode(body) as List<dynamic>, AppVersion.current);
      if (newest == null || prefs.getString(_skipKey) == newest.tag) return null;
      return newest;
    } catch (_) {
      return null;
    }
  }

  static Future<void> skip(ReleaseInfo r) async =>
      (await SharedPreferences.getInstance()).setString(_skipKey, r.tag);

  static Future<String?> _fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.https('api.github.com', '/repos/$repo/releases', {'per_page': '10'}));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'SyncCam/${AppVersion.current}');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final text = await res.transform(utf8.decoder).join();
      return res.statusCode == 200 ? text : null;
    } catch (_) {
      // Offline or on a hotspot with no internet: that's normal for a rig.
      return null;
    } finally {
      client.close();
    }
  }
}
