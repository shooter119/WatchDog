class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  final String? requestId;
  final Map<String, dynamic>? current;
  final List<String> suggestions;

  ApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.requestId,
    this.current,
    this.suggestions = const [],
  });

  @override
  String toString() => message;
}

bool isApiAuthenticationFailure(Object error) =>
    error is ApiException &&
    const {
      'SESSION_REQUIRED',
      'SESSION_INVALID',
      'SESSION_EXPIRED',
      'KEY_SITE_AUTH_REQUIRED',
    }.contains(error.code);
