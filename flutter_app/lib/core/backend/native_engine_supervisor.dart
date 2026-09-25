import 'dart:async';
import 'dart:io';

import 'backend_service.dart';
import 'hiide_backend_service.dart';
import 'mock_backend_service.dart';

class NativeEngineLaunch {
  final BackendService backend;
  final Process? process;
  const NativeEngineLaunch({required this.backend, this.process});
}

class NativeEngineSupervisor {
  NativeEngineSupervisor({
    this.host = '127.0.0.1',
    this.port = 4879,
  });

  final String host;
  final int port;
  static const Duration _startupTimeout = Duration(seconds: 4);

  Future<NativeEngineLaunch> connectOrStart() async {
    final existing = HiideBackendService(host: host, port: port);
    try {
      await existing.connect();
      return NativeEngineLaunch(backend: existing);
    } catch (_) {
      await existing.disconnect();
    }

    for (final candidate in await _candidates()) {
      if (!await File(candidate).exists()) continue;
      Process? process;
      try {
        process = await Process.start(
          candidate,
          const [],
          runInShell: false,
        );
        unawaited(process.stdout.drain<void>().catchError((_) {}));
        unawaited(process.stderr.drain<void>().catchError((_) {}));

        final backend = HiideBackendService(host: host, port: port);
        final deadline = DateTime.now().add(_startupTimeout);
        for (var attempt = 0; attempt < 20 && DateTime.now().isBefore(deadline); attempt++) {
          try {
            await backend.connect();
            return NativeEngineLaunch(backend: backend, process: process);
          } catch (_) {
            await backend.disconnect();
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
      } catch (_) {
        // Try the next well-known location.
      }

      process?.kill();
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }

    return NativeEngineLaunch(backend: MockBackendService());
  }

  Future<List<String>> _candidates() async {
    final values = <String>[];
    void add(String? path) {
      if (path == null || path.isEmpty || values.contains(path)) return;
      values.add(path);
    }

    add(Platform.environment['HIIDE_ENGINE_PATH']);

    final cwd = Directory.current.path;
    add('$cwd/hiide-ipc-server');
    add('$cwd/zig-out/bin/hiide-ipc-server');

    final executableDir = File(Platform.resolvedExecutable).parent.path;
    add('$executableDir/hiide-ipc-server');
    add('$executableDir/../bin/hiide-ipc-server');
    add('$executableDir/data/hiide-ipc-server');

    return values;
  }
}
