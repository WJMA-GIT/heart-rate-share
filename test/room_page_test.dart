import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/l10n/strings_zh.dart';
import 'package:heartrate/room/room_address.dart';
import 'package:heartrate/room/room_client.dart';
import 'package:heartrate/room/room_code.dart';
import 'package:heartrate/ui/app_state.dart';
import 'package:heartrate/ui/pages/room_page.dart';
import 'package:heartrate/ui/widgets/room_code_card.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('房间号卡片', () {
    testWidgets('非法输入在卡片里直接红字提示，不弹对话框', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(RoomCodeCard(controller: controller)));

      expect(find.text(Zh.roomCodeInvalid), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.enterText(find.byType(TextField), 'bad code!');
      await tester.pump();
      expect(find.text(Zh.roomCodeInvalid), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.enterText(find.byType(TextField), 'ROOM_01');
      await tester.pump();
      expect(find.text(Zh.roomCodeInvalid), findsNothing);
    });

    testWidgets('可清空、可复制（空内容时复制按钮不可用）', (tester) async {
      final controller = TextEditingController(text: 'ABC123');
      addTearDown(controller.dispose);
      String? copied;
      await tester.pumpWidget(
        _host(
          RoomCodeCard(
            controller: controller,
            onCopy: (value) => copied = value,
          ),
        ),
      );

      await tester.tap(find.byTooltip(Zh.copyRoomNumber));
      expect(copied, 'ABC123');

      await tester.tap(find.byTooltip(Zh.clearRoomCode));
      await tester.pump();
      expect(controller.text, isEmpty);
      final copyButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.copy),
          matching: find.byType(IconButton),
        ),
      );
      expect(copyButton.onPressed, isNull);
    });

    testWidgets('不是普通输入框：卡片内无边框装饰', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(RoomCodeCard(controller: controller)));
      final field = tester.widget<TextField>(find.byType(TextField));
      // 不能是带下划线/外框的常规输入框
      expect(field.decoration?.border, isNot(isA<UnderlineInputBorder>()));
      expect(field.decoration?.border, isNot(isA<OutlineInputBorder>()));
      expect(find.byType(Card), findsOneWidget);
    });
  });

  group('房间页三个动作', () {
    testWidgets('三个按钮都在，且不再出现「官方服务器」字样', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      expect(find.text(Zh.createCloudRoom), findsOneWidget);
      expect(find.text(Zh.createLocalRoom), findsOneWidget);
      expect(find.text(Zh.joinRoom), findsOneWidget);
      expect(find.textContaining('官方'), findsNothing);
      // 自定义服务器是要选出来才出现的
      expect(find.text(Zh.hostLabel), findsNothing);
      await tester.tap(find.text(Zh.targetCustom));
      await tester.pump();
      expect(find.text(Zh.hostLabel), findsOneWidget);
      expect(find.text(Zh.portLabel), findsOneWidget);
      expect(find.text(Zh.schemeLabel), findsOneWidget);
    });

    testWidgets('创建云端房间：先在卡片里生成一个合法房间号', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        isEmpty,
      );
      await tester.tap(find.text(Zh.createCloudRoom));
      await tester.pump();

      final shown = tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!
          .text;
      expect(RoomCode.isValid(shown), isTrue, reason: shown);
      expect(shown, hasLength(6));
    });

    testWidgets('房间号为空时「加入房间」给提示而不是硬连', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      await tester.tap(find.text(Zh.joinRoom));
      await tester.pump();
      expect(find.text(Zh.roomCodeEmpty), findsOneWidget);
      expect(state.room.state, RoomConnectionState.disconnected);
    });

    testWidgets('自定义服务器校验失败：非法端口有明确提示', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(RoomPage(state: state)));

      await tester.enterText(find.byType(TextField).first, 'ROOM01');
      await tester.tap(find.text(Zh.targetCustom));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, Zh.hostLabel),
        '10.0.0.3',
      );
      await tester.enterText(
        find.widgetWithText(TextField, Zh.portLabel),
        '99999',
      );
      await tester.tap(find.text(Zh.joinRoom));
      await tester.pump();

      expect(
        find.textContaining(
          Zh.roomError(
            const RoomAddressException(RoomAddressError.invalidPort),
          ),
        ),
        findsOneWidget,
      );
    });
  });
}
