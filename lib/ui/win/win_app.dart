import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';
import '../../core/platform/app_version.dart';
import '../../core/platform/startup_log.dart';
import '../../theme/app_theme.dart';
import '../../room/protocol.dart';
import '../widgets/heart_rate_chart.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'win_controller.dart';
import 'win_drag.dart';

/// Windows 客户端（桌面布局）：左侧导航 + 顶部状态条 + 内容区。
///
/// 设计规范见 `generated/win/ui-spec.md`：深色基底、主色 #FF5252、8pt 栅格、
/// 字号 12/14/16/20/28、圆角 8/12/16。页面本身不碰平台能力，纯数据驱动，
/// 便于 golden 截图（`test/win_ui_golden_test.dart`）。
final class WinApp extends StatefulWidget {
  const WinApp({this.controller, this.preview = false, super.key});

  final WinController? controller;

  /// `--connected-preview`：注入 mock 成员并强制「已连接」，给 CI 冒烟用
  /// （`windows-preview-smoke` 断言 full→compact→full 两种界面真的切换过）。
  final bool preview;

  @override
  State<WinApp> createState() => _WinAppState();
}

final class _WinAppState extends State<WinApp> {
  WinController? _controllerOrNull;
  Object? _fatal;
  bool _owns = false;
  bool _autoConnectTried = false;
  bool _safeMode = false;
  _Section _section = _Section.connect;
  double _scale = 1.0;

  /// 窗口/悬浮窗尺寸签名的去重标记。
  String _pushedMetrics = '';

  /// Dart ↔ 原生（悬浮窗）：setOverlay / showOverlay，原生回调 overlayDisconnect。
  MethodChannel? _overlayChannel;
  bool _overlayShown = false;
  DateTime? _lastOverlayPush;

  /// 设置页显示的版本号：启动读一次（PackageInfo → exe 版本资源），不再手写死。
  String _version = '—';

  /// 上次上报的拖动区签名：只有变了才发 Win32 消息。
  String _dragRectSignature = '';

  /// 缩放持久化键（0.8–1.6，步进 0.1）。
  static const _scaleKey = 'win.scale';

  /// 心率字号（DIP，24–96 步进 4）：主界面卡片与精简态行内数字共用。
  static const _bpmSizeKey = 'win.bpmFontSize';
  double _bpmFontSize = defaultBpmFontSize;

  Future<void> _loadScale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getDouble(_scaleKey);
      if (value != null && mounted) {
        setState(() => _scale = value.clamp(0.8, 1.6));
      }
    } catch (_) {}
  }

  Future<void> _bumpScale(double delta) async {
    final next = (_scale + delta).clamp(0.8, 1.6);
    setState(() => _scale = double.parse(next.toStringAsFixed(1)));
    StartupLog.info('win: scale=${_scale.toStringAsFixed(1)}');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_scaleKey, _scale);
    } catch (_) {}
  }

  /// 报给原生的可拖动区（DIP）：命中它才 HTCAPTION，别处一律 HTCLIENT。
  /// 显式上报而不是让原生猜"空白区"——猜的版本把按钮一起吞了。
  void _pushDragRect(Rect rect) {
    final signature = [
      rect.left.round(),
      rect.top.round(),
      rect.width.round(),
      rect.height.round(),
    ].join('/');
    if (signature == _dragRectSignature) return;
    _dragRectSignature = signature;
    StartupLog.info('hit: drag rect $signature');
    setWindowDragRect(rect.left, rect.top, rect.width, rect.height);
  }

  /// 构建标识：CI 用 --dart-define=BUILD_ID=<sha8> 注入；本地构建显示 dev。
  static const _buildId = String.fromEnvironment('BUILD_ID');

  /// 版本号只读一次（全应用唯一入口 `AppVersion`），不要放进 build 里反复异步读。
  /// 显示成 `1.0.15 (1002116) · <sha8|dev>`：用户一眼能对上发布物。
  Future<void> _loadVersion() async {
    final raw = await AppVersion.readWithBuild();
    final parts = raw.split('+');
    final build = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : '?';
    final label =
        '${parts.first} ($build) · ${_buildId.isEmpty ? 'dev' : _buildId}';
    StartupLog.info('win: build=$label');
    if (mounted) setState(() => _version = label);
  }

  Future<void> _loadBpmFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getDouble(_bpmSizeKey);
      if (value != null && mounted) {
        setState(() => _bpmFontSize = _clampBpmFontSize(value));
      }
    } catch (_) {}
  }

  Future<void> _setBpmFontSize(double value) async {
    final next = _clampBpmFontSize(value);
    setState(() => _bpmFontSize = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bpmSizeKey, next);
    } catch (_) {}
  }

  WinController get _controller => _controllerOrNull!;

  /// 主窗口只做两件事：最小尺寸跟着缩放走、把悬浮窗要显示的行推过去。
  /// （连接后不再把主窗口变成全透明条带——那是独立悬浮窗的活。）
  void _syncWindow(bool connected) {
    final signature = '${_scale.toStringAsFixed(1)}/${_bpmFontSize.toInt()}';
    if (signature != _pushedMetrics) {
      _pushedMetrics = signature;
      setWindowMinSize(_minWindowWidth * _scale, _minWindowHeight * _scale);
    }
    _syncOverlay(connected);
  }

  /// 悬浮窗：连接才显示；数据每秒最多推一次，避免把 MethodChannel 刷满。
  void _syncOverlay(bool connected) {
    final channel = _overlayChannel;
    if (channel == null) return;
    if (!connected) {
      if (_overlayShown) {
        _overlayShown = false;
        channel.invokeMethod<void>('showOverlay', false).catchError((_) {});
      }
      return;
    }
    if (!_overlayShown) {
      _overlayShown = true;
      channel.invokeMethod<void>('showOverlay', true).catchError((_) {});
    }
    final now = DateTime.now();
    final last = _lastOverlayPush;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastOverlayPush = now;
    channel
        .invokeMethod<void>('setOverlay', _overlayPayload())
        .catchError((_) {});
  }

  /// (name, bpm, 归一化折线点)：归一化在 Dart 侧算好，原生只负责画。
  Map<String, Object?> _overlayPayload() {
    final controller = _controllerOrNull;
    final rows = <Map<String, Object?>>[];
    if (controller != null) {
      if (controller.transport == WinTransport.ble) {
        rows.add(
          _overlayRow('蓝牙设备', controller.ownBpm, controller.ownSeries, true),
        );
      }
      for (final member in controller.members) {
        rows.add(
          _overlayRow(
            member.report.displayName,
            member.online ? member.report.bpm : null,
            controller.seriesFor(member.report.memberId),
            member.online,
          ),
        );
      }
    }
    return {'font': _bpmFontSize, 'rows': rows};
  }

  Map<String, Object?> _overlayRow(
    String name,
    int? bpm,
    HeartRateSeries series,
    bool online,
  ) {
    final polyline = normalizedPolyline(series);
    final ys = <double>[];
    final gaps = <int>[];
    for (var index = 0; index < polyline.segments.length; index++) {
      final segment = polyline.segments[index];
      for (var point = 0; point < segment.length; point++) {
        ys.add(segment[point].dy.clamp(0.0, 1.0));
        gaps.add(point == 0 && index > 0 ? 1 : 0);
      }
    }
    return {
      'name': name,
      'bpm': online ? (bpm?.toString() ?? '--') : '--',
      'online': online,
      'ys': ys,
      'gaps': gaps,
    };
  }

  @override
  void initState() {
    super.initState();
    _safeMode = Platform.environment['HEARTRATE_SAFE_MODE'] == '1';
    StartupLog.info('win: init (safeMode=$_safeMode)');
    try {
      final controller =
          widget.controller ?? WinController(preview: widget.preview);
      _owns = widget.controller == null;
      _controllerOrNull = controller;
      controller.addListener(_onChange);
      _overlayChannel = const MethodChannel('hrs/win')
        ..setMethodCallHandler((call) async {
          if (call.method == 'overlayDisconnect') {
            StartupLog.info('overlay: disconnect from overlay window');
            await _controllerOrNull?.disconnectAll();
            if (mounted) setState(() {});
          }
          return null;
        });
      _loadScale();
      _loadVersion();
      _loadBpmFontSize();
      if (widget.preview) {
        controller.startPreview();
      } else if (!_safeMode) {
        controller.startDiscovery();
      }
      StartupLog.info('win: ready');
    } catch (error, stack) {
      _fatal = error;
      StartupLog.info('win: FATAL init: $error');
      StartupLog.info('$stack');
    }
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _maybeAutoConnect();
  }

  void _maybeAutoConnect() {
    if (_autoConnectTried || _controller.connected) return;
    final last = _controller.lastPeerId;
    if (last == null) return;
    final peer = _controller.peers.where((p) => p.id == last).firstOrNull;
    if (peer == null) return;
    _autoConnectTried = true;
    _controller.connectPeer(peer);
  }

  @override
  void dispose() {
    _overlayChannel?.setMethodCallHandler(null);
    _controllerOrNull?.removeListener(_onChange);
    if (_owns) _controllerOrNull?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        _fatal == null && _controllerOrNull != null && _controller.connected;
    // 在 build 里推窗口尺寸：这里是唯一同时知道「连接状态 + 缩放」的地方。
    _syncWindow(connected);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: WinTheme.data(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(_scale)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _fatal != null
          ? _FatalView(error: '$_fatal')
          : Scaffold(
              backgroundColor: WinColors.bg,
              body: LayoutBuilder(
                builder: (context, constraints) {
                  // 顶部空白带是拖动区：那里没有控件，点它只拖窗；其余一律 HTCLIENT。
                  final bandWidth = constraints.maxWidth - 32 - 150 * _scale;
                  if (bandWidth > 20) {
                    _pushDragRect(Rect.fromLTWH(16, 0, bandWidth, 24 * _scale));
                  }
                  // Ctrl+滚轮调缩放（标题栏删掉后挂在整页）。
                  return Listener(
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent &&
                          HardwareKeyboard.instance.isControlPressed) {
                        _bumpScale(event.scrollDelta.dy < 0 ? 0.1 : -0.1);
                      }
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Column(
                            children: [
                              Expanded(child: _page()),
                              _BottomTabs(
                                section: _section,
                                scale: _scale,
                                onSelect: (section) =>
                                    setState(() => _section = section),
                              ),
                            ],
                          ),
                        ),
                        // 右上角窗口控件（没有标题栏，最小化/退出只能自己做）。
                        Positioned(
                          top: (_dragStripDip + 6) * _scale,
                          right: 8 * _scale,
                          child: _WindowControls(
                            scale: _scale,
                            onZoomIn: () => _bumpScale(0.1),
                            onZoomOut: () => _bumpScale(-0.1),
                            onMinimize: minimizeWindow,
                            onClose: closeWindow,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }

  /// 「当前心率」：蓝牙自己那一路优先，否则取第一个在线成员。
  int? _currentBpm() {
    final controller = _controllerOrNull;
    if (controller == null) return null;
    final own = controller.ownBpm;
    if (own != null) return own;
    for (final member in controller.members) {
      final bpm = controller.liveBpm(member);
      if (bpm != null) return bpm;
    }
    return null;
  }

  HeartRateSeries _currentSeries() {
    final controller = _controllerOrNull;
    if (controller == null) return HeartRateSeries();
    if (controller.transport == WinTransport.ble) return controller.ownSeries;
    for (final member in controller.members) {
      if (member.online) {
        return controller.seriesFor(member.report.memberId);
      }
    }
    return HeartRateSeries();
  }

  /// 设备列表卡（沿用原来的连接页内容，视觉交给浅色主题）。
  Widget _deviceList(WinController c) => ConnectView(
    adapterState: c.ble.adapterState,
    bleBusy: c.ble.phase.name,
    devices: [for (final d in c.bleDevices) d],
    hiddenDevices: c.hiddenBleDeviceCount,
    peers: c.peers,
    error: c.error,
    scale: _scale,
    onScanBle: c.scanBle,
    onConnectBle: c.connectBle,
    onConnectPeer: (peer) async {
      await c.connectPeer(peer);
      if (mounted) setState(() => _section = _Section.room);
    },
    onConnectManual: c.connectManual,
  );

  Widget _page() {
    final c = _controller;
    switch (_section) {
      case _Section.connect:
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(24, 64 * _scale, 24, 8 * _scale),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '当前心率',
                  style: winText(32 * _scale, weight: FontWeight.w700),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: _HeartCard(
                bpm: _currentBpm(),
                series: _currentSeries(),
                scale: _scale,
                font: _bpmFontSize,
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: () => c.scanBle(),
                        icon: const Icon(Icons.bluetooth_searching, size: 18),
                        label: const Text('扫描设备'),
                        style: FilledButton.styleFrom(
                          backgroundColor: WinColors.accent,
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: c.connected
                            ? () async {
                                await c.disconnectAll();
                                if (mounted) setState(() {});
                              }
                            : null,
                        icon: const Icon(Icons.link_off, size: 18),
                        label: const Text('断开连接'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WinColors.accent,
                          side: const BorderSide(color: WinColors.accent),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _deviceList(c)),
          ],
        );
      case _Section.room:
        return RoomView(
          transport: c.transportLabel,
          connected: c.connected,
          members: c.members,
          liveBpm: c.liveBpm,
          seriesFor: c.seriesFor,
          ownBpm: c.ownBpm,
          ownSeries: c.ownSeries,
          showBleRow: c.transport == WinTransport.ble,
          scale: _scale,
          bpmFont: _bpmFontSize,
        );
      case _Section.settings:
        return SettingsView(
          transparent: c.backgroundTransparent,
          onToggleTransparent: c.toggleBackground,
          logPath: StartupLog.path ?? '(未创建)',
          onOpenLogs: () => c.openLogFolder(),
          safeMode: _safeMode,
          version: _version,
          bleDebug: c.bleDebug,
          onToggleBleDebug: c.toggleBleDebug,
          scale: _scale,
          bpmFont: _bpmFontSize,
          onBpmFontChanged: _setBpmFontSize,
        );
    }
  }
}

enum _Section { connect, room, settings }

/// 主窗口最小尺寸（DIP，×UI 缩放）。
const double _minWindowWidth = 720;
const double _minWindowHeight = 480;

/// 自适应阈值（都乘当前缩放）：设备表窄了先丢 RSSI 列，房间卡够宽才两列。
const double _narrowLayoutWidth = 900;
const double _wideLayoutWidth = 1000;

/// 顶部拖拽带高度：和 windows/runner/win32_window.cpp 里上报的矩形一致。
const double _dragStripDip = 28;

/// 心率字号（DIP，24–96 步进 4）：默认 52。
const double minBpmFontSize = 24;
const double maxBpmFontSize = 96;
const double bpmFontSizeStep = 4;
const double defaultBpmFontSize = 52;

double _clampBpmFontSize(double value) {
  final stepped = (value / bpmFontSizeStep).round() * bpmFontSizeStep;
  return stepped.clamp(minBpmFontSize, maxBpmFontSize).toDouble();
}

// ---------------------------------------------------------------- 设计令牌

/// Windows 端浅色配色（照手机截图）。**只是本地常量**，不动 `AppColors`（安卓那份）。
abstract final class WinColors {
  static const bg = Color(0xFFFAF7F7); // 页面背景
  static const surface = Color(0xFFFFFFFF); // 卡片白
  static const surfaceHigh = Color(0xFFF3EFEF); // 次级底（输入框/次级胶囊）
  static const line = Color(0xFFF0EAEA); // 极淡分隔（只用在 1px 分隔，不做描边）
  static const accent = Color(0xFFFF5252); // 主色，与手机同值
  static const accentSoft = Color(0x1FFF5252); // 选中胶囊底
  static const text = Color(0xFF1A1A1A); // 正文近黑
  static const textDim = Color(0xFF9A9A9A); // 次要灰
  static const ok = Color(0xFF34C759);
  static const warn = Color(0xFFFF9F0A);
}

abstract final class WinTheme {
  /// 浅色桌面主题：白卡片 + 近黑正文，字号阶梯 12/14/16/20/32/96。
  static ThemeData data() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: WinColors.accent,
      brightness: Brightness.light,
    ).copyWith(surface: WinColors.surface),
    scaffoldBackgroundColor: WinColors.bg,
    splashFactory: NoSplash.splashFactory,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: WinColors.text),
      bodySmall: TextStyle(color: WinColors.textDim),
    ),
  );
}

TextStyle winText(
  double size, {
  Color color = WinColors.text,
  FontWeight? weight,
}) => TextStyle(
  fontSize: size,
  color: color,
  fontWeight: weight,
  // 名称/心率下面无论如何都不能出现实线：主题与字体回退都不许改这一条。
  decoration: TextDecoration.none,
);

// ------------------------------------------------------- 右上角窗口控件（无标题栏）

final class _WindowControls extends StatelessWidget {
  const _WindowControls({
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onMinimize,
    required this.onClose,
  });

  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  /// 浮在内容区右上角的一小条：缩放 −/＋、最小化、退出。
  /// 没有任何标题栏；拖动靠原生顶部 28 DIP 的拖拽带（HTCAPTION）。
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 6 * scale),
    decoration: BoxDecoration(
      color: WinColors.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: WinColors.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WinButton(
          icon: Icons.remove,
          tooltip: '缩小界面（Ctrl+滚轮）',
          onTap: onZoomOut,
        ),
        _WinButton(icon: Icons.add, tooltip: '放大界面（Ctrl+滚轮）', onTap: onZoomIn),
        _WinButton(icon: Icons.minimize, tooltip: '最小化', onTap: onMinimize),
        _WinButton(
          icon: Icons.power_settings_new,
          tooltip: '退出',
          onTap: onClose,
          danger: true,
        ),
      ],
    ),
  );
}

/// 自绘窗口按钮（没有系统标题栏，最小化/退出只能自己做）。
final class _WinButton extends StatelessWidget {
  const _WinButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: SizedBox(
        width: 30,
        height: 30,
        child: Icon(
          icon,
          size: 14,
          color: danger ? WinColors.accent : WinColors.textDim,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- 底部 tab

/// 心率 / 房间 / 设置：图标 + 文字，选中态粉胶囊。
final class _BottomTabs extends StatelessWidget {
  const _BottomTabs({
    required this.section,
    required this.scale,
    required this.onSelect,
  });

  final _Section section;
  final double scale;
  final ValueChanged<_Section> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    height: 64 * scale,
    padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 6 * scale),
    color: WinColors.surface,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _tab(Icons.favorite, '心率', _Section.connect),
        _tab(Icons.groups_outlined, '房间', _Section.room),
        _tab(Icons.tune, '设置', _Section.settings),
      ],
    ),
  );

  Widget _tab(IconData icon, String label, _Section target) {
    final selected = section == target;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onSelect(target),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 18 * scale,
          vertical: 8 * scale,
        ),
        decoration: BoxDecoration(
          color: selected ? WinColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18 * scale,
              color: selected ? WinColors.accent : WinColors.textDim,
            ),
            SizedBox(width: 6 * scale),
            Text(
              label,
              style: winText(
                14 * scale,
                color: selected ? WinColors.accent : WinColors.textDim,
                weight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 心率主卡

/// 超大心率数字 + 心形底纹 + BPM + 折线（左轴动态刻度、右端「最新」、左端「-60s」）。
final class _HeartCard extends StatelessWidget {
  const _HeartCard({
    required this.bpm,
    required this.series,
    required this.scale,
    required this.font,
  });

  final int? bpm;
  final HeartRateSeries series;
  final double scale;
  final double font;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(24 * scale),
    decoration: BoxDecoration(
      color: WinColors.surface,
      borderRadius: BorderRadius.circular(16 * scale),
    ),
    child: Column(
      children: [
        SizedBox(
          height: font * 1.3 * scale,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.favorite,
                size: font * 1.5 * scale,
                color: WinColors.accent.withValues(alpha: 0.08),
              ),
              Text(
                bpm?.toString() ?? '--',
                maxLines: 1,
                style: winText(
                  font * 2.0 * scale,
                  color: WinColors.text,
                  weight: FontWeight.w700,
                ).copyWith(height: 1.0),
              ),
            ],
          ),
        ),
        SizedBox(height: 4 * scale),
        Text('BPM', style: winText(14 * scale, color: WinColors.textDim)),
        SizedBox(height: 16 * scale),
        Stack(
          children: [
            HeartRateChart(series: series, bpm: bpm, height: 150 * scale),
            Positioned(
              right: 0,
              top: 0,
              child: Text(
                '最新',
                style: winText(11 * scale, color: WinColors.textDim),
              ),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              child: Text(
                '-60s',
                style: winText(11 * scale, color: WinColors.textDim),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- 左侧导航

// ---------------------------------------------------------------- 连接页

final class ConnectView extends StatelessWidget {
  const ConnectView({
    required this.adapterState,
    required this.bleBusy,
    required this.devices,
    required this.peers,
    required this.error,
    required this.onScanBle,
    required this.onConnectBle,
    required this.onConnectPeer,
    required this.onConnectManual,
    this.hiddenDevices = 0,
    this.scale = 1,
    super.key,
  });

  final String adapterState;
  final String bleBusy;
  final List<dynamic> devices;
  final List<dynamic> peers;
  final String? error;
  final Future<void> Function() onScanBle;
  final Future<bool> Function(String id) onConnectBle;
  final Future<void> Function(dynamic peer) onConnectPeer;
  final Future<bool> Function(String address) onConnectManual;

  /// 被「只列心率设备」过滤掉的条数：空状态里给一句排查提示。
  final int hiddenDevices;

  /// UI 缩放：自适应阈值跟着它走（放大 1.6 后在同样的窗口宽度下提前变窄）。
  final double scale;

  @override
  Widget build(BuildContext context) {
    // 窄窗口先丢 RSSI 这一列（次要信息），别把名称和连接按钮挤没。
    final narrow =
        MediaQuery.sizeOf(context).width < _narrowLayoutWidth * scale;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 64 * scale, 16, 16),
      children: [
        _SectionTitle(
          '蓝牙设备',
          trailing: '适配器：${adapterState.isEmpty ? "未知" : adapterState}',
        ),
        _Card(
          child: Column(
            children: [
              if (devices.isEmpty)
                _EmptyState(
                  icon: Icons.bluetooth_disabled,
                  title: '未发现心率设备（蓝牙设备）',
                  bullets: [
                    '确认系统蓝牙已开启（不是飞行模式）',
                    '设备可能被手机 App 占用：蓝牙设备通常只能同时连一台，先在手机上断开',
                    '设备可能在休眠：戴上或按一下机身按键唤醒',
                    '仍扫不到可在 Windows 设置里先配对一次，再回来扫描',
                    if (hiddenDevices > 0)
                      '已过滤 $hiddenDevices 个非心率设备：设置页可打开「显示全部蓝牙设备」排查',
                  ],
                  action: FilledButton.icon(
                    onPressed: () => onScanBle(),
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text('扫描（10 秒）'),
                  ),
                )
              else
                Column(
                  children: [
                    _TableHeader(narrow: narrow),
                    for (final device in devices)
                      _BleRow(
                        device: device,
                        narrow: narrow,
                        onConnect: onConnectBle,
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionTitle('局域网投射（手机）', trailing: '自动发现中'),
        _Card(
          child: peers.isEmpty
              ? _EmptyState(
                  icon: Icons.wifi_find,
                  title: '未发现手机',
                  bullets: const [
                    '手机与电脑要在同一个 Wi-Fi（路由器没开 AP 隔离）',
                    '手机设置里「投射到局域网」要开着（默认开）',
                    'Windows 防火墙允许本程序的"专用网络"',
                  ],
                  action: _ManualIpRow(onConnect: onConnectManual),
                )
              : Column(
                  children: [
                    _ManualIpRow(onConnect: onConnectManual),
                    for (final peer in peers)
                      ListTile(
                        dense: true,
                        title: Text(
                          peer.name,
                          style: winText(AppTextSize.body),
                        ),
                        subtitle: Text(
                          '${peer.platform} · ${peer.members} 人在线',
                          style: winText(
                            AppTextSize.caption,
                            color: WinColors.textDim,
                          ),
                        ),
                        trailing: FilledButton(
                          onPressed: () => onConnectPeer(peer),
                          child: const Text('连接'),
                        ),
                      ),
                  ],
                ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: winText(AppTextSize.caption, color: WinColors.warn),
            ),
          ),
      ],
    );
  }
}

/// 手动 IP:端口 输入：占位提示 + 格式校验（host 或 host:port，端口 1-65535）。
final class _ManualIpRow extends StatefulWidget {
  const _ManualIpRow({required this.onConnect});
  final Future<bool> Function(String address) onConnect;

  @override
  State<_ManualIpRow> createState() => _ManualIpRowState();
}

final class _ManualIpRowState extends State<_ManualIpRow> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请输入手机地址');
      return;
    }
    final parts = raw.split(':');
    final port = parts.length > 1 ? int.tryParse(parts[1]) : 8770;
    if (parts.first.isEmpty || port == null || port < 1 || port > 65535) {
      setState(() => _error = '格式：IP 或 IP:端口（端口 1-65535），例如 192.168.1.20:8770');
      return;
    }
    setState(() => _error = null);
    widget.onConnect(raw);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            style: winText(AppTextSize.body),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '手动连接：手机 IP 或 IP:端口（如 192.168.1.20:8770）',
              hintStyle: winText(AppTextSize.caption, color: WinColors.textDim),
              errorText: _error,
              errorStyle: winText(11, color: WinColors.warn),
              filled: true,
              fillColor: WinColors.surfaceHigh,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: const BorderSide(color: WinColors.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: const BorderSide(color: WinColors.line),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 44,
          child: FilledButton(onPressed: _submit, child: const Text('连接')),
        ),
      ],
    ),
  );
}

final class _BleRow extends StatelessWidget {
  const _BleRow({
    required this.device,
    required this.onConnect,
    this.narrow = false,
  });
  final dynamic device;
  final Future<bool> Function(String id) onConnect;

  /// 窄窗口：RSSI 是次要列，先丢它（名称/地址/按钮留着）。
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onConnect(device.id),
        hoverColor: WinColors.surfaceHigh,
        child: Container(
          height: 44,
          padding: const EdgeInsets.only(right: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: WinColors.line)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  device.name.isEmpty ? '(未命名)' : device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: winText(AppTextSize.body),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  '${device.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
              ),
              if (!narrow)
                SizedBox(
                  width: 64,
                  child: Text(
                    '${device.rssi}',
                    textAlign: TextAlign.right,
                    style: winText(
                      AppTextSize.caption,
                      color: WinColors.textDim,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () => onConnect(device.id),
                child: const Text('连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _TableHeader extends StatelessWidget {
  const _TableHeader({this.narrow = false});

  final bool narrow;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            '名称',
            style: winText(AppTextSize.caption, color: WinColors.textDim),
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            '地址',
            style: winText(AppTextSize.caption, color: WinColors.textDim),
          ),
        ),
        if (!narrow)
          SizedBox(
            width: 64,
            child: Text(
              'RSSI',
              textAlign: TextAlign.right,
              style: winText(AppTextSize.caption, color: WinColors.textDim),
            ),
          ),
        const SizedBox(width: 76),
      ],
    ),
  );
}

// ---------------------------------------------------------------- 房间页

final class RoomView extends StatelessWidget {
  const RoomView({
    required this.transport,
    required this.connected,
    required this.members,
    required this.liveBpm,
    required this.seriesFor,
    required this.ownBpm,
    required this.ownSeries,
    required this.showBleRow,
    this.scale = 1,
    this.bpmFont = defaultBpmFontSize,
    super.key,
  });

  final String transport;
  final bool connected;
  final List<MemberState> members;
  final int? Function(MemberState member) liveBpm;
  final HeartRateSeries Function(String id) seriesFor;
  final int? ownBpm;
  final HeartRateSeries ownSeries;
  final bool showBleRow;

  /// UI 缩放：列数阈值与卡片高度都跟着它走。
  final double scale;

  /// 心率字号（DIP）：卡片高度必须放得下，否则大数字被裁。
  final double bpmFont;

  @override
  Widget build(BuildContext context) {
    if (!connected) {
      return _EmptyState(
        icon: Icons.link_off,
        title: '还没有连上数据源',
        bullets: const ['到「连接」页选一台手机（局域网）或蓝牙设备（蓝牙）'],
        action: const SizedBox.shrink(),
      );
    }
    final cards = <Widget>[];
    if (showBleRow) {
      cards.add(
        _MemberCard(
          name: '蓝牙设备',
          bpm: ownBpm,
          series: ownSeries,
          online: true,
          bpmFont: bpmFont,
        ),
      );
    }
    for (final member in members) {
      cards.add(
        _MemberCard(
          name: member.report.displayName,
          bpm: liveBpm(member),
          series: seriesFor(member.report.memberId),
          online: member.online,
          bpmFont: bpmFont,
        ),
      );
    }
    // 够宽才排两列，窄了单列；卡片高度固定在 96×缩放，列数变高度不变。
    final windowWidth = MediaQuery.sizeOf(context).width;
    final contentWidth = windowWidth - 200; // 导航 168 + 内容区外边距
    final columns = windowWidth >= _wideLayoutWidth * scale ? 2 : 1;
    final cardWidth = (contentWidth - 12 * (columns - 1)) / columns;
    // 卡片高度：放得下心率字号（含行距）+ 上下留白，不小于原来的 96。
    final cardHeight = bpmFont * 1.6 + 32 > 96 ? bpmFont * 1.6 + 32 : 96.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 64 * scale, 16, 16),
      children: [
        _SectionTitle('房间成员', trailing: transport),
        if (cards.isEmpty)
          _EmptyState(
            icon: Icons.hourglass_empty,
            title: '等待心率数据…',
            bullets: const ['手机在房间里上报后，这里会出现成员卡片'],
            action: const SizedBox.shrink(),
          )
        else
          GridView.count(
            crossAxisCount: columns,
            childAspectRatio: cardWidth / (cardHeight * scale),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: cards,
          ),
      ],
    );
  }
}

final class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.name,
    required this.bpm,
    required this.series,
    required this.online,
    this.bpmFont = defaultBpmFontSize,
  });

  final String name;
  final int? bpm;
  final HeartRateSeries series;
  final bool online;
  final double bpmFont;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: WinColors.surfaceHigh,
              child: Text(
                name.isEmpty ? '?' : name.substring(0, 1),
                style: winText(AppTextSize.body, color: WinColors.text),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: winText(AppTextSize.body),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    online ? '在线' : '离线',
                    style: winText(
                      11,
                      color: online ? WinColors.ok : WinColors.textDim,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              online ? (bpm?.toString() ?? '--') : '--',
              maxLines: 1,
              softWrap: false,
              style: winText(
                bpmFont,
                color: online ? WinColors.accent : WinColors.textDim,
                weight: FontWeight.w600,
              ).copyWith(height: 1.1),
            ),
            const SizedBox(width: 4),
            Text('bpm', style: winText(11, color: WinColors.textDim)),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              height: 36,
              child: CustomPaint(painter: WinSparklinePainter(series)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 设置页

final class SettingsView extends StatelessWidget {
  const SettingsView({
    required this.transparent,
    required this.onToggleTransparent,
    required this.logPath,
    required this.onOpenLogs,
    required this.safeMode,
    required this.version,
    this.bleDebug = false,
    this.onToggleBleDebug,
    this.scale = 1,
    this.bpmFont = defaultBpmFontSize,
    this.onBpmFontChanged,
    super.key,
  });

  final bool transparent;
  final VoidCallback onToggleTransparent;
  final String logPath;
  final Future<void> Function() onOpenLogs;
  final bool safeMode;
  final String version;

  /// 隐藏兜底：显示全部蓝牙设备（默认只列广播带 0x180D 的心率设备）。
  final bool bleDebug;
  final VoidCallback? onToggleBleDebug;

  final double scale;

  /// 心率字号（DIP）：主界面卡片与精简态都跟它走。
  final double bpmFont;
  final ValueChanged<double>? onBpmFontChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 64 * scale, 16, 16),
      children: [
        _SectionTitle('显示'),
        _Card(
          child: Column(
            children: [
              SwitchListTile(
                value: transparent,
                onChanged: (_) => onToggleTransparent(),
                title: Text('背景全透明', style: winText(AppTextSize.body)),
                subtitle: Text(
                  '关闭则用深色底；文字与折线始终不透明',
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
              ),
              const Divider(height: 1, color: WinColors.line),
              ListTile(
                title: Text('心率字号', style: winText(AppTextSize.body)),
                subtitle: Slider(
                  value: bpmFont,
                  min: minBpmFontSize,
                  max: maxBpmFontSize,
                  divisions:
                      ((maxBpmFontSize - minBpmFontSize) / bpmFontSizeStep)
                          .round(),
                  label: '${bpmFont.round()}',
                  onChanged: onBpmFontChanged,
                ),
                trailing: Text(
                  '${bpmFont.round()} px',
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
              ),
              const Divider(height: 1, color: WinColors.line),
              SwitchListTile(
                value: bleDebug,
                onChanged: (_) => onToggleBleDebug?.call(),
                title: Text('显示全部蓝牙设备', style: winText(AppTextSize.body)),
                subtitle: Text(
                  '排查用：默认只列广播带心率服务（0x180D）的设备',
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
              ),
              const Divider(height: 1, color: WinColors.line),
              ListTile(
                title: Text('安全模式', style: winText(AppTextSize.body)),
                subtitle: Text(
                  safeMode
                      ? '已开启（不透明窗口 + 不初始化蓝牙）'
                      : '未开启（启动加 --safe-mode 可排查问题）',
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionTitle('诊断'),
        _Card(
          child: Column(
            children: [
              ListTile(
                title: Text('日志目录', style: winText(AppTextSize.body)),
                subtitle: SelectableText(
                  logPath,
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
                trailing: FilledButton(
                  onPressed: () => onOpenLogs(),
                  child: const Text('打开日志'),
                ),
              ),
              const Divider(height: 1, color: WinColors.line),
              ListTile(
                title: Text('版本', style: winText(AppTextSize.body)),
                trailing: Text(
                  version,
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 通用件

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});
  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Text(
          text,
          style: winText(AppTextSize.section, weight: FontWeight.w600),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: winText(AppTextSize.caption, color: WinColors.textDim),
          ),
      ],
    ),
  );
}

final class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  // 用 Material 而不是 DecoratedBox：ListTile/InkWell 的水波纹与悬停高亮要画在
  // 最近的 Material 上，套 DecoratedBox 会把它们盖掉（debug 下还会断言失败）。
  @override
  Widget build(BuildContext context) => Material(
    color: WinColors.surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.card),
      side: const BorderSide(color: WinColors.line),
    ),
    child: child,
  );
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.bullets,
    required this.action,
  });

  final IconData icon;
  final String title;
  final List<String> bullets;
  final Widget action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: WinColors.textDim),
            const SizedBox(width: 8),
            Text(
              title,
              style: winText(AppTextSize.body, weight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final line in bullets)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '· $line',
              style: winText(AppTextSize.caption, color: WinColors.textDim),
            ),
          ),
        const SizedBox(height: 8),
        action,
      ],
    ),
  );
}

final class _FatalView extends StatelessWidget {
  const _FatalView({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: WinColors.bg,
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '启动异常（窗口还在，说明渲染正常）',
            style: winText(AppTextSize.section, color: WinColors.warn),
          ),
          const SizedBox(height: 8),
          SelectableText(
            error,
            style: winText(AppTextSize.caption, color: WinColors.textDim),
          ),
          const SizedBox(height: 8),
          SelectableText(
            '日志：${StartupLog.path ?? "未创建"}',
            style: winText(AppTextSize.caption, color: WinColors.textDim),
          ),
        ],
      ),
    ),
  );
}

/// 迷你折线：与手机悬浮窗同一份 `normalizedPolyline`（≤8s 淡虚线、>8s 断开、#FF5252）。
final class WinSparklinePainter extends CustomPainter {
  WinSparklinePainter(this.series);
  final HeartRateSeries series;

  @override
  void paint(Canvas canvas, Size size) {
    final polyline = normalizedPolyline(series);
    if (polyline.isEmpty) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        Paint()
          ..color = WinColors.textDim.withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
      return;
    }
    Offset map(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    final solid = Paint()
      ..color = WinColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (final segment in polyline.segments) {
      path.moveTo(map(segment.first).dx, map(segment.first).dy);
      for (final point in segment.skip(1)) {
        final offset = map(point);
        path.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(path, solid);
    final bridge = Paint()
      ..color = WinColors.accent.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final (from, to) in polyline.bridges) {
      final a = map(from);
      final b = map(to);
      final delta = b - a;
      final length = delta.distance;
      if (length <= 0) continue;
      final step = delta / length;
      for (var pos = 0.0; pos < length; pos += 5) {
        final end = (pos + 3).clamp(0.0, length);
        canvas.drawLine(a + step * pos, a + step * end, bridge);
      }
    }
    canvas.drawCircle(
      map(polyline.segments.last.last),
      2,
      Paint()..color = WinColors.accent,
    );
  }

  @override
  bool shouldRepaint(WinSparklinePainter old) =>
      old.series.revision != series.revision;
}

/// Windows 入口。
Future<void> runWinApp({bool preview = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  StartupLog.stage('win: runApp');
  runApp(WinApp(preview: preview));
}

String winTransportHint() => Zh.lanTitle;
