import 'dart:async';
import 'dart:io';

import 'cancellation_token.dart';
import 'circuit_breaker.dart';
import 'rate_limiter.dart';

enum FailureCode {
  cancelled,
  timeout,
  unavailable,
  rateLimited,
  conflict,
  validation,
  permission,
  notFound,
  transport,
  unknown,
}

class HiideFailure implements Exception {
  const HiideFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.cause,
    this.stackTrace,
  });

  final FailureCode code;
  final String message;
  final bool retryable;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'HiideFailure($code): $message';

  static HiideFailure from(Object error, [StackTrace? stack]) {
    if (error is HiideFailure) return error;
    if (error is TimeoutException) {
      return HiideFailure(
        code: FailureCode.timeout,
        message: error.message ?? 'Operation timed out',
        retryable: true,
        cause: error,
        stackTrace: stack,
      );
    }
    if (error is CancellationException) {
      return HiideFailure(
        code: FailureCode.cancelled,
        message: 'Operation cancelled',
        cause: error,
        stackTrace: stack,
      );
    }
    if (error is RateLimitException) {
      return HiideFailure(
        code: FailureCode.rateLimited,
        message: error.toString(),
        retryable: true,
        cause: error,
        stackTrace: stack,
      );
    }
    if (error is CircuitOpenException) {
      return HiideFailure(
        code: FailureCode.unavailable,
        message: error.toString(),
        retryable: true,
        cause: error,
        stackTrace: stack,
      );
    }
    if (error is SocketException || error is HttpException) {
      return HiideFailure(
        code: FailureCode.transport,
        message: error.toString(),
        retryable: true,
        cause: error,
        stackTrace: stack,
      );
    }
    if (error is FormatException) {
      return HiideFailure(
        code: FailureCode.validation,
        message: error.toString(),
        cause: error,
        stackTrace: stack,
      );
    }

    final text = error.toString().toLowerCase();
    final retryableMarkers = <String>[
      'http 408',
      'http 425',
      'http 429',
      'http 500',
      'http 502',
      'http 503',
      'http 504',
      'timed out',
      'timeout',
      'connection reset',
      'connection closed',
      'broken pipe',
      'temporarily unavailable',
      'service unavailable',
      'too many requests',
    ];
    if (retryableMarkers.any(text.contains)) {
      final code = text.contains('429') || text.contains('too many requests')
          ? FailureCode.rateLimited
          : text.contains('timeout')
              ? FailureCode.timeout
              : FailureCode.transport;
      return HiideFailure(
        code: code,
        message: error.toString(),
        retryable: true,
        cause: error,
        stackTrace: stack,
      );
    }

    if (text.contains('permission denied') ||
        text.contains('access denied') ||
        text.contains('forbidden') ||
        text.contains('unauthorized')) {
      return HiideFailure(
        code: FailureCode.permission,
        message: error.toString(),
        cause: error,
        stackTrace: stack,
      );
    }
    if (text.contains('not found') || text.contains('no such file')) {
      return HiideFailure(
        code: FailureCode.notFound,
        message: error.toString(),
        cause: error,
        stackTrace: stack,
      );
    }
    return HiideFailure(
      code: FailureCode.unknown,
      message: error.toString(),
      cause: error,
      stackTrace: stack,
    );
  }
}
