import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchdog/models/models.dart';
import 'package:watchdog/pages/chat_page.dart';
import 'package:watchdog/services/audio_service.dart';
import 'package:watchdog/state/app_controller.dart';
import 'package:watchdog/theme/app_theme.dart';

class _ControlledChatController extends AppController {
  final historyCompleter = Completer<List<ChatMessage>>();
  final replyCompleter = Completer<String>();
  final clearCompleter = Completer<void>();

  List<ChatMessage>? submittedHistory;
  bool clearRequested = false;

  @override
  Future<List<ChatMessage>> fetchChatHistory() => historyCompleter.future;

  @override
  Future<String> askAssistantStream(
    String message, {
    required void Function(String delta) onChunk,
    String? opId,
    List<ChatMessage> history = const [],
  }) {
    submittedHistory = List<ChatMessage>.of(history);
    return replyCompleter.future;
  }

  @override
  Future<void> clearChatHistory() {
    clearRequested = true;
    return clearCompleter.future;
  }

  @override
  void cancelAssistantRequest() {}
}

class _NoopAudioService extends AudioService {
  @override
  Future<void> dispose() async {}
}

const _staleHistory = [
  ChatMessage(id: 'old-user', role: 'user', content: '旧问题', createdAt: 1),
  ChatMessage(
    id: 'old-assistant',
    role: 'assistant',
    content: '旧回答',
    createdAt: 2,
  ),
];

Future<void> _pumpChatPage(
  WidgetTester tester,
  _ControlledChatController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ChatPage(
          controller: controller,
          audioService: _NoopAudioService(),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('历史晚到时不会覆盖已经发送的本地消息', (tester) async {
    final controller = _ControlledChatController();
    await _pumpChatPage(tester, controller);

    final state = tester.state<ChatPageState>(find.byType(ChatPage));
    final sendFuture = state.submitQuestion('新问题');
    await tester.pump();
    expect(find.text('新问题'), findsOneWidget);
    expect(find.text('水元素思考中…'), findsOneWidget);

    controller.historyCompleter.complete(_staleHistory);
    await tester.pump();
    expect(find.text('旧问题'), findsOneWidget);
    expect(find.text('旧回答'), findsOneWidget);
    expect(find.text('新问题'), findsOneWidget);
    expect(find.text('水元素思考中…'), findsOneWidget);

    controller.replyCompleter.complete('新回答');
    await sendFuture;
    await tester.pump();
    expect(find.text('新回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空完成后历史晚到也不会恢复已删除的消息', (tester) async {
    final controller = _ControlledChatController();
    await _pumpChatPage(tester, controller);

    final state = tester.state<ChatPageState>(find.byType(ChatPage));
    final sendFuture = state.submitQuestion('待清空问题');
    await tester.pump();
    controller.replyCompleter.complete('待清空回答');
    await sendFuture;
    await tester.pump();

    await tester.tap(find.byTooltip('清空问答记录'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pump();
    expect(controller.clearRequested, isTrue);

    controller.clearCompleter.complete();
    await tester.pump();
    expect(find.text('待清空问题'), findsNothing);
    expect(find.text('待清空回答'), findsNothing);

    controller.historyCompleter.complete(_staleHistory);
    await tester.pump();
    expect(find.text('旧问题'), findsNothing);
    expect(find.text('旧回答'), findsNothing);
    expect(find.text('你好，我是水元素'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发送中的清空入口被禁用，避免与未完成请求交叉', (tester) async {
    final controller = _ControlledChatController();
    controller.historyCompleter.complete(_staleHistory);
    await _pumpChatPage(tester, controller);

    final state = tester.state<ChatPageState>(find.byType(ChatPage));
    final sendFuture = state.submitQuestion('进行中的问题');
    await tester.pump();
    final clearButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_sweep_outlined),
    );
    expect(clearButton.onPressed, isNull);

    controller.replyCompleter.complete('进行中的回答');
    await sendFuture;
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.delete_sweep_outlined),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
