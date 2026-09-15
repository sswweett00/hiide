import 'dart:async';
import 'dart:io';

/// A single line of terminal output, tagged with its type.
class TerminalLine {
  final String text;
  final TerminalLineType type;

  const TerminalLine({required this.text, required this.type});
}

enum TerminalLineType { command, stdout, stderr, info }

class TerminalService {
  final _controller = StreamController<TerminalLine>.broadcast();
  final List<TerminalLine> _outputLog = [];
  final List<String> _cmdHistory = [];
  int _historyIndex = -1;
  String _workingDirectory = '/home/kaan';

  Stream<TerminalLine> get lineStream => _controller.stream;

  /// All output lines ever written — used to rebuild the UI on first mount.
  List<TerminalLine> get outputLog => List.unmodifiable(_outputLog);

  /// Command history (for up/down arrow navigation).
  List<String> get history => List.unmodifiable(_cmdHistory);

  void setWorkingDirectory(String path) {
    _workingDirectory = path;
  }

  /// Runs [command] and logs it (and its output) to the terminal panel.
  Future<void> execute(String command) async {
    _cmdHistory.add(command);
    _historyIndex = _cmdHistory.length;

    // Handle built-in `cd` command
    if (command.trim().startsWith('cd ')) {
      final target = command.trim().substring(3).trim();
      final newPath =
          target.startsWith('/') ? target : '$_workingDirectory/$target';
      final dir = Directory(newPath);
      if (await dir.exists()) {
        _workingDirectory = dir.resolveSymbolicLinksSync();
        _addLine('\$ $command', TerminalLineType.command);
        _addLine('$_workingDirectory', TerminalLineType.info);
      } else {
        _addLine('\$ $command', TerminalLineType.command);
        _addLine(
            'cd: no such file or directory: $target', TerminalLineType.stderr);
      }
      return;
    }

    if (command.trim() == 'clear') {
      _outputLog.clear();
      // Emit a special clear signal
      _addLine('\x1B[2J', TerminalLineType.info);
      return;
    }

    _addLine('\$ $command', TerminalLineType.command);
    // No Dart-side timeout here: the UI path must not leave a pending timer
    // (widget tests assert no timers are pending after the tree is disposed).
    await _runAndLog(command, timeout: null);
  }

  /// Runs [command], logs it to the terminal panel, and returns the combined
  /// stdout + stderr text so the AI agent can react to the output.
  /// [timeout] guards against commands that hang the agent loop.
  Future<String> executeCapture(
    String command, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _cmdHistory.add(command);
    _historyIndex = _cmdHistory.length;

    // Handle built-in `cd` command
    if (command.trim().startsWith('cd ')) {
      final target = command.trim().substring(3).trim();
      final newPath =
          target.startsWith('/') ? target : '$_workingDirectory/$target';
      final dir = Directory(newPath);
      if (await dir.exists()) {
        _workingDirectory = dir.resolveSymbolicLinksSync();
        _addLine('\$ $command', TerminalLineType.command);
        _addLine('$_workingDirectory', TerminalLineType.info);
        return 'Changed directory to $_workingDirectory';
      }
      _addLine('\$ $command', TerminalLineType.command);
      _addLine(
          'cd: no such file or directory: $target', TerminalLineType.stderr);
      return '(error) cd: no such file or directory: $target';
    }

    if (command.trim() == 'clear') {
      _outputLog.clear();
      _addLine('\x1B[2J', TerminalLineType.info);
      return '(terminal cleared)';
    }

    _addLine('\$ $command', TerminalLineType.command);
    try {
      final output = await _runAndLog(command, timeout: timeout);
      return output;
    } catch (e) {
      _addLine('Error: $e', TerminalLineType.stderr);
      return '(error) $e';
    }
  }

  /// Shared process runner: logs the command + output and returns the combined
  /// text output ('' on failure or empty output). A null [timeout] runs without
  /// a Dart-side timer (used by the interactive UI path).
  Future<String> _runAndLog(
    String command, {
    Duration? timeout,
  }) async {
    try {
      var process = Process.run(
        'bash',
        ['-c', command],
        workingDirectory: _workingDirectory,
        runInShell: false,
      );
      if (timeout != null) {
        process = process.timeout(timeout);
      }
      final result = await process;

      final stdout = result.stdout.toString().trimRight();
      final stderr = result.stderr.toString().trimRight();

      if (stdout.isNotEmpty) {
        for (final line in stdout.split('\n')) {
          _addLine(line, TerminalLineType.stdout);
        }
      }
      if (stderr.isNotEmpty) {
        for (final line in stderr.split('\n')) {
          _addLine(line, TerminalLineType.stderr);
        }
      }

      final combined = [
        if (stdout.isNotEmpty) stdout,
        if (stderr.isNotEmpty) stderr,
      ].join('\n');
      return combined.isEmpty ? '(command completed with no output)' : combined;
    } on TimeoutException {
      final seconds = timeout?.inSeconds ?? 0;
      _addLine('Command timed out after ${seconds}s', TerminalLineType.stderr);
      return '(error) Command timed out after ${seconds}s';
    } catch (e) {
      _addLine('Error: $e', TerminalLineType.stderr);
      return '(error) $e';
    }
  }

  /// Publishes a command the AI agent ran (through the Zig engine) into the
  /// terminal panel so the user can see what the agent did. The command itself
  /// is executed by the engine — this only mirrors it for display.
  void logAgentRun(String command, String output) {
    _addLine('\$ $command', TerminalLineType.command);
    if (output.trim().isEmpty) return;
    for (final line in output.split('\n')) {
      _addLine(line, TerminalLineType.stdout);
    }
  }

  void _addLine(String text, TerminalLineType type) {
    final line = TerminalLine(text: text, type: type);
    _outputLog.add(line);
    if (!_controller.isClosed) {
      _controller.add(line);
    }
  }

  String? navigateHistory(bool up) {
    if (_cmdHistory.isEmpty) return null;
    if (up) {
      if (_historyIndex > 0) _historyIndex--;
    } else {
      if (_historyIndex < _cmdHistory.length - 1) _historyIndex++;
    }
    if (_historyIndex < 0 || _historyIndex >= _cmdHistory.length) return null;
    return _cmdHistory[_historyIndex];
  }

  void dispose() {
    _controller.close();
  }
}
