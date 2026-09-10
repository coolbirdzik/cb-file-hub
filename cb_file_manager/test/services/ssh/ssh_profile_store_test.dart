import 'package:cb_file_manager/services/ssh/ssh_profile_store.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'generated Ed25519 key imports and retains the same public identity',
    () {
      final key = SshStoredKey.generate('developer');
      expect(key.publicKey, startsWith('ssh-ed25519 '));
      final imported = SshStoredKey.import('developer', key.pem);
      expect(imported.fingerprint, key.fingerprint);
      expect(imported.publicKey, key.publicKey);
      final pair = SSHKeyPair.fromPem(key.pem).single as OpenSSHEd25519KeyPair;
      final encrypted = pair.toPem(passphrase: 'test-only-passphrase');
      expect(
        () => SshStoredKey.import('key', encrypted, 'wrong'),
        throwsA(anything),
      );
      expect(
        SshStoredKey.import(
          'key',
          encrypted,
          'test-only-passphrase',
        ).fingerprint,
        key.fingerprint,
      );
    },
  );
  test(
    'profiles, keys and fingerprints survive reload; referenced keys cannot be deleted',
    () async {
      final store = SshProfileStore();
      final key = SshStoredKey.generate('work');
      await store.saveKey(key);
      await Future.wait([
        store.saveProfile(
          SshProfile(
            id: '1',
            name: 'dev',
            host: 'localhost',
            username: 'alice',
            keyId: key.id,
          ),
        ),
        store.saveProfile(
          const SshProfile(
            id: '2',
            name: 'ops',
            host: 'localhost',
            username: 'bob',
            port: 2222,
            password: 'test-password',
          ),
        ),
        store.trust('localhost', 22, 'SHA256:fixture'),
      ]);
      final restored = SshProfileStore();
      await restored.load();
      expect(restored.profiles, hasLength(2));
      expect(restored.keys.single.fingerprint, key.fingerprint);
      expect(restored.knownHosts['localhost:22'], 'SHA256:fixture');
      await expectLater(store.deleteKey(key.id), throwsStateError);
      expect(store.keys, hasLength(1));
      await store.deleteProfile('1');
      await store.deleteKey(key.id);
      await store.forgetHost('localhost:22');
      final finalStore = SshProfileStore();
      await finalStore.load();
      expect(finalStore.keys, isEmpty);
      expect(finalStore.knownHosts, isEmpty);
      expect(finalStore.profiles.single.password, 'test-password');
    },
  );
}
