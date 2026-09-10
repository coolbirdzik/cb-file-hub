import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'ftp_client.dart';
import 'ftp_file_info.dart';

/// Uses the desktop TLS backend for FTPS, including orderly TLS shutdown and
/// session resumption. Credentials are passed over stdin, never command args.
class CurlFtpsClient extends FtpClient {
  final String host, username, password;
  final int port;
  final bool implicit;
  final String? trustedCertificatePath;
  final Set<Process> _processes = {};
  String _directory = '/';
  bool _connected = false;
  int _generation = 0;
  CurlFtpsClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.implicit,
    this.trustedCertificatePath,
  }) : super.plain(
         host: host,
         port: port,
         username: username,
         password: password,
       );
  @override
  bool get isConnected => _connected;
  @override
  String? get currentDirectory => _directory;
  static String quote(String value) {
    if (value.contains(RegExp(r'[\r\n\x00]'))) {
      throw ArgumentError('Invalid FTPS argument');
    }
    return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
  }

  String _path(String path) =>
      p.posix.normalize(p.posix.join(_directory, path));
  Future<Uint8List> _request(
    String path, {
    String? upload,
    List<String> commands = const [],
    bool noBody = false,
    void Function(int)? progress,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError('FTPS is available on desktop only.');
    }
    final generation = _generation;
    final url = Uri(
      scheme: implicit ? 'ftps' : 'ftp',
      host: host,
      port: port,
      // //path asks FTP servers for an absolute path rather than login-relative.
      pathSegments: [
        '',
        ..._path(path).split('/'),
        if (path.endsWith('/') && path != '/') '',
      ],
    );
    final config = <String>[
      'silent',
      'show-error',
      'ssl-reqd',
      'globoff',
      'connect-timeout = 15',
      'speed-time = 30',
      'speed-limit = 1',
      'proto = "=ftp,ftps"',
      'noproxy = "*"',
      'url = ${quote(url.toString())}',
      'user = ${quote('$username:$password')}',
      if (trustedCertificatePath != null)
        'cacert = ${quote(trustedCertificatePath!)}',
      if (upload != null) 'upload-file = ${quote(upload)}',
      if (noBody) 'head',
      for (final command in commands) 'quote = ${quote(command)}',
    ].join('\n');
    final executable = Platform.isWindows
        ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\curl.exe'
        : 'curl';
    final process = await Process.start(executable, [
      '--disable',
      '--config',
      '-',
    ], mode: ProcessStartMode.normal);
    if (generation != _generation) {
      process.kill();
      throw StateError('FTPS connection closed');
    }
    _processes.add(process);
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    final output = process.stdout.listen((chunk) {
      bytes.add(chunk);
      received += chunk.length;
      progress?.call(received);
    });
    final outputDone = output.asFuture<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      process.stdin.write(config);
      await process.stdin.close();
      final code = await process.exitCode;
      final message = await errors;
      await outputDone;
      if (code != 0) {
        final operation = upload != null
            ? 'upload'
            : commands.isNotEmpty
            ? commands.first.split(' ').first
            : 'read';
        throw StateError('FTPS $operation: ${message.trim()}');
      }
      return bytes.takeBytes();
    } finally {
      _processes.remove(process);
      await output.cancel();
    }
  }

  @override
  Future<bool> connect() async {
    await _request('/');
    _connected = true;
    return true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _generation++;
    for (final process in _processes.toList()) {
      process.kill();
    }
    _processes.clear();
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }

  @override
  Future<void> sendNoop() async {
    /* Connections are scoped to each operation. */
  }
  @override
  Future<List<FtpFileInfo>> listDirectory([String? path]) async {
    final directory = _path(path ?? _directory);
    final data = await _request(
      directory.endsWith('/') ? directory : '$directory/',
    );
    return FtpFileInfo.parseDirectoryListing(
      utf8.decode(data, allowMalformed: true),
      directory,
    );
  }

  @override
  Future<bool> changeDirectory(String path) async {
    await listDirectory(path);
    _directory = _path(path);
    return true;
  }

  Future<bool> _commands(List<String> commands) async {
    await _request('/', commands: commands, noBody: true);
    return true;
  }

  @override
  Future<bool> createDirectory(String dirName) =>
      _commands(['MKD ${_path(dirName)}']);
  @override
  Future<bool> deleteDirectory(String dirName) =>
      _commands(['RMD ${_path(dirName)}']);
  @override
  Future<bool> deleteFile(String fileName) =>
      _commands(['DELE ${_path(fileName)}']);
  @override
  Future<bool> rename(String oldName, String newName) =>
      _commands(['RNFR ${_path(oldName)}', 'RNTO ${_path(newName)}']);
  @override
  Future<Uint8List?> downloadFile(String remotePath) => _request(remotePath);
  @override
  Future<Uint8List?> downloadFileWithProgress(
    String remotePath,
    void Function(int) onProgress,
  ) => _request(remotePath, progress: onProgress);
  @override
  Future<bool> uploadFile(String localPath, String remotePath) async {
    await _request(remotePath, upload: File(localPath).absolute.path);
    return true;
  }

  @override
  Future<bool> uploadFileWithProgress(
    String localPath,
    String remotePath,
    void Function(int) onProgress,
  ) async {
    await uploadFile(localPath, remotePath);
    onProgress(await File(localPath).length());
    return true;
  }

  @override
  Future<bool> uploadData(Uint8List data, String remotePath) async {
    final temp = await Directory.systemTemp.createTemp('cb-ftps-upload-');
    try {
      final file = File('${temp.path}/data');
      await file.writeAsBytes(data);
      return await uploadFile(file.path, remotePath);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  @override
  Future<bool> goToParentDirectory() =>
      changeDirectory(p.posix.dirname(_directory));
  @override
  Future<bool> setPassiveMode(bool usePassive) async => true;
  @override
  Future<bool> togglePassiveMode() async => true;
}
