import 'package:flutter_test/flutter_test.dart';
import 'package:synccam/core/updates.dart';

Map<String, dynamic> _release(String tag, {bool draft = false}) => {
      'tag_name': tag,
      'name': 'SyncCam $tag',
      'draft': draft,
      'prerelease': true,
      'body': 'notes for $tag',
      'html_url': 'https://github.com/x/y/releases/tag/$tag',
      'assets': [
        {'name': 'SyncCam-$tag-android.apk', 'browser_download_url': 'https://dl/$tag.apk'},
        {'name': 'SyncCam-$tag-ios-unsigned.ipa', 'browser_download_url': 'https://dl/$tag.ipa'},
      ],
    };

void main() {
  test('semver ordering', () {
    SemVer v(String s) => SemVer.tryParse(s)!;
    expect(v('v0.2.0') > v('0.1.9'), isTrue);
    expect(v('1.0.0') > v('0.99.99'), isTrue);
    expect(v('0.10.0') > v('0.9.0'), isTrue, reason: 'numeric, not string, compare');
    expect(v('1.2.0') > v('1.2.0-beta.1'), isTrue);
    expect(v('1.2.0').compareTo(v('v1.2.0')), 0);
    expect(SemVer.tryParse('latest'), isNull);
  });

  test('picks the newest non-draft release above the installed version', () {
    final list = [_release('v0.3.0', draft: true), _release('v0.2.1'), _release('v0.2.0'), _release('v0.1.0')];
    final r = UpdateChecker.pickNewest(list, '0.1.0')!;
    expect(r.tag, 'v0.2.1');
    expect(r.apkUrl, 'https://dl/v0.2.1.apk');
    expect(r.ipaUrl, 'https://dl/v0.2.1.ipa');
    expect(r.notes, 'notes for v0.2.1');
  });

  test('no update when installed is newest or input is junk', () {
    expect(UpdateChecker.pickNewest([_release('v0.2.0'), _release('v0.1.0')], '0.2.0'), isNull);
    expect(UpdateChecker.pickNewest([_release('nightly')], '0.1.0'), isNull);
    expect(UpdateChecker.pickNewest(['oops', 42], '0.1.0'), isNull);
  });
}
