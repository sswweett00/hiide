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
        retryable: false,
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
    return HiideFailure(
      code: FailureCode.unknown,
      message: error.toString(),
      retryable: false,
      cause: error,
      stackTrace: stack,
    );
  }
}
