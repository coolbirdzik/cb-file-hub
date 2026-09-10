import 'dart:io';
import 'package:cb_file_manager/services/ssh/local_ssh_discovery.dart';
import 'package:cb_file_manager/services/ssh/ssh_profile_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Directory ssh;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    home = await Directory.systemTemp.createTemp('cb-ssh-discovery-');
    ssh = await Directory(p.join(home.path, '.ssh')).create();
  });
  tearDown(() async => home.delete(recursive: true));

  test(
    'reads aliases, first values, wildcard defaults and named private keys',
    () async {
      final key = SshStoredKey.generate('fixture');
      final custom = File(p.join(ssh.path, 'work key'));
      await custom.writeAsString(key.pem);
      await File(p.join(ssh.path, 'work key.pub')).writeAsString(key.publicKey);
      await File(
        p.join(ssh.path, 'known_hosts'),
      ).writeAsString('not a private key');
      await File(
        p.join(ssh.path, 'putty.ppk'),
      ).writeAsString('PuTTY-User-Key-File-3: ssh-ed25519');
      await File(p.join(ssh.path, 'config')).writeAsString('''
Host dev other
  HostName=dev.example.test
  User "developer"
  Port 2222
  IdentityFile "~/.ssh/work key" # comment
Host * !other
  User fallback
  Port 22
Host other
  User ignored
''');
      final result = await LocalSshDiscovery(
        homeDirectory: home.path,
        username: 'local',
      ).scan();
      expect(result.hosts.map((h) => h.alias), ['dev', 'other']);
      expect(result.hosts.first.host, 'dev.example.test');
      expect(result.hosts.first.username, 'developer');
      expect(result.hosts.first.port, 2222);
      expect(result.hosts.first.identityFiles, [custom.path]);
      expect(result.keys.map((k) => k.path), [custom.path]);
      expect(result.warnings, isEmpty);
    },
  );

  test(
    'follows sorted includes with cycle limits and never executes Match exec',
    () async {
      await Directory(p.join(ssh.path, 'conf.d')).create();
      await File(
        p.join(ssh.path, 'config'),
      ).writeAsString('Include conf.d/*.conf\n');
      await File(p.join(ssh.path, 'conf.d', 'a.conf')).writeAsString('''
Host dev
 HostName dev.example.test
 ProxyJump bastion
 IdentityFile %d/.ssh/%h-%r-%p
Match exec "touch should-not-exist"
 User wrong
Host *
 User developer
Include config
''');
      final result = await LocalSshDiscovery(homeDirectory: home.path).scan();
      expect(result.hosts.single.username, 'developer');
      expect(result.hosts.single.unsupportedOptions, ['proxyjump']);
      expect(
        result.hosts.single.identityFiles.single,
        p.join(ssh.path, 'dev.example.test-developer-22'),
      );
      expect(result.warnings, isNotEmpty);
      expect(
        await File(p.join(home.path, 'should-not-exist')).exists(),
        isFalse,
      );
    },
  );

  test('missing SSH folder is an empty discovery', () async {
    final result = await LocalSshDiscovery(
      homeDirectory: p.join(home.path, 'missing'),
    ).scan();
    expect(result.hosts, isEmpty);
    expect(result.keys, isEmpty);
    expect(result.warnings, isEmpty);
  });

  test(
    'an Include in a non-matching Host cannot change another host',
    () async {
      await File(p.join(ssh.path, 'config')).writeAsString('''
Host other
 Include other.conf
Host dev
 HostName dev.example.test
 User developer
''');
      await File(p.join(ssh.path, 'other.conf')).writeAsString('''
Host *
 User wrong
''');
      final result = await LocalSshDiscovery(homeDirectory: home.path).scan();
      expect(
        result.hosts.firstWhere((h) => h.alias == 'dev').username,
        'developer',
      );
    },
  );

  test('quoted Windows paths and equals in a filename are preserved', () {
    expect(
      LocalSshDiscovery.tokenize(
        r'IdentityFile="C:\Users\dev\.ssh\work=key" # comment',
      ),
      ['IdentityFile', r'C:\Users\dev\.ssh\work=key'],
    );
    expect(LocalSshDiscovery.tokenize('HostName = dev.example.test'), [
      'HostName',
      'dev.example.test',
    ]);
  });

  test('repeated and concurrent imports reuse the vault identity', () async {
    final store = SshProfileStore();
    final key = SshStoredKey.generate('original');
    final saved = await store.importKey(key);
    final imports = await Future.wait(
      List.generate(
        3,
        (_) => store.importKey(SshStoredKey.import('copy', key.pem)),
      ),
    );
    expect(imports.map((k) => k.id), everyElement(saved.id));
    expect(store.keys, hasLength(1));
  });
}
