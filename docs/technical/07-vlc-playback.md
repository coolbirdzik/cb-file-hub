# VLC playback

Local files, HTTP streams, SMB, desktop PiP and the frame picker use
`cb_file_manager/lib/services/media/vlc_playback.dart`. Media Kit and the old
`flutter_vlc_player` fallback are no longer dependencies.

The plugin is vendored at `cb_file_manager/third_party/vlc_player` from pub.dev
2.1.2. Its Windows CMake pin is updated from VLC 3.0.21 to **3.0.23**, including
VideoLAN's published SHA-256. CMake fetches the runtime on a clean build and
bundles the VLC DLLs and plugins; users do not need a separate VLC installation.
Upstream provenance and patches are recorded in `PATCHES.md` beside its license.
Android uses the plugin's libVLC 3.7.0 dependency and requires Android 10/API 29.
Linux needs system `libvlc-dev` and `vlc`; Apple builds use VLCKit/MobileVLCKit.

The shared backend queues commands until the native view is attached and media
is seekable. Loading indicators must overlay the existing native surface:
removing that widget while VLC buffers disposes playback. Native VLC snapshots
are used for the frame picker and screenshot action.

Default playback fit is `contain`: scale up or down to the largest image that
fits the window, preserving the original aspect ratio and the complete frame.
Different window/video ratios leave letterbox or pillarbox space. This applies
to local and SMB playback and desktop PiP.

The streaming player's overlay Stack uses `StackFit.expand`. Keep its viewport
independent of control visibility: desktop gesture/seek overlays return empty
widgets when inactive, which otherwise collapse the positioned video to zero
size as soon as the controls auto-hide (including after an SMB seek).

SMB URLs retain their encoded paths. The source resolver removes userinfo from
the MRL and supplies `smb-user`, `smb-pwd` and `smb-domain` as per-media options.
Windows UNC paths become properly escaped file URIs. PiP preserves the original
source instead of stripping SMB credentials by converting it to a UNC path.
Filesystem browsing still uses the existing SMB service/FFI plugin.

Run from `cb_file_manager/`:

```powershell
flutter test test/services/media/vlc_playback_test.dart
flutter test integration_test/vlc_playback_e2e_test.dart -d windows --dart-define=CB_E2E=true
```

To include real SMB playback/seek/snapshot validation, pass
`--dart-define=CB_E2E_SMB_URL=smb://host/share/sample.mp4` for an accessible test
share. The default run skips SMB when no source is supplied. Avoid putting
credentials in checked-in test commands or logs.

The visibility regression checks the Flutter surface dimensions and decoded
pixels before/after scrubbing and after controls auto-hide. Without an SMB URL,
it uses the local fixture as a file URL to exercise the same streaming layout.
