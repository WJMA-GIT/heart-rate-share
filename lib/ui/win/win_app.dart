import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';
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
  const WinApp({this.controller, super.key});

  final WinController? controller;

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

  /// 缩放持久化键（0.8–1.6，步进 0.1）。
  static const _scaleKey = 'win.scale';

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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_scaleKey, _scale);
    } catch (_) {}
  }

  WinController get _controller => _controllerOrNull!;

  @override
  void initState() {
    super.initState();
    _safeMode = Platform.environment['HEARTRATE_SAFE_MODE'] == '1';
    StartupLog.info('win: init (safeMode=$_safeMode)');
    try {
      final controller = widget.controller ?? WinController();
      _owns = widget.controller == null;
      _controllerOrNull = controller;
      controller.addListener(_onChange);
      _loadScale();
      if (!_safeMode) controller.startDiscovery();
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
    _controllerOrNull?.removeListener(_onChange);
    if (_owns) _controllerOrNull?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        _fatal == null && _controllerOrNull != null && _controller.connected;
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
          // 连上就只留心率行（游戏内挂机不能有干扰）；断开自动回完整界面。
          : connected
          ? _CompactView(
              controller: _controller,
              scale: _scale,
              onDisconnect: () async {
                await _controller.disconnectAll();
                if (mounted) setState(() {});
              },
            )
          : Scaffold(
              backgroundColor: WinColors.bg,
              body: Column(
                children: [
                  _TopBar(
                    controller: _controller,
                    safeMode: _safeMode,
                    scale: _scale,
                    onZoomIn: () => _bumpScale(0.1),
                    onZoomOut: () => _bumpScale(-0.1),
                    onToggleSection: (section) =>
                        setState(() => _section = section),
                    section: _section,
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        _NavRail(
                          section: _section,
                          onSelect: (section) =>
                              setState(() => _section = section),
                          onDrag: startWindowDrag,
                        ),
                        Expanded(child: _page()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _page() {
    final c = _controller;
    switch (_section) {
      case _Section.connect:
        return ConnectView(
          adapterState: c.ble.adapterState,
          bleBusy: c.ble.phase.name,
          devices: [for (final d in c.bleDevices) d],
          peers: c.peers,
          error: c.error,
          onScanBle: c.scanBle,
          onConnectBle: c.connectBle,
          onConnectPeer: (peer) async {
            await c.connectPeer(peer);
            if (mounted) setState(() => _section = _Section.room);
          },
          onConnectManual: c.connectManual,
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
        );
      case _Section.settings:
        return SettingsView(
          transparent: c.backgroundTransparent,
          onToggleTransparent: c.toggleBackground,
          logPath: StartupLog.path ?? '(未创建)',
          onOpenLogs: () => c.openLogFolder(),
          safeMode: _safeMode,
          version: '1.0.8',
        );
    }
  }
}

enum _Section { connect, room, settings }

// ---------------------------------------------------------------- 设计令牌

/// 只是 `AppColors` 的别名：Windows 端**不再有自己的色值**，全部来自手机端共用主题。
abstract final class WinColors {
  static const bg = AppColors.bg;
  static const surface = AppColors.surface;
  static const surfaceHigh = AppColors.surfaceHigh;
  static const line = AppColors.line;
  static const accent = AppColors.brand;
  static const text = AppColors.text;
  static const textDim = AppColors.textDim;
  static const ok = AppColors.ok;
  static const warn = AppColors.warn;
}

abstract final class WinTheme {
  /// 直接复用手机端那套色值/字号（见 lib/theme/app_theme.dart）。
  static ThemeData data() => AppTheme.desktop();
}

TextStyle winText(
  double size, {
  Color color = WinColors.text,
  FontWeight? weight,
}) => TextStyle(fontSize: size, color: color, fontWeight: weight);

// ---------------------------------------------------------------- 顶部状态条

final class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.safeMode,
    required this.section,
    required this.onToggleSection,
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final WinController controller;
  final bool safeMode;
  final _Section section;
  final ValueChanged<_Section> onToggleSection;
  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final connected = controller.connected;
    return GestureDetector(
      onPanStart: (_) => startWindowDrag(),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          color: WinColors.surface,
          border: Border(bottom: BorderSide(color: WinColors.line)),
        ),
        child: Row(
          children: [
            const Icon(Icons.monitor_heart, size: 18, color: WinColors.accent),
            const SizedBox(width: 8),
            Text(
              '共享心率',
              style: winText(AppTextSize.body, weight: FontWeight.w600),
            ),
            const SizedBox(width: 16),
            _Badge(
              label: connected ? '已连接' : '未连接',
              color: connected ? WinColors.ok : WinColors.textDim,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                controller.transportLabel,
                overflow: TextOverflow.ellipsis,
                style: winText(
                  12,
                  color: connected ? WinColors.text : WinColors.textDim,
                ),
              ),
            ),
            const Spacer(),
            if (safeMode)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '安全模式',
                  style: winText(AppTextSize.caption, color: WinColors.warn),
                ),
              ),
            IconButton(
              tooltip: '设置',
              iconSize: 16,
              onPressed: () => onToggleSection(_Section.settings),
              icon: const Icon(Icons.tune, color: WinColors.textDim),
            ),
            // 缩放：0.8–1.6 步进 0.1，持久化；Ctrl+滚轮也能调。
            Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent &&
                    HardwareKeyboard.instance.isControlPressed) {
                  if (event.scrollDelta.dy < 0) {
                    onZoomIn();
                  } else {
                    onZoomOut();
                  }
                }
              },
              child: Row(
                children: [
                  _WinButton(
                    icon: Icons.remove,
                    tooltip: '缩小界面（Ctrl+滚轮）',
                    onTap: onZoomOut,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '${(scale * 100).round()}%',
                      style: winText(
                        AppTextSize.caption,
                        color: WinColors.textDim,
                      ),
                    ),
                  ),
                  _WinButton(
                    icon: Icons.add,
                    tooltip: '放大界面（Ctrl+滚轮）',
                    onTap: onZoomIn,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _WinButton(
              icon: Icons.remove,
              tooltip: '最小化',
              onTap: minimizeWindow,
            ),
            _WinButton(
              icon: Icons.close,
              tooltip: '关闭',
              onTap: closeWindow,
              danger: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊状态徽标：绿=在线/已连接，灰=离线，黄=连接中。
final class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: winText(11, color: color)),
      ],
    ),
  );
}

/// 自绘标题栏按钮（无系统灰条，所以最小化/关闭自己做）。
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

// ---------------------------------------------------------------- 左侧导航

final class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.section,
    required this.onSelect,
    required this.onDrag,
  });

  final _Section section;
  final ValueChanged<_Section> onSelect;
  final VoidCallback onDrag;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => onDrag(),
      child: Container(
        width: 168,
        decoration: const BoxDecoration(
          color: WinColors.surface,
          border: Border(right: BorderSide(color: WinColors.line)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            _item(Icons.bluetooth_searching, '连接', _Section.connect),
            _item(Icons.groups_outlined, '房间', _Section.room),
            _item(Icons.tune, '设置', _Section.settings),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '拖动标题栏移动窗口',
                style: winText(11, color: WinColors.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(IconData icon, String label, _Section target) {
    final selected = section == target;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.button),
        onTap: () => onSelect(target),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? WinColors.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? WinColors.accent : WinColors.textDim,
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: winText(
                  14,
                  color: selected ? WinColors.text : WinColors.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 连接成功后的全透明精简态：只有「名称 | 心率大字 | 迷你折线 | 断开」。
/// 背景用颜色键色（原生 LWA_COLORKEY 抠掉），内容不透明；整块可拖动。
final class _CompactView extends StatelessWidget {
  const _CompactView({
    required this.controller,
    required this.scale,
    required this.onDisconnect,
  });

  final WinController controller;
  final double scale;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (controller.transport == WinTransport.ble) {
      rows.add(
        _CompactRow(
          name: '蓝牙心率带',
          bpm: controller.ownBpm,
          series: controller.ownSeries,
          scale: scale,
          online: true,
        ),
      );
    }
    for (final member in controller.members) {
      rows.add(
        _CompactRow(
          name: member.report.displayName,
          bpm: member.online ? member.report.bpm : null,
          series: controller.seriesFor(member.report.memberId),
          scale: scale,
          online: member.online,
        ),
      );
    }
    if (rows.length > 8) rows.removeRange(8, rows.length); // 8 人上限，不无限长高
    return GestureDetector(
      onPanStart: (_) => startWindowDrag(),
      behavior: HitTestBehavior.translucent,
      child: ColoredBox(
        // 与原生颜色键一致：这一色被抠成全透明，内容照常不透明。
        color: const Color(0xFF010203),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 8 * scale,
            vertical: 6 * scale,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows) row,
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: onDisconnect,
                  icon: const Icon(Icons.link_off, size: 12),
                  label: Text('断开', style: winText(AppTextSize.caption)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 三列固定宽：名称 96×scale / 心率 48×scale 右对齐 / 折线 72×scale。名字再长也不挤动数值。
final class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.name,
    required this.bpm,
    required this.series,
    required this.scale,
    required this.online,
  });

  final String name;
  final int? bpm;
  final HeartRateSeries series;
  final double scale;
  final bool online;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 22 * scale,
    child: Row(
      children: [
        SizedBox(
          width: 96 * scale,
          child: Tooltip(
            message: name,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: winText(
                AppTextSize.caption,
                color: online ? Colors.white : WinColors.textDim,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 48 * scale,
          child: Text(
            online ? (bpm?.toString() ?? '--') : '--',
            textAlign: TextAlign.right,
            style: winText(
              AppTextSize.body * (1 + (scale - 1) * 0.2),
              color: online ? WinColors.accent : WinColors.textDim,
              weight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 72 * scale,
          height: 18 * scale,
          child: CustomPaint(painter: WinSparklinePainter(series)),
        ),
      ],
    ),
  );
}

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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle(
          '蓝牙心率带',
          trailing: '适配器：${adapterState.isEmpty ? "未知" : adapterState}',
        ),
        _Card(
          child: Column(
            children: [
              if (devices.isEmpty)
                _EmptyState(
                  icon: Icons.bluetooth_disabled,
                  title: '未发现蓝牙设备',
                  bullets: const [
                    '确认系统蓝牙已开启（不是飞行模式）',
                    '心率带可能被手机 App 占用：BLE 心率带通常只能同时连一台，先在手机上断开',
                    '心率带可能在休眠：戴上或按一下机身按键唤醒',
                    '仍扫不到可在 Windows 设置里先配对一次，再回来扫描',
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
                    _TableHeader(),
                    for (final device in devices)
                      _BleRow(device: device, onConnect: onConnectBle),
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
  const _BleRow({required this.device, required this.onConnect});
  final dynamic device;
  final Future<bool> Function(String id) onConnect;

  @override
  Widget build(BuildContext context) {
    final hrs = device.isHrsCandidate == true;
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
                  device.name.isEmpty ? device.id : device.name,
                  style: winText(AppTextSize.body),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  hrs ? '心率带' : '其他 BLE',
                  style: winText(
                    12,
                    color: hrs ? WinColors.accent : WinColors.textDim,
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  '${device.rssi}',
                  textAlign: TextAlign.right,
                  style: winText(AppTextSize.caption, color: WinColors.textDim),
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
          flex: 2,
          child: Text(
            '类型',
            style: winText(AppTextSize.caption, color: WinColors.textDim),
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    if (!connected) {
      return _EmptyState(
        icon: Icons.link_off,
        title: '还没有连上数据源',
        bullets: const ['到「连接」页选一台手机（局域网）或心率带（蓝牙）'],
        action: const SizedBox.shrink(),
      );
    }
    final cards = <Widget>[];
    if (showBleRow) {
      cards.add(
        _MemberCard(
          name: '蓝牙心率带',
          bpm: ownBpm,
          series: ownSeries,
          online: true,
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
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
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
            crossAxisCount: 2,
            childAspectRatio: 3.1,
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
  });

  final String name;
  final int? bpm;
  final HeartRateSeries series;
  final bool online;

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
              style: winText(
                28,
                color: online ? WinColors.accent : WinColors.textDim,
                weight: FontWeight.w600,
              ),
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
    super.key,
  });

  final bool transparent;
  final VoidCallback onToggleTransparent;
  final String logPath;
  final Future<void> Function() onOpenLogs;
  final bool safeMode;
  final String version;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
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
Future<void> runWinApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  StartupLog.stage('win: runApp');
  runApp(const WinApp());
}

String winTransportHint() => Zh.lanTitle;
