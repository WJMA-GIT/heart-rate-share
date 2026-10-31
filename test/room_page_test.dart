import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/l10n/strings_zh.dart';
import 'package:heartrate/core/profile/connection_profile.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/room/room_code.dart';
import 'package:heartrate/ui/app_state.dart';
import 'package:heartrate/ui/pages/room_page.dart';
import 'package:heartrate/ui/widgets/join_room_dialog.dart';
import 'package:heartrate/ui/widgets/room_code_card.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 记录剪贴板读取次数，并固定返回值（返回读取次数的取值函数）。
int Function() _mockClipboard(String? text) {
  var reads = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          reads += 1;
          return text == null ? null : <String, Object?>{'text': text};
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return () => reads;
}

void main() {
  group('房间号卡片（自己的一侧，只读）', () {
    testWidgets('不可编辑：卡片里没有任何输入框', (tester) async {
      await tester.pumpWidget(_host(const RoomCodeCard(roomCode: 'ABC123')));
      expect(find.byType(TextField), findsNothing);
      expect(find.text('ABC123'), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);
    });

    testWidgets('未进房间时显示占位文案，复制按钮不可用', (tester) async {
      await tester.pumpWidget(_host(const RoomCodeCard(roomCode: null)));
      expect(find.text(Zh.roomCodeNone), findsOneWidget);
      final copy = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.copy),
          matching: find.byType(IconButton),
        ),
      );
      expect(copy.onPressed, isNull);
    });

    testWidgets('左复制、右粘贴是两个分开的入口', (tester) async {
      String? copied;
      var pasted = 0;
      await tester.pumpWidget(
        _host(
          RoomCodeCard(
            roomCode: 'ABC123',
            onCopy: (value) => copied = value,
            onPaste: () => pasted += 1,
          ),
        ),
      );
      final copyFinder = find.ancestor(
        of: find.byIcon(Icons.copy),
        matching: find.byType(IconButton),
      );
      final pasteFinder = find.ancestor(
        of: find.byIcon(Icons.content_paste),
        matching: find.byType(IconButton),
      );
      expect(tester.getCenter(copyFinder).dx, lessThan(160));
      expect(tester.getCenter(pasteFinder).dx, greaterThan(160));

      await tester.tap(copyFinder);
      await tester.tap(pasteFinder);
      await tester.pump();
      expect(copied, 'ABC123');
      expect(pasted, 1);
    });
  });

  group('加入房间对话框（目标输入与自身房间号隔离）', () {
    Future<JoinRequest?> showDialogResult(
      WidgetTester tester, {
      required String enterText,
      String? ownRoomCode,
      List<ConnectionProfile> recents = const [],
    }) async {
      JoinRequest? request;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                request = await showDialog<JoinRequest>(
                  context: context,
                  builder: (_) => JoinRoomDialog(
                    ownRoomCode: ownRoomCode,
                    recents: recents,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (enterText.isNotEmpty) {
        await tester.enterText(find.byType(TextField), enterText);
      }
      await tester.tap(find.widgetWithText(FilledButton, Zh.joinRoom));
      await tester.pumpAndSettle();
      return request;
    }

    testWidgets('非法房间号就地报错，不返回目标', (tester) async {
      final request = await showDialogResult(tester, enterText: 'bad code!');
      expect(request, isNull);
      expect(find.text(Zh.roomCodeInvalid), findsOneWidget);
    });

    testWidgets('粘贴到的是自己的房间号：明确拒绝', (tester) async {
      final request = await showDialogResult(
        tester,
        enterText: 'MYROOM',
        ownRoomCode: 'MYROOM',
      );
      expect(request, isNull);
      expect(find.text(Zh.roomCodeIsOwn), findsOneWidget);
    });

    testWidgets('合法房间号返回目标；取消不改任何连接', (tester) async {
      final request = await showDialogResult(tester, enterText: 'PEER01');
      expect(request, isNotNull);
      expect(request!.code, 'PEER01');
      expect(request.profile, isNull, reason: '没选最近连接就用页面上的目标');
    });

    testWidgets('可以从最近连接选择，选中后带出它的服务器配置', (tester) async {
      final recent = ConnectionProfile(
        mode: ConnectionMode.remote,
        host: '10.0.0.9',
        port: 8765,
        secure: false,
        roomCode: 'RC0001',
      );
      JoinRequest? request;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                request = await showDialog<JoinRequest>(
                  context: context,
                  builder: (_) =>
                      JoinRoomDialog(ownRoomCode: null, recents: [recent]),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ChoiceChip));
      await tester.pumpAndSettle();
      expect(find.text(Zh.joinTargetServer(recent.endpoint)), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, Zh.joinRoom));
      await tester.pumpAndSettle();
      expect(request!.code, 'RC0001');
      expect(request!.profile?.id, recent.id);
    });

    testWidgets('剪贴板只在点「从剪贴板粘贴」时读一次', (tester) async {
      final reads = _mockClipboard('PEER02');
      String? pasted;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showDialog<JoinRequest>(
                  context: context,
                  builder: (_) =>
                      const JoinRoomDialog(ownRoomCode: 'MYROOM', recents: []),
                );
                pasted = result?.code;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(reads(), 0, reason: 'build 里不能读剪贴板');

      await tester.tap(find.text(Zh.pasteFromClipboard));
      await tester.pumpAndSettle();
      expect(reads(), 1);
      expect(find.text('PEER02'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, Zh.joinRoom));
      await tester.pumpAndSettle();
      expect(pasted, 'PEER02');
    });
  });

  group('房间页动作与最近连接', () {
    testWidgets('只有「创建房间」「加入房间」两个动作，没有本机建房', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      expect(find.text(Zh.createRoom), findsOneWidget);
      expect(find.text(Zh.joinRoom), findsOneWidget);
      expect(find.textContaining('本地'), findsNothing);
      expect(find.textContaining('官方'), findsNothing);
      expect(find.text(Zh.hostLabel), findsNothing);

      await tester.tap(find.text(Zh.targetCustom));
      await tester.pump();
      expect(find.text(Zh.hostLabel), findsOneWidget);
      expect(find.text(Zh.portLabel), findsOneWidget);
      expect(find.text(Zh.schemeLabel), findsOneWidget);
    });

    testWidgets('粘贴非法房间号：提示且不建立连接', (tester) async {
      _mockClipboard('bad code!');
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      await tester.tap(find.byTooltip(Zh.pasteRoomNumber));
      await tester.pumpAndSettle();

      expect(find.text(Zh.roomCodeInvalid), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(state.room.state, RoomConnectionState.disconnected);
    });

    testWidgets('粘贴合法房间号：进入确认加入，取消后连接不变', (tester) async {
      _mockClipboard('PEER01');
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      await tester.tap(find.byTooltip(Zh.pasteRoomNumber));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('PEER01'), findsOneWidget);

      await tester.tap(find.text(Zh.cancel));
      await tester.pumpAndSettle();
      expect(state.room.state, RoomConnectionState.disconnected);
    });

    testWidgets('最近连接不再有详情入口，字幕不省略', (tester) async {
      final recent = ConnectionProfile(
        mode: ConnectionMode.remote,
        host: '10.0.0.9',
        port: 8765,
        secure: false,
        roomCode: 'RC0001',
      );
      final state = AppState(recentProfiles: [recent]);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      expect(find.byIcon(Icons.info_outline), findsNothing);
      final subtitle = tester.widget<Text>(find.textContaining('RC0001'));
      expect(subtitle.overflow, isNot(TextOverflow.ellipsis));
      expect(subtitle.maxLines, isNull);
    });
  });

  test('系统生成的房间号仍是 6 位且满足协议正则', () {
    for (var i = 0; i < 20; i++) {
      final code = RoomCode.generate();
      expect(code, hasLength(6));
      expect(RoomCode.isValid(code), isTrue, reason: code);
    }
  });
}
