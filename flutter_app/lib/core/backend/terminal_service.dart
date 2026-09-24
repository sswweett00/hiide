import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TerminalLine {
  final String text;
  final TerminalLineType type;

  const TerminalLine({required this.text, required this.type});
}

enum TerminalLineType { command, stdout, stderr, info }

class TerminalService {
  TerminalService({String? workingDirectory})
      : _workingDirectory = _validDirectory(workingDirectory);

  static const int _maxOutputLines = 2000;
  static const int _maxHistory = 200;

  final _controller = StreamController<TerminalLine>.broadcast();
  final List<TerminalLine> _outputLog = <TerminalLine>[];
  final List<String> _cmdHistory = <String>[];
  final Set<Process> _activeProcesses = <Process>{};
  int _historyIndex = -1;
  String _workingDirectory;
  bool _disposed = false;

  Stream<TerminalLine> get lineStream => _controller.stream;
  List<TerminalLine> get outputLog => List<TerminalLine>.unmodifiable(_outputLog);
  List<String> get history => List<String>.unmodifiable(_cmdHistory);
  String get workingDirectory => _workingDirectory;

  static String _validDirectory(String? requested) {
    final path = requested?.trim();
    if (path != null && path.isNotEmpty) {
      try {
        final dir = Directory(path);
        if (dir.existsSync()) return dir.resolveSymbolicLinksSync();
      } catch (_) {}
    }
    return Directory.current.path;
  }

  void setWorkingDirectory(String path) {
    if (_disposed) return;
    final requested = path.trim();
    if (requested.isEmpty) return;
    try {
      final dir = Directory(requested);
      if (dir.existsSync()) _workingDirectory = dir.resolveSymbolicLinksSync();
    } catch (_) {}
  }

  Future<void> execute(String command) async {
    if (_disposed) return;
    final normalized = command.trim();
    if (normalized.isEmpty) return;
    _remember(normalized);
    if (_handleBuiltin(normalized)) return;
    _addLine('\$ $command', TerminalLineType.command);
    await _runAndLog(command, timeout: null);
  }

  /// Cancels all processes currently owned by the terminal session.
  /// Returns the number of processes that received a kill signal.
  int cancelActiveProcesses() {
    var canceled = 0;
    for (final process in List<Process>.from(_activeProcesses)) {
      try {
        if (process.kill()) canceled++;
      } catch (_) {}
    }
    return canceled;
  }

  Future<String> executeCapture(String command, {Duration timeout = const Duration(seconds: 60)}) async {
    if (_disposed) return '(error) terminal disposed';
    final normalized = command.trim();
    if (normalized.isEmpty) return '';
    _remember(normalized);
    if (_handleBuiltin(normalized)) {
      if (normalized == 'clear') return '(terminal cleared)';
      if (normalized == 'cd' || normalized.startsWith('cd ')) return 'Changed directory to $_workingDirectory';
      return '';
    }
    _addLine('\$ $command', TerminalLineType.command);
    return _runAndLog(command, timeout: timeout);
  }

  bool _handleBuiltin(String command) {
    if (command == 'clear') {
      _outputLog.clear();
      _addLine('\x1B[2J', TerminalLineType.info);
      return true;
    }
    if (command == 'cd' || command.startsWith('cd ')) {
      final target = command.length <= 2 ? '~' : command.substring(3).trim();
      final candidate = target == '~' || target == r'~/'
          ? (Platform.environment['HOME'] ?? _workingDirectory)
          : target;
      final dir = Directory(_isAbsolute(candidate) ? candidate : '$_workingDirectory${Platform.pathSeparator}$candidate');
      try {
        if (!dir.existsSync()) {
          _addLine('cd: no such file or directory: $target', TerminalLineType.stderr);
          return true;
        }
        _workingDirectory = dir.resolveSymbolicLinksSync();
        _addLine(_workingDirectory, TerminalLineType.info);
      } catch (error) {
        _addLine('cd: $error', TerminalLineType.stderr);
      }
      return true;
    }
    return false;
  }

  bool _isAbsolute(String path) => path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  void _remember(String command) {
    if (_cmdHistory.isNotEmpty && _cmdHistory.last == command) {
      _historyIndex = _cmdHistory.length;
      return;
    }
    _cmdHistory.add(command);
    if (_cmdHistory.length > _maxHistory) _cmdHistory.removeAt(0);
    _historyIndex = _cmdHistory.length;
  }

  Future<String> _runAndLog(String command, {Duration? timeout}) async {
    Process? process;
    try {
      final executable = Platform.isWindows ? 'cmd.exe' : 'bash';
      final arguments = Platform.isWindows ? <String>['/C', command] : <String>['-lc', command];
      process = await Process.start(executable, arguments, workingDirectory: _workingDirectory, runInShell: false);
      _activeProcesses.add(process);

      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = process.stdout.transform(utf8.decoder).listen((chunk) {
        stdoutBuffer.write(chunk);
        for (final line in chunk.split('\n')) {
          if (line.isNotEmpty) _addLine(line, TerminalLineType.stdout);
        }
      }).asFuture<void>();
      final stderrDone = process.stderr.transform(utf8.decoder).listen((chunk) {
        stderrBuffer.write(chunk);
        for (final line in chunk.split('\n')) {
          if (line.isNotEmpty) _addLine(line, TerminalLineType.stderr);
        }
      }).asFuture<void>();

      var timedOut = false;
      final exitCode = timeout == null
          ? await process.exitCode
          : await process.exitCode.timeout(timeout, onTimeout: () {
              timedOut = true;
              process!.kill();
              return -1;
            });

      _activeProcesses.remove(process);
      await Future.wait<void>([stdoutDone, stderrDone]).timeout(const Duration(seconds: 1), onTimeout: () => <void>[]);

      final stdout = stdoutBuffer.toString().trimRight();
      final stderr = stderrBuffer.toString().trimRight();
      final combined = [if (stdout.isNotEmpty) stdout, if (stderr.isNotEmpty) stderr].join('\n');
      if (timedOut) {
        final seconds = timeout?.inSeconds ?? 0;
        _addLine('Command timed out after ${seconds}s', TerminalLineType.stderr);
        return '(error) Command timed out after ${seconds}s';
      }
      if (exitCode != 0) {
        _addLine('Command exited with code $exitCode', TerminalLineType.stderr);
        return combined.isEmpty ? '(error) exit code $exitCode' : '(error) $combined';
      }
      return combined.isEmpty ? '(command completed with no output)' : combined;
    } catch (error) {
      if (process != null) _activeProcesses.remove(process);
      _addLine('Error: $error', TerminalLineType.stderr);
      return '(error) $error';
    }
  }

  void logAgentRun(String command, String output) {
    if (_disposed) return;
    _remember(command);
    _addLine('\$ $command', TerminalLineType.command);
    for (final line in output.split('\n')) {
      if (line.isNotEmpty) _addLine(line, TerminalLineType.stdout);
    }
  }

  void _addLine(String text, TerminalLineType type) {
    if (_disposed) return;
    final line = TerminalLine(text: text, type: type);
    _outputLog.add(line);
    if (_outputLog.length > _maxOutputLines) _outputLog.removeRange(0, _outputLog.length - _maxOutputLines);
    if (!_controller.isClosed) _controller.add(line);
  }

  String? navigateHistory(bool up) {
    if (_cmdHistory.isEmpty) return null;
    if (up) {
      if (_historyIndex > 0) _historyIndex--;
      return _cmdHistory[_historyIndex];
    }
    if (_historyIndex < _cmdHistory.length - 1) {
      _historyIndex++;
      return _cmdHistory[_historyIndex];
    }
    _historyIndex = _cmdHistory.length;
    return '';
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final process in List<Process>.from(_activeProcesses)) {
      try { process.kill(); } catch (_) {}
    }
    _activeProcesses.clear();
    await _controller.close();
  }
}
