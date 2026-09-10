import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class LocalSshHost {
  final String alias, host, username;
  final int port;
  final List<String> identityFiles, unsupportedOptions;
  const LocalSshHost({
    required this.alias,
    required this.host,
    required this.username,
    this.port = 22,
    this.identityFiles = const [],
    this.unsupportedOptions = const [],
  });
}

class LocalSshKey {
  final String path;
  const LocalSshKey(this.path);
  String get name => p.basename(path);
}

class LocalSshSnapshot {
  final List<LocalSshHost> hosts;
  final List<LocalSshKey> keys;
  final List<String> warnings;
  const LocalSshSnapshot({
    this.hosts = const [],
    this.keys = const [],
    this.warnings = const [],
  });
}

/// Read-only discovery. Never invokes ssh, Match exec or ProxyCommand.
/// Private key contents are only read in full when the user chooses to import.
class LocalSshDiscovery {
  final String homeDirectory;
  final String username;
  LocalSshDiscovery({String? homeDirectory, String? username})
    : homeDirectory =
          homeDirectory ??
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '',
      username =
          username ??
          Platform.environment['USERNAME'] ??
          Platform.environment['USER'] ??
          '';

  Future<LocalSshSnapshot> scan() async {
    if (homeDirectory.isEmpty) return const LocalSshSnapshot();
    final sshDir = p.join(homeDirectory, '.ssh');
    final warnings = <String>[];
    final lines = <List<String>>[];
    final stack = <String>{};
    var filesRead = 0;

    Future<void> readConfig(String path, int depth) async {
      final normalized = p.normalize(p.absolute(path));
      if (depth > 8 || filesRead >= 32 || !stack.add(normalized)) {
        warnings.add('SSH config include limit: $path');
        return;
      }
      try {
        final file = File(path);
        if (!await file.exists()) return;
        filesRead++;
        if (await file.length() > 128 * 1024) {
          warnings.add('SSH config is too large: $path');
          return;
        }
        for (final line in const LineSplitter().convert(
          await file.readAsString(),
        )) {
          final tokens = tokenize(line);
          if (tokens.isEmpty) continue;
          if (tokens.first.toLowerCase() == 'include') {
            lines.add(const ['_include']);
            for (final pattern in tokens.skip(1)) {
              final expanded = _expandHome(pattern);
              final absolute = p.isAbsolute(expanded)
                  ? expanded
                  : p.join(sshDir, expanded);
              for (final included in await _glob(absolute)) {
                await readConfig(included, depth + 1);
              }
            }
            lines.add(const ['_endinclude']);
          } else {
            lines.add(tokens);
            if (tokens.first.toLowerCase() == 'match') {
              warnings.add('Conditional Match settings were skipped');
            }
          }
        }
      } on FileSystemException catch (e) {
        warnings.add('Cannot read SSH config: ${e.path}');
      } on FormatException {
        warnings.add('Cannot decode SSH config: $path');
      } finally {
        stack.remove(normalized);
      }
    }

    await readConfig(p.join(sshDir, 'config'), 0);
    final aliases = <String>{};
    for (final line in lines) {
      if (line.first.toLowerCase() == 'host') {
        aliases.addAll(
          line.skip(1).where((s) => !s.contains(RegExp(r'[!*?%]'))),
        );
      }
    }
    final hosts = <LocalSshHost>[];
    for (final alias in aliases) {
      var active = true;
      var skippedIncludeDepth = 0;
      final values = <String, String>{};
      final identities = <String>[];
      final unsupported = <String>{};
      for (final line in lines) {
        final directive = line.first.toLowerCase();
        final args = line.skip(1).toList();
        if (directive == '_include') {
          if (!active || skippedIncludeDepth > 0) skippedIncludeDepth++;
          continue;
        }
        if (directive == '_endinclude') {
          if (skippedIncludeDepth > 0) skippedIncludeDepth--;
          continue;
        }
        if (skippedIncludeDepth > 0) continue;
        if (directive == 'host') {
          active =
              args.any((v) => !v.startsWith('!') && _matches(v, alias)) &&
              !args.any(
                (v) => v.startsWith('!') && _matches(v.substring(1), alias),
              );
        } else if (directive == 'match') {
          // Conditional options cannot safely be inferred without OpenSSH.
          active = false;
        } else if (active && args.isNotEmpty) {
          if (directive == 'identityfile') {
            if (args.first != 'none') identities.add(args.first);
          } else if ([
            'hostname',
            'user',
            'port',
            'proxyjump',
            'proxycommand',
            'certificatefile',
          ].contains(directive)) {
            values.putIfAbsent(directive, () => args.first);
          }
        }
      }
      for (final option in ['proxyjump', 'proxycommand', 'certificatefile']) {
        if (values[option] != null && values[option] != 'none') {
          unsupported.add(option);
        }
      }
      final host = (values['hostname'] ?? alias).replaceAll('%h', alias);
      final user = values['user'] ?? username;
      final port = int.tryParse(values['port'] ?? '') ?? 22;
      hosts.add(
        LocalSshHost(
          alias: alias,
          host: host,
          username: user,
          port: port,
          identityFiles: identities
              .map(
                (v) => _expandHome(v).replaceAllMapped(
                  RegExp(r'%[%dhrp]'),
                  (m) => switch (m[0]) {
                    '%d' => homeDirectory,
                    '%h' => host,
                    '%r' => user,
                    '%p' => '$port',
                    _ => '%',
                  },
                ),
              )
              .map(
                (v) => p.isAbsolute(v)
                    ? p.normalize(v)
                    : p.normalize(p.join(homeDirectory, v)),
              )
              .toSet()
              .toList(),
          unsupportedOptions: unsupported.toList(),
        ),
      );
    }
    final candidates = <String>{
      for (final host in hosts) ...host.identityFiles,
    };
    try {
      if (await Directory(sshDir).exists()) {
        await for (final entry in Directory(sshDir).list(followLinks: false)) {
          if (entry is File) candidates.add(entry.path);
        }
      }
    } on FileSystemException {
      warnings.add('Cannot read $sshDir');
    }
    final keys = <LocalSshKey>[];
    for (final path in candidates.take(256)) {
      if (path.endsWith('.pub') || path.endsWith('.ppk')) continue;
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final header = ascii.decode(
          await file
              .openRead(0, 128)
              .fold<List<int>>([], (a, b) => a..addAll(b)),
          allowInvalid: true,
        );
        if (RegExp(
          r'-----BEGIN (OPENSSH|RSA|EC|PRIVATE|ENCRYPTED PRIVATE)( PRIVATE)? KEY-----',
        ).hasMatch(header)) {
          keys.add(LocalSshKey(path));
        }
      } on FileSystemException {
        // An unreadable key must not prevent discovering the remaining keys.
      }
    }
    hosts.sort((a, b) => a.alias.compareTo(b.alias));
    keys.sort((a, b) => a.name.compareTo(b.name));
    return LocalSshSnapshot(hosts: hosts, keys: keys, warnings: warnings);
  }

  String _expandHome(String value) => value == '~'
      ? homeDirectory
      : value.startsWith('~/') || value.startsWith('~\\')
      ? p.join(homeDirectory, value.substring(2))
      : value;

  static bool _matches(String pattern, String value) => RegExp(
    '^${pattern.split('').map((c) => c == '*'
        ? '.*'
        : c == '?'
        ? '.'
        : RegExp.escape(c)).join()}\$',
    caseSensitive: false,
  ).hasMatch(value);

  Future<List<String>> _glob(String pattern) async {
    if (!pattern.contains(RegExp(r'[*?]'))) return [pattern];
    final parent = p.dirname(pattern);
    final directories = parent.contains(RegExp(r'[*?]'))
        ? await _glob(parent)
        : [parent];
    final matches = <String>[];
    for (final directory in directories) {
      try {
        await for (final entry in Directory(
          directory,
        ).list(followLinks: false)) {
          if (_matches(p.basename(pattern), p.basename(entry.path))) {
            matches.add(entry.path);
          }
          if (matches.length >= 256) break;
        }
      } on FileSystemException {
        // Missing Include patterns are valid in OpenSSH.
      }
    }
    return matches..sort();
  }

  /// Handles quoted paths, comments and `Key=value`, preserving Windows paths.
  static List<String> tokenize(String line) {
    final result = <String>[];
    var token = StringBuffer();
    String? quote;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '#' && quote == null) break;
      if (c == '\\' &&
          i + 1 < line.length &&
          (line[i + 1] == quote || line[i + 1] == ' ')) {
        token.write(line[++i]);
      } else if (c == '"' || c == "'") {
        if (quote == c) {
          quote = null;
        } else if (quote == null) {
          quote = c;
        } else {
          token.write(c);
        }
      } else if (quote == null &&
          (c.trim().isEmpty ||
              c == '=' &&
                  result.length <= 1 &&
                  (result.isEmpty || token.isEmpty))) {
        if (token.isNotEmpty) {
          result.add(token.toString());
          token = StringBuffer();
        }
      } else {
        token.write(c);
      }
    }
    if (token.isNotEmpty) result.add(token.toString());
    return result;
  }
}
