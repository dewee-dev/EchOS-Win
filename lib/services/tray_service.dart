// 托盘/菜单栏：镜像 Mac StatusBar。
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_paths.dart';
import 'app_state.dart' show AppState, CheckStateKind;
import 'license_service.dart';

class TrayService with TrayListener {
  static final TrayService instance = TrayService._();
  TrayService._() {
    trayManager.addListener(this);
  }

  AppState get _app => AppState.instance;

  /// 已写入临时目录的图标路径（蓝=代理在生效，橙=未生效）
  String? _trayBlueIcon;
  String? _trayOraIcon;

  /// 代理是否在生效 —— 决定托盘图标颜色。
  ///
  /// ★ TUN 模式**故意不接管系统代理**（流量走虚拟网卡），所以 `proxyReady`
  ///   在 TUN 下恒为 false。只看它的话，TUN 明明正常工作、托盘却一直是橙的。
  ///   凡「代理是否在生效」的判定都要走这个二选一，不能只看系统代理。
  ///
  /// ★ 托盘变蓝的时机（用户拍板）：**自检通过之后**，与主灯同步——
  ///   顺序是 运行绿(灯)→自检黄(灯)→托盘蓝+灯绿。接管了但自检还没过/
  ///   自检未完成的窗口里，托盘保持橙：那时代理虽然"接管了"，隧道质量
  ///   未证实，蓝图标是对外的"一切正常"承诺，不能提前给。
  ///   自检失败（隧道探针也不通）时代理会被自动关停，_proxyActive
  ///   自然回落，无需在此单列。只有国内探针失败、隧道探针通过时，
  ///   与灯色一致判蓝（见下方方案A对齐注释，2026-10-17）。
  // 与灯色判据（方案A）对齐（2026-10-17 用户报三态打架：运行绿灯+自检失败+托盘橙）：
  // 隧道探针通过时国内探针失败只是质量注记（baidu 经隧道绕道超时≠代理没生效），
  // 托盘不该比灯更严——不然灯绿托盘橙，用户不知道该信哪个。
  bool get _proxyActive =>
      (_app.proxyReady || _app.tunActive) &&
      (_app.checkState.kind == CheckStateKind.ok ||
          (_app.checkState.kind == CheckStateKind.failed &&
              !_app.checkState.tunProbeFailed));

  Future<void> init() async {
    await _writeIcons();
    _lastActive = _proxyActive;
    await _applyIcon(_proxyActive);
    await trayManager.setToolTip('EchOS');
    _lastDockIcon = _app.config.showDockIcon;
    _applyDockIcon();
    await _rebuildMenu();
    _app.addListener(_onState);
    // 授权状态一变就重排菜单。托盘菜单的形态跟 AppState 完全脱钩，
    // 少了这条订阅，被吊销的用户手里的菜单会一直停在旧的那一版。
    // 刻意不存句柄：托盘与应用同生共死，没有能走到这里的释放路径，
    // 存一个从不 cancel 的订阅只会让分析器以为它漏了。
    LicenseService.instance.changes.listen((_) => _rebuildMenu());
  }

  /// 上次同步给原生的状态，用于跳过无变化的 platform channel 往返。
  /// AppState 的 notifyListeners() 调用点很多（日志、状态、配置…），
  /// 而每次都会走到这里；无条件重发 IPC 会在高频日志下持续占用 UI 线程，
  /// 表现为右键托盘菜单的 hover 药丸不跟手。
  bool? _lastActive;
  bool? _lastDockIcon;

  void _onState() {
    _rebuildMenu(); // 内部自带内容指纹去重，无变化时直接返回
    final active = _proxyActive;
    if (active != _lastActive) {
      _lastActive = active;
      _applyIcon(active);
    }
    // 配置变化时同步任务栏图标可见性（勾选「在任务栏显示图标」后立即生效）
    final dock = _app.config.showDockIcon;
    if (dock != _lastDockIcon) {
      _lastDockIcon = dock;
      _applyDockIcon();
    }
  }

  /// 任务栏图标可见性：用 window_manager 的 setSkipTaskbar 控制任务栏按钮
  /// （tray_manager 的 setDockIconVisible 是 macOS 专用，Windows 上是空操作）。
  void _applyDockIcon() {
    windowManager.setSkipTaskbar(!_app.config.showDockIcon);
  }

  /// 托盘「ECH 代理」开关：与主界面「启动代理」同口径的授权预检，
  /// 放在异步辅助函数里（点击分发器本身是同步的）。
  Future<void> _toggleWithVerify() async {
    await LicenseService.instance.verify();
    if (LicenseService.instance.blocked) {
      await windowManager.show();
      await windowManager.focus();
      return;
    }
    await _app.toggle();
  }

  /// 原生托盘菜单点击分发（动作语义与 Mac 版/面板一致）
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final app = _app;
    // 界面被锁（激活页）时只放行「显示应用」和「退出」。菜单已经按
    // uiLocked 缩减过一版，这里再挡一道：原生菜单的重建有 IPC 往返，
    // 授权刚变化到菜单刷新之间存在一个窗口，那一下点击必须落空。
    // 会话中途的 unreachable 不算锁：代理开关放行给 _toggleWithVerify，
    // 由它先校验再决定（被拦时亮窗说明原因）。
    if (LicenseService.instance.uiLocked &&
        menuItem.key != 'show' &&
        menuItem.key != 'quit') {
      return;
    }
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
        break;
      case 'toggle':
        // 与主界面「启动代理」同口径：开关代理是「使用授权」的时刻，
        // 先校验再动手。被拦时把窗口亮出来——托盘点选时主窗口多半藏着，
        // 静默拦下的表现就是「点了没反应」；亮出来用户能看到激活页或
        // 状态栏上的原因（吊销/未登记/连不上服务器各有各的提示）。
        // unreachable 不是 hardBlocked：不切激活页（隧道不该为一次抖动
        // 停掉），但新启动照样被门禁拦——亮出主界面让状态栏说明原因。
        // 静默拦下的表现就是「点了没反应」；亮出来用户能看到激活页或
        // 状态栏上的原因（吊销/未登记/连不上服务器各有各的提示）。
        // unreachable 不是 hardBlocked：不切激活页（隧道不该为一次抖动
        // 停掉），但新启动照样被门禁拦——亮出主界面让状态栏说明原因。
        _toggleWithVerify();
        break;
      case 'tun':
        final wantOn = !app.config.tunMode;
        // 开 TUN 要过「管理员权限」和「wintun.dll 是否存在」两道校验，任一不过
        // 都会弹框说明；而托盘状态下主窗口是隐藏的，不先亮出来，用户只会觉得
        // 「点了没反应」。关 TUN 不弹框，就不打扰了。
        if (wantOn) {
          windowManager.show();
          windowManager.focus();
        }
        app.setTunMode(wantOn);
        break;
      case 'update':
        // 先把主窗口带到前台，更新弹窗才不会被埋在不可见的托盘状态下
        windowManager.show();
        windowManager.focus();
        app.checkEverything();
        break;
      case 'dock':
        app.setShowDockIcon(!app.config.showDockIcon);
        break;
      case 'quit':
        quit();
        break;
      default:
        final key = menuItem.key ?? '';
        if (key.startsWith('server-')) {
          final i = int.tryParse(key.substring(7));
          if (i != null && i >= 0 && i < app.config.servers.length) {
            app.select(app.config.servers[i].id);
          }
        }
    }
  }

  /// 真正退出：走 AppState.shutdown() 的完整收尾（还原系统代理 → 停内核
  /// → 写「退出时代理是否在运行」标记 → persist → 排空并关闭日志），与
  /// 关窗隐藏、安装器退出同一条路径。原先只 stop() 不写状态，proxy-state
  /// 停留在上一次会话的旧值，下次启动的自动恢复会无端拉起或静默失效。
  /// 窗口的关闭按钮在未激活时会走这条路（见 main.dart 的 _HideOnClose），
  /// 其余情况窗口的关闭按钮被拦截为「隐藏到托盘」，destroy 也会走同一条路，
  /// 所以退出进程必须直接 exit。
  Future<void> quit() async {
    try {
      await _app.shutdown();
    } catch (_) {}
    exit(0);
  }

  /// 上次 setContextMenu 的内容指纹；内容没变就跳过重建。
  /// 原来每次状态变更都重建原生菜单：若重建恰逢菜单已打开，会清空
  /// 自绘标签表导致「只有底色、无文字」，稍等/重开才恢复。
  String? _menuSig;

  Future<void> _rebuildMenu({bool force = false}) async {
    final app = _app;
    // 缩减口径与主界面门控同一把锁（LicenseService.uiLocked）：被服务器
    // 明确拒绝、或启动以来从未可用——主界面进不去，菜单才缩；会话中途
    // 的 unreachable 不缩（隧道还跑着，代理开关点击自有一层校验兜底，
    // 被拦时亮窗说明原因），否则一次网络抖动就把托盘掏空。
    final locked = LicenseService.instance.uiLocked;
    // v2rayN 风格：运行状态用行首实心圆点表达（开=有点，关=没点），文案固定
    final running = app.isRunning || app.isStarting;
    final servers = app.config.servers;
    // 锁定态进指纹：授权状态变了菜单要跟着换，靠 AppState 的通知是收不到的
    // （LicenseService 是另一个单例，两者互不相干）。
    final sig = [
      locked,
      running,
      app.config.tunMode,
      app.config.showDockIcon,
      servers.length,
      app.selected?.id,
      ...servers.map((s) => '${s.id}:${s.name}'),
    ].join('|');
    if (!force && sig == _menuSig) return;
    _menuSig = sig;
    // 未激活时只剩「显示应用」和「退出」。留着代理开关、TUN、服务器切换这些
    // 项没有意义——主界面根本进不去，点了只是改一些此刻用不上的配置，
    // 还让人以为程序在正常跑。
    if (locked) {
      try {
        await trayManager.setContextMenu(Menu(items: [
          MenuItem(key: 'show', label: '显示应用'),
          MenuItem(type: 'separator'),
          MenuItem(key: 'quit', label: '退出应用'),
        ]));
      } catch (_) {}
      return;
    }
    final items = <MenuItem>[
      MenuItem(key: 'show', label: '显示应用'),
      MenuItem(type: 'separator'),
      MenuItem(key: 'toggle', label: 'ECH 代理', checked: running),
      // TUN 模式开关：与主界面那个是同一个 config.tunMode。
      // 勾选反映「用户意图」（配置值）而非「此刻是否真生效」—— 和主界面口径一致。
      // 不能绑 tunActive（那个还要求 isRunning && 管理员），否则非管理员时
      // 显示未勾选，用户点一下以为没反应，其实是弹了提权框。
      MenuItem(key: 'tun', label: 'TUN 模式', checked: app.config.tunMode),
      MenuItem.submenu(
          key: 'servers',
          label: '代理服务器',
          submenu: Menu(items: [
            for (var i = 0; i < app.config.servers.length; i++)
              MenuItem(
                key: 'server-$i',
                label: app.config.servers[i].name.isEmpty
                    ? '未命名'
                    : app.config.servers[i].name,
                checked: app.selected?.id == app.config.servers[i].id,
              ),
          ])),
      MenuItem(type: 'separator'),
      MenuItem(key: 'update', label: '检查更新'),
      MenuItem(type: 'separator'),
      MenuItem(
          key: 'dock', label: '任务栏显示图标', checked: app.config.showDockIcon),
      MenuItem(key: 'quit', label: '退出应用'),
    ];
    try {
      await trayManager.setContextMenu(Menu(items: items));
    } catch (_) {}
  }

  /// 对齐 Mac 菜单栏：代理在生效（系统代理已接管，或 TUN 已跑起来）→ 蓝；
  /// 否则 → 橙。
  Future<void> _applyIcon(bool active) async {
    if (active) {
      if (_trayBlueIcon != null) {
        await trayManager.setIcon(_trayBlueIcon!);
      }
    } else {
      if (_trayOraIcon != null) {
        await trayManager.setIcon(_trayOraIcon!);
      }
    }
  }

  @override
  void onTrayIconMouseDown() {
    // 左键单击：显示主窗口（Windows 托盘惯例；菜单留给右键）
    windowManager.show();
    windowManager.focus();
  }

  // 右键托盘：菜单由原生侧在收到 WM_RBUTTONUP 时直接弹出（跟随鼠标位置），
  // 不经 Dart 往返。**这里刻意不做「弹出前强制重建菜单」的自愈**（2026-10-10
  // 实测教训）：重建在菜单打开期间送达时（嵌套消息泵会把它送进来），Dart 侧
  // 的条目 ID 注册表立即换成新菜单的自增 ID，而打开中的原生菜单还是旧 ID
  // ——此后点击发出的旧 ID 查不到对应项，所有菜单项静默失效（「点击退出
  // 没效果」）。空白菜单（字体丢失）的根治在原生层：popup 期间重建被暂存、
  // 关闭后原子应用，打开中的菜单自始至终用自己那套一致的标签与 ID。

  /// 把打包的托盘图标写为临时文件供托盘显示（蓝=已接管，橙=未接管）
  Future<void> _writeIcons() async {
    // 托盘图标是应用每次启动都要加载的资源，不是临时文件，放应用数据目录
    // %APPDATA%\EchOS\tray，与 config / logs 同在一处，不进任何 Temp 目录。
    final dir = Directory(
        '${AppPaths.appDataDir.path}${Platform.pathSeparator}tray');
    dir.createSync(recursive: true);

    final blue = File('${dir.path}${Platform.pathSeparator}tray-blue.ico');
    final blueData = await rootBundle.load('assets/tray-blue.ico');
    blue.writeAsBytesSync(blueData.buffer.asUint8List());
    _trayBlueIcon = blue.path;

    final ora = File('${dir.path}${Platform.pathSeparator}tray-ora.ico');
    final oraData = await rootBundle.load('assets/tray-ora.ico');
    ora.writeAsBytesSync(oraData.buffer.asUint8List());
    _trayOraIcon = ora.path;
  }
}
