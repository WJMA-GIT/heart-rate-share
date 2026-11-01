import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/app_version.dart';
import '../../core/platform/startup_log.dart';
import '../widgets/heart_rate_chart.dart';

import 'win_controller.dart';

/// Windows 客户端：**标准系统窗口** + 四块浅色界面（当前心率 / 连接 / 房间 / 设置）。
///
/// 这里不再做任何"自绘客户区/无边框/全透明条带"的花活：它是普通窗口，视图等于客户区，
/// 所以不会出现"UI 在窗口里移动"和文字二次缩放。透明条带由独立的原生悬浮窗负责。
final class WinApp extends StatefulWidget {
  const WinApp({this.controller, this.preview = false, super.key});

  final WinController? controller;

  /// `--connected-preview`：注入 mock 成员并强制「已连接」，给 CI 冒烟用。
  final bool preview;

  @override
  State<WinApp> createState() => _WinAppState();
}

const double _minBpmFont = 24;
const double _maxBpmFont = 96;
const double _bpmFontStep = 4;
const double _defaultBpmFont = 52;

double _clampBpmFont(double value) {
  final stepped = (value / _bpmFontStep).round() * _bpmFontStep;
  return stepped.clamp(_minBpmFont, _maxBpmFont).toDouble();
}

final class _WinAppState extends State<WinApp> {
  WinController? _controller;
  Object? _fatal;
  bool _owns = false;
  String _version = '—';
  double _bpmFont = _defaultBpmFont;
  bool _showChart = true;
  _Section _section = _Section.heart;

  MethodChannel? _overlayChannel;
  bool _overlayShown = false;
  DateTime? _lastOverlayPush;

  static const _bpmKey = 'win.bpmFontSize';
  static const _showChartKey = 'win.showChart';
  static const _buildId = String.fromEnvironment('BUILD_ID');

  WinController get _controller => _controller!;

  @override
  void initState() {
    super.initState();
    try {
      final controller =
          widget.controller ?? WinController(preview: widget.preview);
      _owns = widget.controller == null;
      _controller = controller;
      controller.addListener(_onChange);
      _overlayChannel = const MethodChannel('hrs/win')
        ..setMethodCallHandler((call) async {
          if (call.method == 'overlayDisconnect') {
            StartupLog.info('overlay: disconnect from overlay window');
            await _controller?.disconnectAll();
            if (mounted) setState(() {});
          }
          return null;
        });
      _loadPreferences();
      if (widget.preview) {
        controller.startPreview();
      } else {
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
    _syncOverlay();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final font = prefs.getDouble(_bpmKey);
      final chart = prefs.getBool(_showChartKey);
      if (mounted) {
        setState(() {
          if (font != null) _bpmFont = _clampBpmFont(font);
          if (chart != null) _showChart = chart;
        });
      }
    } catch (_) {}
    await _loadVersion();
  }

  Future<void> _loadVersion() async {
    final raw = await AppVersion.readWithBuild();
    final parts = raw.split('+');
    final build = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : '?';
    final label =
        '${parts.first} ($build) · ${_buildId.isEmpty ? 'dev' : _buildId}';
    StartupLog.info('win: build=$label');
    if (mounted) setState(() => _version = label);
  }

  Future<void> _setBpmFont(double value) async {
    final next = _clampBpmFont(value);
    setState(() => _bpmFont = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bpmKey, next);
    } catch (_) {}
  }

  Future<void> _setShowChart(bool value) async {
    setState(() => _showChart = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showChartKey, value);
    } catch (_) {}
  }

  /// 悬浮窗：连接才显示；数据每秒最多推一次。
  void _syncOverlay() {
    final channel = _overlayChannel;
    if (channel == null) return;
    final connected = _controller?.connected ?? false;
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

  Map<String, Object?> _overlayPayload() {
    final controller = _controller;
    final rows = <Map<String, Object?>>[];
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
    return {'font': _bpmFont, 'rows': rows};
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
  void dispose() {
    _overlayChannel?.setMethodCallHandler(null);
    _controller?.removeListener(_onChange);
    if (_owns) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncOverlay();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: WinTheme.data(),
      home: HomeView(
        controller: _controller,
        fatal: _fatal,
        section: _section,
        onSection: (section) => setState(() => _section = section),
        version: _version,
        bpmFont: _bpmFont,
        showChart: _showChart,
        onBpmFont: _setBpmFont,
        onShowChart: _setShowChart,
        safeMode: Platform.environment['HEARTRATE_SAFE_MODE'] == '1',
      ),
    );
  }
}

enum _Section { heart, room, settings }

// ---------------------------------------------------------------- 设计令牌

/// Windows 浅色配色（本地常量，不动安卓那份 `AppColors`）。
abstract final class WinColors {
  static const bg = Color(0xFFFAF7F7);
  static const card = Color(0xFFFFFFFF);
  static const field = Color(0xFFF5F1F1);
  static const accent = Color(0xFFFF5252);
  static const accentSoft = Color(0x1FFF5252);
  static const text = Color(0xFF1A1A1A);
  static const dim = Color(0xFF9A9A9A);
  static const ok = Color(0xFF34C759);
}

abstract final class WinTheme {
  static ThemeData data() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: WinColors.accent,
      brightness: Brightness.light,
    ).copyWith(surface: WinColors.card),
    scaffoldBackgroundColor: WinColors.bg,
    splashFactory: NoSplash.splashFactory,
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
  decoration: TextDecoration.none,
);

// ---------------------------------------------------------------- 主界面

/// 四块内容共用一个滚动容器，避免再出现"大面积空白 / 控件贴边"。
final class HomeView extends StatelessWidget {
  const HomeView({
    required this.controller,
    required this.fatal,
    required this.section,
    required this.onSection,
    required this.version,
    required this.bpmFont,
    required this.showChart,
    required this.onBpmFont,
    required this.onShowChart,
    required this.safeMode,
    super.key,
  });

  final WinController controller;
  final Object? fatal;
  final _Section section;
  final ValueChanged<_Section> onSection;
  final String version;
  final double bpmFont;
  final bool showChart;
  final ValueChanged<double> onBpmFont;
  final ValueChanged<bool> onShowChart;
  final bool safeMode;

  @override
  Widget build(BuildContext context) {
    if (fatal != null) {
      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('启动异常（窗口正常，只是数据层起不来）',
                  style: winText(20, weight: FontWeight.w600)),
              const SizedBox(height: 12),
              SelectableText('$fatal', style: winText(13, color: WinColors.dim)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: _page()),
          _Tabs(section: section, onSelect: onSection),
        ],
      ),
    );
  }

  Widget _page() {
    switch (section) {
      case _Section.heart:
        return _HeartPage(
          controller: controller,
          bpmFont: bpmFont,
          showChart: showChart,
        );
      case _Section.room:
        return _RoomPage(controller: controller, bpmFont: bpmFont);
      case _Section.settings:
        return _SettingsPage(
          controller: controller,
          version: version,
          bpmFont: bpmFont,
          showChart: showChart,
          onBpmFont: onBpmFont,
          onShowChart: onShowChart,
          safeMode: safeMode,
        );
    }
  }
}

final class _Tabs extends StatelessWidget {
  const _Tabs({required this.section, required this.onSelect});

  final _Section section;
  final ValueChanged<_Section> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    color: WinColors.card,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _tab(Icons.favorite, '心率', _Section.heart),
        const SizedBox(width: 12),
        _tab(Icons.groups_outlined, '房间', _Section.room),
        const SizedBox(width: 12),
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
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? WinColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? WinColors.accent : WinColors.dim),
            const SizedBox(width: 6),
            Text(
              label,
              style: winText(
                14,
                color: selected ? WinColors.accent : WinColors.dim,
                weight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _HeartPage extends StatelessWidget {
  const _HeartPage({
    required this.controller,
    required this.bpmFont,
    required this.showChart,
  });

  final WinController controller;
  final double bpmFont;
  final bool showChart;

  int? get _bpm {
    final own = controller.ownBpm;
    if (own != null) return own;
    for (final member in controller.members) {
      final bpm = controller.liveBpm(member);
      if (bpm != null) return bpm;
    }
    return null;
  }

  HeartRateSeries get _series {
    if (controller.transport == WinTransport.ble) return controller.ownSeries;
    for (final member in controller.members) {
      if (member.online) return controller.seriesFor(member.report.memberId);
    }
    return HeartRateSeries();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
    children: [
      Text('当前心率', style: winText(30, weight: FontWeight.w700)),
      const SizedBox(height: 16),
      _Card(
        child: Column(
          children: [
            SizedBox(
              height: bpmFont * 1.5,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(Icons.favorite, size: bpmFont * 1.6, color: const Color(0x14FF5252)),
                  Text(
                    _bpm?.toString() ?? '--',
                    style: winText(bpmFont * 1.6, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            Text('BPM', style: winText(14, color: WinColors.dim)),
            if (showChart) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 170,
                child: HeartRateChart(series: _series, bpm: _bpm, height: 170),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('-60s', style: winText(11, color: WinColors.dim)),
                  const Spacer(),
                  Text('最新', style: winText(11, color: WinColors.dim)),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: () => controller.scanBle(),
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
                onPressed: controller.connected
                    ? () => controller.disconnectAll()
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
      const SizedBox(height: 16),
      _BleCard(controller: controller),
      const SizedBox(height: 16),
      _LanCard(controller: controller),
      if (controller.error != null) ...[
        const SizedBox(height: 12),
        Text(controller.error!, style: winText(12, color: WinColors.accent)),
      ],
    ],
  );
}

final class _BleCard extends StatelessWidget {
  const _BleCard({required this.controller});

  final WinController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.bleDevices;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle('蓝牙设备', trailing: controller.ble.adapterState),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                '未发现心率设备：确认蓝牙已开、设备没被手机占用、戴上唤醒后再扫描',
                style: winText(12, color: WinColors.dim),
              ),
            )
          else
            for (final device in devices)
              _Row(
                title: device.name.isEmpty ? '(未命名)' : device.name,
                subtitle: '${device.id} · ${device.rssi} dBm',
                action: controller.connected && controller.transport == WinTransport.ble
                    ? const _Badge('已连接')
                    : TextButton(
                        onPressed: () => controller.connectBle(device.id),
                        child: const Text('连接'),
                      ),
              ),
        ],
      ),
    );
  }
}

final class _LanCard extends StatelessWidget {
  const _LanCard({required this.controller});

  final WinController controller;

  @override
  Widget build(BuildContext context) {
    final peers = controller.peers;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle('局域网投射'),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '未发现手机：同一 Wi-Fi、手机端「投射到局域网」开着、允许专用网络',
                style: winText(12, color: WinColors.dim),
              ),
            )
          else
            for (final peer in peers)
              _Row(
                title: peer.name,
                subtitle: '${peer.platform} · ${peer.members} 人在线',
                action: TextButton(
                  onPressed: () => controller.connectPeer(peer),
                  child: const Text('连接'),
                ),
              ),
          _ManualIp(onConnect: controller.connectManual),
        ],
      ),
    );
  }
}

final class _ManualIp extends StatefulWidget {
  const _ManualIp({required this.onConnect});

  final Future<bool> Function(String address) onConnect;

  @override
  State<_ManualIp> createState() => _ManualIpState();
}

final class _ManualIpState extends State<_ManualIp> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请输入手机地址');
      return;
    }
    final parts = raw.split(':');
    final port = parts.length > 1 ? int.tryParse(parts[1]) : 8770;
    if (parts.first.isEmpty || port == null || port < 1 || port > 65535) {
      setState(() => _error = '格式：IP 或 IP:端口，例如 192.168.1.20:8770');
      return;
    }
    setState(() => _error = null);
    widget.onConnect(raw);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 44,
            child: TextField(
              controller: _input,
              style: winText(14),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '手动连接：手机 IP 或 IP:端口',
                hintStyle: winText(13, color: WinColors.dim),
                errorText: _error,
                filled: true,
                fillColor: WinColors.field,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
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

// ---------------------------------------------------------------- 房间页

final class _RoomPage extends StatelessWidget {
  const _RoomPage({required this.controller, required this.bpmFont});

  final WinController controller;
  final double bpmFont;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
    children: [
      Text('房间', style: winText(30, weight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(
        controller.connected ? controller.transportLabel : '未连接',
        style: winText(13, color: WinColors.dim),
      ),
      const SizedBox(height: 16),
      if (controller.members.isEmpty)
        _Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '还没有成员：先在「心率」页连上手机或心率带',
              style: winText(13, color: WinColors.dim),
            ),
          ),
        )
      else
        for (final member in controller.members)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: WinColors.accentSoft,
                      child: Text(
                        member.report.displayName.isEmpty
                            ? '?'
                            : member.report.displayName.substring(0, 1),
                        style: winText(16, color: WinColors.accent),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            member.report.displayName,
                            style: winText(16, weight: FontWeight.w600),
                          ),
                          Text(
                            member.online ? '在线' : '离线',
                            style: winText(
                              12,
                              color: member.online ? WinColors.ok : WinColors.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      member.online
                          ? '${controller.liveBpm(member) ?? '--'}'
                          : '--',
                      style: winText(bpmFont * 0.7, weight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    Text('BPM', style: winText(12, color: WinColors.dim)),
                  ],
                ),
              ),
            ),
          ),
    ],
  );
}

// ---------------------------------------------------------------- 设置页

final class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.controller,
    required this.version,
    required this.bpmFont,
    required this.showChart,
    required this.onBpmFont,
    required this.onShowChart,
    required this.safeMode,
  });

  final WinController controller;
  final String version;
  final double bpmFont;
  final bool showChart;
  final ValueChanged<double> onBpmFont;
  final ValueChanged<bool> onShowChart;
  final bool safeMode;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
    children: [
      Text('设置', style: winText(30, weight: FontWeight.w700)),
      const SizedBox(height: 16),
      _Card(
        child: Column(
          children: [
            SwitchListTile(
              value: showChart,
              onChanged: onShowChart,
              title: Text('显示折线图', style: winText(15)),
              subtitle: Text('关闭后主界面只保留心率数字', style: winText(12, color: WinColors.dim)),
            ),
            const Divider(height: 1, color: Color(0xFFF0EAEA)),
            ListTile(
              title: Text('心率字号', style: winText(15)),
              subtitle: Slider(
                value: bpmFont,
                min: _minBpmFont,
                max: _maxBpmFont,
                divisions: ((_maxBpmFont - _minBpmFont) / _bpmFontStep).round(),
                label: '${bpmFont.round()}',
                onChanged: onBpmFont,
              ),
              trailing: Text('${bpmFont.round()} px', style: winText(12, color: WinColors.dim)),
            ),
            const Divider(height: 1, color: Color(0xFFF0EAEA)),
            SwitchListTile(
              value: controller.bleDebug,
              onChanged: (_) => controller.toggleBleDebug(),
              title: Text('显示全部蓝牙设备', style: winText(15)),
              subtitle: Text('排查用：默认只列广播带 0x180D 的心率设备',
                  style: winText(12, color: WinColors.dim)),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _Card(
        child: Column(
          children: [
            ListTile(
              title: Text('日志目录', style: winText(15)),
              subtitle: Text(StartupLog.path ?? '(未创建)',
                  style: winText(12, color: WinColors.dim)),
              trailing: TextButton(
                onPressed: () => controller.openLogFolder(),
                child: const Text('打开'),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF0EAEA)),
            ListTile(
              title: Text('关于', style: winText(15)),
              subtitle: Text(
                safeMode ? '安全模式（不初始化蓝牙）' : '共享心率 Windows 客户端',
                style: winText(12, color: WinColors.dim),
              ),
              trailing: Text(version, style: winText(12, color: WinColors.dim)),
            ),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- 通用件

final class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: WinColors.card,
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

final class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
    child: Row(
      children: [
        Text(text, style: winText(16, weight: FontWeight.w600)),
        const Spacer(),
        if (trailing != null && trailing!.isNotEmpty)
          Text(trailing!, style: winText(12, color: WinColors.dim)),
      ],
    ),
  );
}

final class _Row extends StatelessWidget {
  const _Row({required this.title, required this.subtitle, required this.action});

  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: winText(15), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(subtitle, style: winText(12, color: WinColors.dim)),
            ],
          ),
        ),
        action,
      ],
    ),
  );
}

final class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: WinColors.accentSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(label, style: winText(12, color: WinColors.accent)),
  );
}

/// Windows 入口。
Future<void> runWinApp({bool preview = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  StartupLog.stage('win: runApp');
  runApp(WinApp(preview: preview));
}
