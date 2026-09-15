import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend_service.dart';

/// The active backend (real Zig engine or mock fallback).
/// Overridden at the app root with the instance created in `main()`.
final backendServiceProvider = Provider<BackendService>(
  (ref) => throw UnimplementedError(
      'backendServiceProvider must be overridden in main'),
);
