import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/services/diagnostic_log_service.dart';

void main() {
  test('诊断 payload 包含异常上下文并截断敏感/超长字段', () {
    final event = DiagnosticLogService.buildEvent(
      error: Exception('request failed api_token=secret-value'),
      stack: StackTrace.fromString('x' * 10000),
      source: 'flutter_error',
      page: 'chat',
      appVersion: '1.0.0+45',
      context: 'building ChatPage',
      library: 'widgets library',
      sequence: 7,
      breadcrumbs: const [
        {'stage': 'chat_submit', 'level': 'info'},
      ],
      timestamp: 123,
    );

    expect(event['stage'], 'diagnostic_error');
    expect(event['level'], 'error');
    expect(event['op_id'], 'diag-123-7');
    final data = event['data']! as Map<String, dynamic>;
    expect(data['page'], 'chat');
    expect(data['app_version'], '1.0.0+45');
    expect(data['error'], contains('[REDACTED]'));
    expect((data['stack'] as String).length, lessThanOrEqualTo(4001));
    expect(data['breadcrumbs'], isNotEmpty);
  });
}
