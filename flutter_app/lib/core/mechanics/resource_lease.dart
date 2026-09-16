import 'dart:async';

class LeaseUnavailableException implements Exception {
  const LeaseUnavailableException(this.key);
  final String key;
  @override
  String toString() => 'Resource lease unavailable: $key';
}

class _Lease {
  _Lease(this.token, this.expiresAt);
  final Object token;
  DateTime expiresAt;
}

class ResourceLeaseManager {
  ResourceLeaseManager({this.defaultTtl = const Duration(seconds: 30)})
      : assert(defaultTtl > Duration.zero);

  final Duration defaultTtl;
  final Map<String, _Lease> _leases = <String, _Lease>{};

  ResourceLeaseHandle acquire(String key, {Duration? ttl}) {
    _cleanup();
    if (_leases.containsKey(key)) throw LeaseUnavailableException(key);
    final token = Object();
    _leases[key] = _Lease(token, DateTime.now().add(ttl ?? defaultTtl));
    return ResourceLeaseHandle._(this, key, token);
  }

  bool isHeld(String key) {
    _cleanup();
    return _leases.containsKey(key);
  }

  bool _renew(String key, Object token, Duration ttl) {
    final lease = _leases[key];
    if (lease == null || !identical(lease.token, token)) return false;
    lease.expiresAt = DateTime.now().add(ttl);
    return true;
  }

  void _release(String key, Object token) {
    final lease = _leases[key];
    if (lease != null && identical(lease.token, token)) _leases.remove(key);
  }

  void _cleanup() {
    final now = DateTime.now();
    _leases.removeWhere((_, lease) => !now.isBefore(lease.expiresAt));
  }

  void clear() => _leases.clear();
}

class ResourceLeaseHandle {
  ResourceLeaseHandle._(this._owner, this.key, this._token);
  final ResourceLeaseManager _owner;
  final String key;
  final Object _token;
  bool _released = false;

  bool get isReleased => _released;

  bool renew({Duration? ttl}) {
    if (_released) return false;
    final ok = _owner._renew(key, _token, ttl ?? _owner.defaultTtl);
    if (!ok) _released = true;
    return ok;
  }

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(key, _token);
  }

  Future<T> protect<T>(Future<T> Function() action) async {
    if (_released) throw StateError('Lease already released: $key');
    try {
      return await action();
    } finally {
      release();
    }
  }
}
