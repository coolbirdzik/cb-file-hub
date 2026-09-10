import 'package:cb_file_manager/services/media/vlc_playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SMB credentials with domain and punctuation become VLC options', () {
    final source = vlcMediaSource(
      'smb://DOMAIN%3Buser:p%40ss%3Aword%23%25@nas/share/My%20video%23.mp4',
    );
    expect(source.uri.toString(), 'smb://nas/share/My%20video%23.mp4');
    expect(source.uri.userInfo, isEmpty);
    expect(source.mediaOptions, [
      ':smb-domain=DOMAIN',
      ':smb-user=user',
      ':smb-pwd=p@ss:word#%',
    ]);
  });

  test('SMB keeps colons in passwords and accepts Windows domain names', () {
    final source = vlcMediaSource('smb://domain%5Cuser:a:b@nas/share/a.mp4');
    expect(source.mediaOptions, [
      ':smb-domain=domain',
      ':smb-user=user',
      ':smb-pwd=a:b',
    ]);
  });

  test(
    'UNC and local Windows paths preserve literal spaces and percent signs',
    () {
      for (final path in [
        r'\\server\share\Tiếng Việt #100%.mp4',
        r'L:\Video\a #100%.mp4',
      ]) {
        final source = vlcMediaSource(path);
        expect(source.uri.scheme, 'file');
        expect(source.uri.toFilePath(windows: true), path);
      }
    },
  );

  test('HTTP URLs retain their query and fragment', () {
    const url = 'https://host/video.mp4?token=a%2Bb#track';
    expect(vlcMediaSource(url).uri.toString(), url);
  });
}
