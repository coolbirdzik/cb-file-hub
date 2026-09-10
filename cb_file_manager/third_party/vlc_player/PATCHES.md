# Local VLC runtime pin

Source: https://pub.dev/packages/vlc_player/versions/2.1.2

Vendored from the unmodified pub.dev 2.1.2 archive, retaining its license and
third-party notices. Windows CMake now downloads VLC **3.0.23** instead of
3.0.21, with the SHA-256 published at:
https://download.videolan.org/pub/videolan/vlc/3.0.23/win64/vlc-3.0.23-win64.7z.sha256

The runtime is fetched during CMake configuration and is not committed. Keep
this patch when updating the plugin; do not patch the user's global Pub cache.

Windows packaging also includes the VLC runtime license and plugin notices.

Desktop texture layout gives `FittedBox` the full viewport constraints so the
default `contain` fit also enlarges small videos, preserving aspect ratio and
the complete frame while resizing the window.
