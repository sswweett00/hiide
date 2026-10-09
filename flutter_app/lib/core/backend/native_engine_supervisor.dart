import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'backend_service.dart';
import 'hiide_backend_service.dart';

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
    final inheritedToken = Platform.environment['HIIDE_IPC_TOKEN'];

    // Only attach to an existing engine when this process inherited its
    // unguessable session token. Without it, a different local process could
    // impersonate the engine on loopback and receive workspace contents.
    if (inheritedToken != null && inheritedToken.isNotEmpty) {
      final existing = HiideBackendService(
        host: host,
        port: port,
        ipcToken: inheritedToken,
      );
      try {
        await existing.connect();
        return NativeEngineLaunch(backend: existing);
      } catch (error) {
        await existing.disconnect();
        final message = error.toString();
        if (message.contains('unauthorized')) {
          throw StateError(
            'A protected Hiide IPC engine is already running on $host:$port '
            'but its session token is unavailable to this application.',
          );
        }
        if (message.contains('Incompatible Hiide IPC') ||
            message.contains('IPC contract violation')) {
          // An engine is reachable but speaks an incompatible wire contract.
          // Starting another process on the same port cannot repair that state.
          rethrow;
        }
      }
    }

    String? lastError;
    for (final candidate in await _candidates()) {
      if (!await File(candidate).exists()) continue;
      Process? process;
      try {
        final ipcToken = _generateIpcToken();
        process = await Process.start(
          candidate,
          const [],
          environment: <String, String>{
            ...Platform.environment,
            'HIIDE_IPC_TOKEN': ipcToken,
          },
          runInShell: false,
        );
        unawaited(process.stdout.drain<void>().catchError((_) {}));
        unawaited(process.stderr.drain<void>().catchError((_) {}));

        final backend = HiideBackendService(
          host: host,
          port: port,
          ipcToken: ipcToken,
        );
        final deadline = DateTime.now().add(_startupTimeout);
        for (var attempt = 0;
            attempt < 20 && DateTime.now().isBefore(deadline);
            attempt++) {
          try {
            await backend.connect();
            return NativeEngineLaunch(backend: backend, process: process);
          } catch (error) {
            lastError = '$error';
            await backend.disconnect();
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
      } catch (error) {
        lastError = '$error';
      }

      process?.kill();
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }

    final detail = lastError == null ? '' : ' Last error: $lastError';
    throw StateError(
      'Hiide native engine could not be started or reached at $host:$port. '
      'Build/package hiide-ipc-server and ensure it is available beside the '
      'application executable.$detail',
    );
  }

  String _generateIpcToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
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
