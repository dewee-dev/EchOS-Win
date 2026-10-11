// 授权：激活、校验、以及「此刻要不要拦着用户」。
//
// ## 整体模型（服务端签码，客户端只是照着走）
//   1. 客户端算出设备码（见 device_identity.dart）：ECHC-XXXX-XXXX-XXXX-XXXX。
//   2. 用户在 TG 机器人那侧拿到激活码，自助路径按服务端的放行模式分两种：
//      自动放行发 /active <设备码> 直接出码；登记放行先 /bind
//      <设备码>，管理员确认后发 /active（不带参数）出码。
//      模式由服务端定，客户端不感知、也不需要感知。
//   3. 用户把激活码（ECHS-XXXX-XXXX-XXXX-XXXX）填回客户端窗口，客户端调
//      /activate 去「领」。领的动作只是把服务端那条记录从 pending 改成
//      active，不做任何分配。
//   4. 之后每次启动，客户端调 /verify 问一句「我还算数吗」。纯读，零写入。
//
// ## 只有三种情况不拦，其余一律拦
//   active          本次联网校验通过
//   notConfigured   构建时没注入 ECHOS_LICENSE_URL（本地开发包）
//   enforcementOff  服务端把全局强制开关关了（管理员手动打开的逃生门）
// 其余情况——没登记、码没领、被吊销、连不上、返回看不懂——一律拦。
//
// ## 为什么连不上也拦
// 原来有过一段宽限期（离线 7 天内照常放行），已经删掉。它挡不住真正要挡的
// 那种事：吊销只在管理员动手的那一刻生效，而客户端要等下次联网才看得到，
// 断着网时那 7 天等于给吊销开了个洞。
//
// 现行口径分两档（见 blocked 的注释）：
//   · 没有本地凭证的断网（从未激活 / 上次结论已是否定——否定结论会清掉
//     「上次校验成功」时间戳）→ 照拦。吊销后拔网线重启绕不过去：时间戳
//     在吊销落地那一刻就没了。
//   · 留有凭证的断网 → 不拦，与会话中途断网同款（拦新不杀旧）。重启不比
//     会话更危险；反过来拦死它是死锁——直连被劫持的环境里校验恰恰要靠
//     隧道跑起来才通（2026-10-10 TUN 提权实测）。
// 服务端故障的逃生门不变：管理员关 enforce，所有客户端立刻恢复可用。
// 客户端这边不留、也不该留任何后门，否则那个开关就只是在给自己开后门。
//
// ## 激活信息存在哪、为什么不会被顺走
// %APPDATA%\EchOS\license.json，只存设备码、激活码、上次校验成功时间。
// 刻意不放进 data/ 目录，也不进 AppConfig：分享、配置备份、WebDAV 备份
// 走的全是 AppConfig 的 JSON，激活信息一旦进了那里就等于随备份外传，
// 换机一还原就变成「拿别人的授权」。
// 卸载只删安装目录（installer/EchOS.iss 的 [UninstallDelete] 只写了 {app}），
// %APPDATA% 下的东西一律留着，重装后不必重新激活。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';
import 'app_version.dart';
import 'device_identity.dart';
import 'log_service.dart';
import '../models/config.dart';

/// 客户端在授权这件事上的全部状态。界面直接按这个分支，不自己拼字符串判断。
enum LicenseStage {
  /// 还没问过服务端（启动瞬间）。
  unknown,

  /// 没配授权服务地址：不拦截，本地开发用。
  notConfigured,

  /// 服务端不认识这台设备：还没人给它发过码。
  unregistered,

  /// 服务端已经给这台设备发过码，但用户还没把码填进来领。
  codeIssued,

  /// 已激活，且本次联网校验通过。
  active,

  /// 授权被吊销。
  revoked,

  /// 授权被管理员封禁（黑名单）。与吊销的处置相同：立即停代理。
  /// 区别只在管理侧的语义——吊销针对这台设备，封禁针对这个人。
  banned,

  /// 服务端把全局强制校验关了，所有设备一律放行。
  /// 这一档**不代表本机已激活**——它只表示服务端此刻不拦。界面上不能拿它
  /// 显示「已激活」，否则管理员关掉开关做排查时，所有用户都会以为自己有授权。
  enforcementOff,

  /// 网络异常 / 服务端返回看不懂的东西。一律拦。
  unreachable,
}

/// 一次校验/激活的结果。ok 只表示「这一步网络往返成功且服务端认了」，
/// 不等于「已激活」—— 想问激活状态看 stage。
class LicenseResult {
  final bool ok;
  final LicenseStage stage;
  final String message;

  /// 这一发是「手动校验节流命中」的维持现状答复：没有产生任何新信息
  ///（没发请求、没到结论），界面**不应**据此刷新消息行——否则断网时
  /// 连点按钮，状态行会在「连接失败」（真实失败）与旧档位结论（节流
  /// 答复带 ok:true）之间来回翻面。
  final bool throttled;
  const LicenseResult(this.ok, this.stage, this.message,
      {this.throttled = false});
}

class LicenseService {
  static final LicenseService instance = LicenseService._();
  LicenseService._();

  /// 授权服务地址。构建期注入：--dart-define=ECHOS_LICENSE_URL=https://xxx.workers.dev
  /// 为空 = 不启用授权（见文件头「关于不配置就不拦截」）。
  static const String baseUrl = String.fromEnvironment('ECHOS_LICENSE_URL');

  static bool get enabled => baseUrl.trim().isNotEmpty;

  Timer? _timer;
  LicenseStage _stage = LicenseStage.unknown;
  String _message = '';
  DateTime? _lastVerifiedAt;
  String _code = '';
  final _changes = StreamController<LicenseStage>.broadcast();

  /// 推送在线时的慢速兜底校验间隔（分钟）。见 bootstrap 里 300 秒定时器的说明：
  /// 推送是尽力而为的通知，丢一次就让吊销无限期不被察觉，这条是唯一的保底。
  static const int _safetyNetMinutes = 60;

  /// 最近一次**真正发出** /verify 的时刻（TTL 抑制掉的、重复在途的都不计）。
  /// 慢速兜底据此判断「距上次问过多久了」。
  DateTime? _lastVerifyAt;

  LicenseStage get stage => _stage;
  String get message => _message;

  /// bootstrap 是否完成（联网校验已出结果）。完成前的界面只显示
  /// 「正在校验授权…」的启动页，不显示主界面也不显示激活页——
  /// 两条路都不该在校验结果出来之前出现。
  bool _bootstrapped = false;
  bool get bootstrapped => _bootstrapped;

  /// 本次运行是否**曾经**拿到过「可用」结论（active / 放行 / 未配置）。
  /// 启动首验 unreachable 时界面据此留在激活页（授权弹窗）等恢复，而不是
  /// 落进主界面挂着红字角标——「拦新」在启动这一关也该拦界面；而一旦
  /// 进过主界面，之后的 unreachable 只是会话中的抖动，不再把人踢去激活页
  /// （拦新不杀旧的既有口径，见 hardBlocked 的注释）。
  bool _everUsable = false;
  bool get everUsable => _everUsable;

  /// 界面是否被锁在激活页（主界面进不去）。main.dart 的 home 门控与
  /// 托盘菜单的缩减共用这一个口径：hardBlocked（服务器明确说不），或
  /// 「既没有本会话的可用记录、也没有本地凭证」的 unreachable——后者
  /// 是全新机器或上次结论已是否定的机器断网启动，没有可保的会话。
  /// 留着「上次校验成功」时间戳的断网启动不锁（拦新不杀旧跨重启，
  /// 见 blocked 的注释）：主界面照常、代理照常恢复，校验在网络回来
  /// （通常就是隧道跑起来）后几秒内追上结论。
  bool get uiLocked =>
      hardBlocked ||
      (_stage == LicenseStage.unreachable &&
          !_everUsable &&
          _lastVerifiedAt == null);

  /// 最近一次授权请求是否因网络失败。与 stage 解耦：硬拦档位
  /// （吊销/封禁等）在断网时被保留，此时 stage 不再是 unreachable，
  /// 界面要判断「此刻到底是不是断网」只能看这里。
  bool get netDown => _netDown;
  DateTime? get lastVerifiedAt => _lastVerifiedAt;
  String get deviceCode => DeviceIdentity.current;

  /// 本地已存的激活码。界面上预填它：用户重装 App（不重装系统）时不用重输。
  String get savedCode => _code;

  /// 是否要把用户挡在激活窗口后面。托盘菜单、关闭按钮、状态栏全看这一个值，
  /// 各处自己判断一遍的话，迟早有一处漏判，用户就从那儿绕进去了。
  ///
  /// unreachable 有一档例外：本地还留着「上次校验成功」的时间戳——每个
  /// 否定结论（吊销/封禁/未登记/换码）都会把它清掉，所以它存在就意味着
  /// 这台机器最后一次从服务器拿到的答复是可用，此刻只是网络断了。对它的
  /// 处置与会话中途断网完全同款（拦新不杀旧）：不拦。重启并不比会话中断
  /// 网更危险——一个断网用户重启得不到任何会话里没有的东西；而拦死它的
  /// 代价是死锁（直连被劫持的环境里：校验不通 → 不恢复代理 → 校验永远
  /// 不通，2026-10-10 TUN 提权实测踩中）。时间戳为空的断网（从未激活 /
  /// 上次结论已是否定）照拦——「吊销后拔网线重启绕过拦截」从这儿走不通：
  /// 吊销结论落地的那一刻时间戳就被清了。

  bool get blocked =>
      _stage != LicenseStage.active &&
      _stage != LicenseStage.notConfigured &&
      _stage != LicenseStage.enforcementOff &&
      !(_stage == LicenseStage.unreachable && _lastVerifiedAt != null);

  /// blocked 里「服务器明确说不」的那一档：未登记、码未领、码被换、被吊销。
  /// 与 unreachable（只是这一刻问不到答案）分开：后者本机多半是有授权的，
  /// 正在跑的会话不该被殃及——关窗口照常隐藏到托盘，等复查恢复。
  /// 两个词对应两种处置：hardBlocked 停隧道/关窗即退，blocked 只是进不了
  /// 主界面、起不了新隧道。
  bool get hardBlocked => blocked && _stage != LicenseStage.unreachable;

  Stream<LicenseStage> get changes => _changes.stream;

  /// 重发一遍当前状态的事件。激活成功后主界面靠这个事件切页，
  /// 广播投递万一被吞（监听器时序、微任务竞争），补一发就能把
  /// 卡在激活页的实例拉回主界面；对已切换的实例是无害的幂等重建。
  void resync() {
    if (!_changes.isClosed) _changes.add(_stage);
  }

  /// 落盘位置见文件头「激活信息存在哪」。不进 data/ 目录是为了不会被
  /// 配置备份和 WebDAV 备份带走；不进 AppConfig 是同一个道理。
  File get _storeFile =>
      File('${AppPaths.appDataDir.path}${Platform.pathSeparator}license.json');

  // -------------------------------------------------------------------------
  // 启动流程
  // -------------------------------------------------------------------------

  /// 读本地状态 → 联网校验 → 起定时复查。启动时调一次。
  Future<void> bootstrap() async {
    _loadLocal();
    // 代理优先偏好跨重启（net-pref.txt，见 _savePreferProxyPref）：
    // 载入要在首验之前——被劫持环境的第一枪就该走能通的路。
    _preferProxy = _loadPreferProxyPref();
    if (!enabled) {
      _bootstrapped = true;
      _authLog('本构建未配置授权服务器（缺少 ECHOS_LICENSE_URL）：'
          '属本地开发构建，不做任何校验与拦截');
      _set(LicenseStage.notConfigured, '未配置授权服务器（本地构建）');
      return;
    }
    // 校验在途：状态行如实显示进行时（启动页读这条）。
    _message = '正在校验授权…';
    _authLog('=== 启动：开始本次授权校验（设备 $deviceCode，客户端版本 $kAppVersionTag）===');
    await verify(source: '启动校验');
    // 联网启动顺手刷新一次 TG 群邀请链接缓存（与授权校验同一条通道）。
    // 需要它的激活页恰恰常在断网场景打开，等到那时再取就晚了；趁联网
    // 先备好，断网的激活页直接用缓存显示按钮。一个 GET，几百字节。
    if (!netDown) unawaited(fetchInviteLink());
    _timer?.cancel();
    // 启动后 90 秒补查（事件驱动改造后仅 WS 掉线时才有意义：KV 最终
    // 一致 ~60 秒，推送在线时 resync 会自己来，掉线时这枪补窗口）。
    Timer(const Duration(seconds: 90), () {
      if (!_changes.isClosed && !pushLive) verify(source: '启动补查');
    });
    // 掉线兜底轮询：WS 在线时 tick 直接跳过（管理端操作由 resync 秒级
    // 送达，事后无需轮询"补"）；WS 掉线时才真正发请求，按连续掉线时长
    // 指数降档（5→10→15 分钟封顶），掉线起点由 pushOutageMinutes 统一
    // 记账（含在线清零），此处不再各写一份。
    // 可见性只在线时一票否决（托盘驻留原口径）；**掉线时可见与否都轮询**
    // ——旧口径"状态由推送/操作对齐"在推送掉线后前提落空，2026-10-07
    // 实测：后台吊销 + 托盘挂起 + 推送断线，三者叠加时吊销感知无限期。
    _timer = Timer.periodic(const Duration(seconds: 300), (_) {
      if (pushLive) {
        // 推送在线时仍保留一条**慢速兜底**（默认 60 分钟一次）。
        //
        // 为什么必须有：推送是「尽力而为」的通知，不是可靠队列——WS 消息
        // 可能在线路半开时无声丢失（pong 新鲜度要 90 秒才识破），广播侧
        // 也偶发丢弃（2026-10-08 曾实测：04:09 吊销，客户端一直没收到
        // 推送，到 04:13:56 用户点托盘才被前台校验发现，中间约 5 分钟
        // 正常代理）；而连接健康时下面两条兜底全被挡在门外，结果就是
        // **通知一丢，吊销永远不被察觉**。
        //
        // 代价极低：走普通 verify（非 force），服务端 TTL 会把绝大多数
        // 请求抑制掉（revalidateAfter=3600），实际每小时最多一发，
        // 100 客户端也就每天几千次读，远在免费额度内。
        final sinceLast = _lastVerifyAt == null
            ? null
            : DateTime.now().difference(_lastVerifyAt!);
        if (sinceLast != null && sinceLast.inMinutes < _safetyNetMinutes) return;
        _authLog('推送在线，慢速兜底校验（距上次 ${sinceLast?.inMinutes ?? -1} 分钟）');
        verify(source: '慢速兜底');
        return;
      }
      final minsDown = pushOutageMinutes;
      // 掉线时长 → 轮询间隔：0~10 分钟每 tick（5 分钟）问一次，
      // 10~20 分钟每两 tick 问一次，之后每三 tick。掉得越久越省，
      // 刚掉线那几分钟最敏感。
      final step = minsDown >= 20 ? 3 : (minsDown >= 10 ? 2 : 1);
      if (_outageTicks % step != 0) {
        _outageTicks++;
        return;
      }
      _outageTicks++;
      _authLog('推送通道掉线中（$minsDown 分钟），轮询兜底第 $_outageTicks 次');
      verify(source: '掉线轮询');
    });
    // 实时推送通道：管理端操作后秒级收到 resync（见 _connectPush）。
    _connectPush();
    // 标志最后置位 + 补发一次当前状态：runApp 先于 bootstrap 完成，
    // 根界面此时才订阅 changes——bootstrap 期间发过的事件它没赶上，
    // 不补发的话首帧之后界面就停在启动页不切换。
    _bootstrapped = true;
    resync();
  }

// 实时推送通道（_connectPush 及其辅助）。

  WebSocket? _ws;
  Timer? _wsRetry;
  Timer? _wsPing;
  bool _wsConnecting = false;
  int _wsBackoff = 0;

  /// 推送通道是否在线。判定加「pong 新鲜度」：readyState==open 只是
  /// 「还没发现断」，半开连接要等 30s+10s 探活才暴露——那段假在线
  /// 期间 pushLive 若仍为真，「在线就不轮询」的门会把吊销感知恶化成
  /// 无限期。pong 90 秒没到就当不在线（心跳 30s 一发，90s = 3 个周期
  /// 全丢，只可能是连接已死），客户端自动切回轮询兜底。
  bool get pushLive =>
      _ws != null &&
      _ws!.readyState == WebSocket.open &&
      _lastPongAt.isAfter(DateTime.now().subtract(const Duration(seconds: 90)));

  /// 连接实时推送通道：管理端操作（吊销/恢复）后服务端广播一句
  /// resync，收到即立刻重新校验——吊销感知从分钟级压到秒级。
  ///
  /// 通道只是「催一下」的信号，不含任何授权语义：收到后走的就是
  /// 与手动校验完全相同的 verify()，服务端的答复才是权威。
  /// 断线/失败按指数退避重连（5s→60s 封顶）；通道不可用不影响
  /// 任何判定——轮询节奏原样兜底。
  void _connectPush() {
    if (!enabled || disposed || _wsConnecting || pushLive) return;
    _wsConnecting = true;
    final base = baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    WebSocket.connect('$base/ws').then((ws) {
      _ws = ws;
      _wsConnecting = false;
      _wsBackoff = 0;
      _wsRetry?.cancel();
      // 推送通道的连接/断开/收包全部留痕：客户端日志是「吊销没及时生效」
      // 这类问题唯一的现场（服务端只有广播失败的一行 console），没有这几行，
      // 事后分不清「服务端没推」「通道断了」还是「消息在线路上丢了」。
      _authLog('推送通道已连接（管理端吊销/恢复可秒级送达）');
      // pong 窗口从「连上」这一刻起算：_lastPongAt 若还停在上一条连接的
      // 旧值（重连场景）或构造时的初始值（首次连接），第一条心跳的 10 秒
      // 探活会把一条刚建好、健康的连接误判成半开而断掉——每条连接固定
      // 在 30+10 秒时自杀、5 秒后重连，循环往复。
      _lastPongAt = DateTime.now();
      _startPing(ws);
      // 通道上线也广播一次内部事件：主界面侧据此暂停运行期轮询。
      // 同样只在翻转时发（对照 _schedulePushReconnect）。
      if (_lastPushLiveEvent != true && !_changes.isClosed) {
        _lastPushLiveEvent = true;
        _changes.add(_stage);
      }
      // 重连成功立即补一课（0~5 秒随机延迟）：resync 广播不持久化，
      // 掉线窗口里管理端做过的操作（吊销/恢复/换码）永远不会再推来，
      // 掉线前的旧状态要靠这次主动校验对齐。随机延迟把「全量客户端
      // 同时重连→同时 verify」的部署瞬间尖峰摊开（CF 部署必断连）。
      Future.delayed(Duration(milliseconds: 500 + _rnd(4500)), () {
        if (!disposed && pushLive) verify(source: '重连补课');
      });
      ws.listen((data) {
        if (data == 'pong') { _lastPongAt = DateTime.now(); return; }
        // resync = 服务端主动说「状态变了」——TTL 是"没事件时的节奏"，
        // 这就是事件，force 击穿立即问。
        if (data == 'resync') {
          _authLog('收到服务端 resync 推送：状态有变，立即校验');
          // 打标记放在这里而不是校验分支里判断：verify 有在途去重，
          // resync 恰好撞上一个在途请求时会直接复用那个 Future，
          // 若标记挂在分支里，这一次询问就没有「刚被 resync 催过」的上下文，
          // 确认复核会被跳过。标记在收到的那一刻就落，合并与否都不丢。
          _resyncSeenAt = DateTime.now();
          verify(force: true, source: 'resync推送');
        }
      }, onDone: () {
        // 迟到的收尾事件守卫：旧连接的 close 可能在新连接已建成后送达，
        // 无条件清空会把新连接的引用与心跳一起杀掉（多 socket 并存、
        // pushLive 恒 false 的根源）。
        if (!identical(_ws, ws)) return;
        _ws = null;
        _stopPing();
        _wsOutageStart ??= DateTime.now();
        _authLog('推送通道断开（对端关闭），自动重连中');
        _schedulePushReconnect();
      }, onError: (e) {
        if (!identical(_ws, ws)) return;
        _ws = null;
        _stopPing();
        _wsOutageStart ??= DateTime.now();
        _authLog('推送通道出错（${describeNetError(e) ?? e.runtimeType}），自动重连中');
        _schedulePushReconnect();
      });
    }).catchError((_) {
      _wsConnecting = false;
      _schedulePushReconnect();
    });
  }

  void _schedulePushReconnect() {
    if (!enabled) return;
    // 指数退避：5s、10s、20s、40s，封顶 60s。
    final delay = Duration(seconds: _wsBackoff < 4 ? 5 << _wsBackoff : 60);
    _wsBackoff++;
    _wsRetry?.cancel();
    _wsRetry = Timer(delay, _connectPush);
    // 掉线也要让主界面侧知道：恢复运行期轮询。只在「在线→掉线」翻转时
    // 发一次——退避期内每次排程都发的话，5~60s 一个的事件风暴会拖着
    // 整棵 UI 树空转，信息量却为零。
    if (_lastPushLiveEvent != false && !_changes.isClosed) {
      _lastPushLiveEvent = false;
      _changes.add(_stage);
    }
  }

  /// 推送通道「在线/掉线」上次广播的状态：事件只在翻转时发。
  bool? _lastPushLiveEvent;

  /// 30 秒一次心跳：发 ping，10 秒内没等到 pong 视同半开连接，
  /// 主动断开走重连。静默死掉的 WS 若无此探活，可能长时间不报错。
  void _startPing(WebSocket ws) {
    _wsPing?.cancel();
    _wsPing = Timer.periodic(const Duration(seconds: 30), (_) {
      if (ws.readyState != WebSocket.open) return;
      Timer(const Duration(seconds: 10), () {
        if (_ws == ws &&
            ws.readyState == WebSocket.open &&
            _lastPongAt.isBefore(DateTime.now().subtract(const Duration(seconds: 10)))) {
          _lastPongAt = DateTime.fromMillisecondsSinceEpoch(0);
          ws.close();
        }
      });
      ws.add('ping');
    });
  }

  void _stopPing() {
    _wsPing?.cancel();
    _wsPing = null;
  }

  DateTime _lastPongAt = DateTime.now();

  /// 0..max-1 的随机数，摊平重连风暴用。
  static int _rnd(int max) => DateTime.now().microsecondsSinceEpoch % max;
  /// 服务端指示的"最早下次校验时间"（revalidateAfter）；null=无指示不抑制。
  DateTime? _revalidateAt;
  /// 掉线兜底轮询的计数与起点（指数降档用）。
  int _outageTicks = 0;
  DateTime? _wsOutageStart;

  /// 推送通道已连续掉线多少分钟（在线时为 0）。运行期轮询与空闲
  /// 兜底共用这一个起点判定降档档位。
  int get pushOutageMinutes {
    if (pushLive) {
      _wsOutageStart = null;
      return 0;
    }
    final start = _wsOutageStart;
    if (start == null) return 0;
    return DateTime.now().difference(start).inMinutes;
  }
  /// dispose 后不再补课（防止延迟回调打在已关闭的流上）。
  bool disposed = false;

  /// resync 之后的确认复核：刚被服务端催过就拿到 active 时补一枪。
  ///
  /// 为什么要这一枪：管理端写完 KV 立刻广播，客户端往往在写入后 1~2 秒
  /// 就来问，而 Cloudflare KV 的写此刻还没收敛到它读的那个边缘节点——
  /// 拿到的是**写入前的旧值 active**（生产实测收敛约 4.4 秒）。这份答复
  /// 在客户端看来完全权威：于是 TTL 被推到一小时、状态被记成有效，
  /// 而推送在线时不会有第二次询问，**这次吊销就永久丢失了**，直到
  /// 用户手动打开窗口。2026-10-08 实测：05:47 吊销，客户端 05:47:34 被
  /// resync 催着问了一次、得到 200 active，之后代理一直正常。
  ///
  /// 间隔取 30 秒：实测收敛约 4.4 秒，30 秒留了近 7 倍余量；等待对用户
  /// 完全无感（他不会盯着进度条），却把「永久丢失」压成「最多 30 秒延迟」。
  /// 复核走 force：这次必须真问，TTL 拦不住它。
  ///
  /// 只在「刚收到 resync」时排：平时那些主动校验（轮询、启动、回前台）
  /// 不需要额外这一枪——它们本来就是去拿最新状态的。
  void _scheduleResyncConfirm() {
    final seen = _resyncSeenAt;
    if (seen == null) return;
    final waited = DateTime.now().difference(seen);
    // 标记是旧的（比如上一次 resync 的确认已经排过、或中途又问了几轮）：
    // 再补这一枪没有意义，跳过即可。
    if (waited.inSeconds > _resyncConfirmWindow.inSeconds) {
      _resyncSeenAt = null;
      return;
    }
    _resyncSeenAt = null;
    _resyncConfirm?.cancel();
    _resyncConfirm = Timer(_resyncConfirmWindow, () {
      if (disposed) return;
      _authLog('resync 后确认复核：刚才那份「有效」有可能读到 KV 旧值，'
          '现在重新问一次（间隔 ${_resyncConfirmWindow.inSeconds} 秒）');
      verify(force: true, source: 'resync确认');
    });
  }

  /// resync 确认复核的等待时长。
  static const Duration _resyncConfirmWindow = Duration(seconds: 30);

  void dispose() {
    disposed = true;
    _timer?.cancel();
    _quickRetry?.cancel();
    _rateRetry?.cancel();
    _resyncConfirm?.cancel();
    _negConfirm?.cancel();
    _cutRecheck?.cancel();
    _wsRetry?.cancel();
    _stopPing();
    _ws?.close();
    _ws = null;
    _timer = null;
    _changes.close();
  }

  // -------------------------------------------------------------------------
  // 校验
  // -------------------------------------------------------------------------

  /// 问服务端「这台设备还算数吗」。
  ///
  /// 没有「静默」参数：早期版本用它区分后台定时复查与用户手动点「重新校验」，
  /// 差别只在提示抢不抢注意力。宽限期删掉之后两条路的行为已经完全一致，
  /// 留着一个不生效的参数，读代码的人会以为它还有用。
  ///
  /// 同一时刻至多一个校验在途：定时器、回前台、WS resync、运行期轮询、
  /// 手动「重新校验」可能几乎同时触发，已在途时后来的调用共享同一个
  /// Future，而不是各发一个请求再赌谁先回来。对外校验入口 = 一次本体
  /// 校验 + 失败后的快速重试调度；本机过滤层/弱网常把个别请求掐成瞬时
  /// 失败——失败后 5 秒自动补一发，连续快速重试有上限（约 1 分钟），
  /// 之后交回常规周期与 resume 校验。
  Future<LicenseResult> verify({bool force = false, String source = ''}) {
    if (!enabled) {
      return Future.value(
          const LicenseResult(true, LicenseStage.notConfigured, ''));
    }
    // 手动「重新校验」的客户端节流：3 秒内的连点只放第一枪。
    // 服务端对 /verify 本就有按 IP 的滑窗限流（撞线回 429），这里不是
    // 防滥用，是替用户自己拦手——按钮连点除了把自己点进 429、再触发
    // 一串限流补射之外没有任何产出。节流到点后静默返回当前结论
    // （不伪造新结果、不动状态），人手正常节奏完全感知不到。
    if (source == '用户手动') {
      final last = _lastManualAt;
      final now = DateTime.now();
      if (last != null && now.difference(last) < _manualThrottle) {
        return Future.value(
            LicenseResult(true, _stage, _message, throttled: true));
      }
      _lastManualAt = now;
    }
    // 快速重试链已在 5 秒一发地轮询、或限流补射正在等服务端的 retryAfter
    // 时，回前台/窗口显示这类高频聚焦事件不再各补一枪——两条链本身就是
    // 既定的节奏，补枪只贡献请求量与 429（TUN 提权重启的焦点风暴正是靠它
    // 撞爆闸门的）；链落定后的聚焦照常触发，恢复真相不缺入口。
    if ((source == '回前台' || source == '窗口显示') &&
        (_quickRetry?.isActive == true || _rateRetry?.isActive == true)) {
      return Future.value(LicenseResult(true, _stage, _message));
    }
    // 服务端给的 TTL（revalidateAfter，秒）：在此之前自动校验自我抑制。
    // 服务端已经给过权威结论，没事件就不该再去问。TTL 只拦"自动来源"
    // （定时器、补课、回前台）——用户按按钮/启动预检/resync 推送都传
    // force:true 击穿：这三者是外部事件，服务端 TTL 管不到它们。
    if (!force && _revalidateAt != null && DateTime.now().isBefore(_revalidateAt!)) {
      _authLog('TTL 内跳过自动校验（服务端指示 ${_revalidateAt!.difference(DateTime.now()).inSeconds} 秒内无需复查）'
          '${source.isEmpty ? '' : '，来源 $source'}');
      return Future.value(LicenseResult(true, _stage, _message));
    }
    final running = _verifyInFlight;
    if (running != null) return running;
    // 记录「真发出去了」的时刻，慢速兜底据此算间隔；TTL 抑制与在途合并
    // 都不算，否则一次被抑制的调用会把兜底时钟往前推，白白延后真正的保底。
    _lastVerifyAt = DateTime.now();
    // 机械重试不记「触发来源」行：快速重试链 5 秒一发，4 行/发把断网的一
    // 分钟刷成 48+ 行；重试的失败有专属单行（见 _verifyOnce）。
    if (source.isNotEmpty && source != '失败重试') {
      _authLog('校验触发来源：$source');
    }
    return _verifyInFlight = _chain(() => _verifyWithRetry(source))
        .whenComplete(() => _verifyInFlight = null);
  }

  /// 手动校验的节流间隔与上次点击时刻（见 verify 开头的节流说明）。
  static const Duration _manualThrottle = Duration(seconds: 3);
  DateTime? _lastManualAt;

  /// 在途校验，供上面的共享逻辑用。
  Future<LicenseResult>? _verifyInFlight;

  /// license 网络操作（verify/activate）的串行链：前一趟没落地，后一趟不出发。
  /// HTTP 响应不保证按请求顺序到达——两个并发的 /verify，旧的那个晚回来，
  /// 会把刚生效的新状态（比如吊销）用旧答案覆盖回去，_set 是后写者胜。
  /// 串行之后任何时刻至多一个请求在途，时序自然有序。
  Future<void> _netChain = Future.value();

  Future<T> _chain<T>(Future<T> Function() op) {
    final done = _netChain.then((_) => op());
    // 链本身吞掉异常，只保持顺序；调用方拿 done 看真正的结果。
    _netChain = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<LicenseResult> _verifyWithRetry(String source) async {
    final r = await _verifyOnce(source);
    // 断网→恢复的瞬间补发一次事件（stage 未变也要发）：激活页状态行的
    // 「连接失败」快照靠它对齐回真实档位（吊销/封禁被保留时没有
    // stage 事件可等）。幂等，纯通知。
    if (_netRecovered) {
      _netRecovered = false;
      resync();
    }
    if (r.ok && _stage != LicenseStage.unreachable) {
      _unreachableRetries = 0;
      return r;
    }
    // 连不上就快速重试：用 _netDown 而不是 stage 判——硬拦档位被保留时
    // stage 不再是 unreachable，但网络依然是断的，重试链不能停。
    if (_netDown && _unreachableRetries < 12) {
      _unreachableRetries++;
      _quickRetry?.cancel();
      _quickRetry = Timer(const Duration(seconds: 5), () {
        if (disposed || !_netDown) return;
        verify(source: '失败重试');
      });
    }
    return r;
  }

  int _unreachableRetries = 0;
  Timer? _quickRetry;
  /// 限流（429）后的补射定时器：见 _verifyOnce 里 case 'rate_limited'。
  Timer? _rateRetry;
  /// 收到 resync 的时刻。用于判断「刚刚这次 active 答复可能是 KV 旧读」。
  DateTime? _resyncSeenAt;
  /// resync 后确认复核的定时器，见 _scheduleResyncConfirm。
  Timer? _resyncConfirm;

  /// 最近一次 /verify 的 HTTP 状态码。仅用于授权日志那一行说明文字，
  /// 不参与任何判定——判定只看返回体里的 status。
  int _lastStatusCode = 0;

  /// 授权/校验相关的全部留痕统一走这里：`[授权]` 前缀让 LogService 把它
  /// 路由进专属的「授权激活」视图与 auth.log（与 `[自检]` 同一套机制）。
  ///
  /// 为什么不混进普通日志：普通日志有级别过滤（off/error 会把 info 丢掉）、
  /// 还会随会话轮转。授权是「这台机器此刻凭什么能用」的唯一凭据，
  /// 用户报障时第一句话就是「看下授权日志」，它不能被级别开关吃掉、
  /// 也不能因为重启就消失。
  ///
  /// 文案一律中文，且要说清是**哪一步、结论是什么**——「校验失败」这种
  /// 话等于没写，看日志的人还得回去猜是哪一环。
  static void _authLog(String msg) {
    LogService.instance.log('[授权] $msg', level: LogLevel.info);
  }

  /// 一次校验/激活请求的落点说明：路径 + HTTP 码 + 服务端答复的 status。
  /// 服务端 4xx 是应用层答复（unknown_device / code_mismatch / revoked…），
  /// 不是传输失败，所以照样记下来并译成人话。
  static String _httpNote(String path, int statusCode, Object? status) {
    final code = switch (status) {
      'active' => '校验通过，授权有效',
      'pending' => '激活码已签发，等待客户端填入领取',
      'revoked' => '授权已被管理员吊销',
      'code_mismatch' => '客户端持有的激活码与服务端记录不一致（管理端换过码），旧码作废',
      'banned' => '该账号已被管理员封禁，名下设备全部停用',
      'unknown_device' => '服务端不认识这台设备，尚未登记发码',
      'bad_request' => '请求内容不合规',
      'rate_limited' => '请求过于频繁被限流（服务端要求稍后再问）',
      'ok' => '请求已受理',
      null => '服务端未给出状态',
      _ => '服务端返回「$status」',
    };
    return '$path 往返完成（HTTP $statusCode）：$code';
  }

  Future<LicenseResult> _verifyOnce(String source) async {
    if (!enabled) {
      return LicenseResult(true, LicenseStage.notConfigured, '');
    }

    if (source != '失败重试') {
      _authLog('开始校验授权：设备码 $deviceCode'
          '${_code.isEmpty ? '，本机未保存激活码' : '，本机已保存激活码'}');
    }
    // 携带本地保存的激活码：服务端比对记录里当前的码，不一致回
    // code_mismatch——管理端「修改激活码」后旧码持有者即被切断。
    // 一并带上客户端版本：管理页那列版本号原先只在激活时写一次、此后永远
    // 是旧值（实测跑 1.1.0 而页面显示 1.2.10）。服务端仅在版本变化时才写，
    // 稳态零写，不破verify 的零写地基。
    // 版本带平台后缀（kAppVersionTag，如 1.2.11-Win）：管理页靠它区分
    // Windows / Mac 客户端；纯三段的 kAppVersion 留给 Updater 做更新判定。
    final res = await _post('/verify', {
      'deviceCode': deviceCode,
      'code': _code,
      'appVersion': kAppVersionTag,
    });
    if (res == null) {
      final r = _handleUnreachable();
      // 快速重试链的失败一行说完：完整的 4 行仪式（来源/开始/失败/结论）
      // 只属于有语义的触发（启动/手动/回前台），机械重试重复同样的结论
      // 十几次只会把日志刷成噪音——断网那一分钟从 48+ 行降到 12 行。
      if (source == '失败重试') {
        _authLog('快速重试失败：$netFailHeadline');
        return r;
      }
      _authLog('校验未完成：连不上授权服务器'
          '${_stage == LicenseStage.unreachable ? '（$message）' : '（维持原结论：${_stageName(_stage)}）'}');
      return r;
    }
    // 请求往返成功 = 网络恢复了（哪怕答复是否定）：清掉断网标记，
    // 快速重试链到此收手，交回常规节奏。标记「刚从断网恢复」：
    // 硬拦档位被保留时 stage 不变、不会有事件，界面挂着的「连接失败」
    // 快照就永远停摆——_verifyWithRetry 尾部据此补发一次事件。
    if (_netDown) _netRecovered = true;
    _netDown = false;
    _authLog(_httpNote('/verify', _lastStatusCode, res['status']));

    switch (res['status']) {
      case 'active':
        // 服务端 enforce 被关掉时会对**任何**设备都回这一档，包括从没登记过的，
        // 并且带上 active:false。那一档的意思是「服务器此刻放行」，不是「你已
        // 激活」，两者不能混为一谈：激活过的机器在开关打开后还得靠 /verify
        // 重新拿到真的 active 才算数。
        if (res['enforced'] == false || res['active'] == false) {
          // 这一档的文案不进客户端：管理员把逃生门打开时，界面上没必要
          // 告诉用户「服务器此刻不拦你」——那既像故障提示，又等于把后台
          // 的开关暴露给每个用户。stage 本身必须留着（blocked 看它），
          // 状态栏那一行「校验已停用」也留着，好让管理员自己看得出
          // 此刻是在放行状态而不是在正常校验。
          _authLog('服务端强制校验已关闭：本次按放行处理，'
              '注意这不代表本机已激活（放行开关由管理员在后台控制）');
          _negStreak = 0;
          _negConfirm?.cancel();
          _negConfirm = null;
          _set(LicenseStage.enforcementOff, '');
          return LicenseResult(true, LicenseStage.enforcementOff, '');
        }
        _lastVerifiedAt = DateTime.now();
        _saveLocal();
        _unreachableRetries = 0;
        _negStreak = 0;
        _negConfirm?.cancel();
        _negConfirm = null;
        // TTL 锚点：从这次成功答复起算 revalidateAfter 秒。
        final ttl = (res['revalidateAfter'] as num?)?.toInt() ?? 3600;
        _revalidateAt = DateTime.now().add(Duration(seconds: ttl));
        // 记下服务端侧的记录变更时间：后续否定答复用它判别「真变更」
        // 还是「KV 过期读」（见 _shouldApplyNegative）。
        _lastPositiveAt = DateTime.tryParse(res['updatedAt'] as String? ?? '');
        // 刚被 resync 催过就拿到了 active：这一枪有可能问得太早，读到的是
        // KV 还没收敛的旧值，于是「吊销」被一份新鲜的权威答复吞掉。
        // 实测窗口很小（生产环境实测约 4.4 秒收敛，05:47 那次是在写入后
        // 1~2 秒问的、正好落进窗口），但它一旦发生就是**永久丢失**——
        // 这份 active 把 TTL 推到一小时，而推送在线时不会轮询。
        // 所以这里补一枪延后复核：宁可多问一次，也不能把吊销判定了丢掉。
        _scheduleResyncConfirm();
        _authLog('校验通过：本机授权有效，记录本次成功时间');
        _set(LicenseStage.active, '');
        return const LicenseResult(true, LicenseStage.active, '');
      case 'pending':
        // 服务端已经给这台设备发过码，只是人还没填进去。
        // TTL 与 revoked/code_mismatch 同口径清掉：否定复核不带 force，
        // TTL 残留会把 20 秒后的复核吞掉，旧状态最长压一小时。
        _revalidateAt = null;
        _authLog('尚未完成激活：服务端已签发激活码，等待用户填入领取');
        if (!_shouldApplyNegative(LicenseStage.codeIssued, res['updatedAt'] as String? ?? '')) {
          return const LicenseResult(true, LicenseStage.codeIssued, '');
        }
        _set(LicenseStage.codeIssued, '激活码已签发，请将激活码粘贴到输入框后，点击「激活」完成注册');
        return LicenseResult(true, LicenseStage.codeIssued, _message);
      case 'revoked':
        _revalidateAt = null;
        if (!_shouldApplyNegative(LicenseStage.revoked, res['updatedAt'] as String? ?? '')) {
          return const LicenseResult(true, LicenseStage.revoked, '');
        }
        _lastVerifiedAt = null;
        _saveLocal();
        _authLog('校验未通过：管理员已吊销本机授权，客户端被拦下');
        _set(LicenseStage.revoked, '客户端授权已吊销，如有问题请联系管理员反馈。');
        return const LicenseResult(true, LicenseStage.revoked, '');
      case 'banned':
        // 封禁（黑名单）与吊销同处置：立即停代理，不进复核。
        // 封禁不在 license 记录上、没有时间戳可比；且管理语义就是
        // 「此人不可用」——立即停是唯一正确的处置。
        // TTL 一并清掉：封禁后的切断复检/掉线轮询都不带 force，TTL 残留
        // 会让「管理员解封」的感知从分钟级拖到小时级。
        _revalidateAt = null;
        _lastVerifiedAt = null;
        _saveLocal();
        _authLog('校验未通过：该账号已被管理员封禁，名下设备全部停用');
        _set(LicenseStage.banned, '客户端授权已被封禁，如有问题请联系管理员反馈。');
        return const LicenseResult(true, LicenseStage.banned, '');
      case 'code_mismatch':
        _revalidateAt = null;
        // 管理端已更换本机的激活码：旧码持有者在此刻被切断。
        // 状态回到未登记同档（激活码卡片重现），用户填入新码即恢复。
        if (!_shouldApplyNegative(LicenseStage.unregistered, res['updatedAt'] as String? ?? '')) {
          return const LicenseResult(true, LicenseStage.unregistered, '');
        }
        _lastVerifiedAt = null;
        _saveLocal();
        _authLog('校验未通过：管理端已更换本机激活码，本机保存的旧码作废，'
            '需向管理员索取新激活码');
        _set(LicenseStage.unregistered, '激活码校验失败，请确认与设备绑定一致');
        return const LicenseResult(
            true, LicenseStage.unregistered, '激活码校验失败，请确认与设备绑定一致');
      case 'unknown_device':
        _revalidateAt = null;
        // 删除/解绑后记录不存在，没有时间戳可判别新旧。管理端的语义是
        // 「此客户端不可用」——按用户原则立即停代理，不走复核：
        // 真被删除的机器多跑一秒都是白用；若是 KV 抖出的假 404，
        // 下次校验回到 active 自愈（隧道需手动重开，这是错杀的代价）。
        _lastVerifiedAt = null;
        _saveLocal();
        _authLog('校验未通过：服务端查不到本设备码（已删除/解绑），立即停代理');
        _set(LicenseStage.unregistered, '本机尚未登记，请前往TG群注册并获取激活码');
        return const LicenseResult(true, LicenseStage.unregistered, '');
      case 'rate_limited':
        // 限流不是授权结论，是「这一枪打得太快」——服务端滑窗 20 次/60 秒，
        // 管理端连续快速操作（吊销/恢复来回点）时 resync 密集触发校验，
        // 叠加复检链就可能撞线。此前这里掉进 default 被当成「无法识别的
        // 状态」：状态被误置为 unreachable、用户看到误导性报错，且这一枪
        // 携带的吊销/恢复判定整个被丢弃——正好构成「有时秒生效、有时
        // 要手动点页面才弹窗」的一条通路。
        //
        // 正确处置：上一份已知结论继续有效（不动 stage，不弹错），按服务端
        // 给的 retryAfter 排一次补射。补射必须 force：TTL 是「拿到权威结论
        // 后的抑制节奏」，这次压根没拿到结论，让 TTL 拦住补射等于把判定
        // 永久丢掉。窗口 clamp 到 2~60 秒，retryAfter 缺失时给个短值。
        final waitSec = ((res['retryAfter'] as num?)?.toInt() ?? 5).clamp(2, 60);
        _rateRetry?.cancel();
        _rateRetry = Timer(Duration(seconds: waitSec), () {
          if (!disposed) verify(force: true, source: '限流重试');
        });
        _authLog('校验被限流：维持上一次结论，$waitSec 秒后自动重试');
        return LicenseResult(true, _stage, _message);
      default:
        // 服务端加了新状态而客户端版本旧了（或网关返回了可解析但看不懂
        // 的 JSON）。宁可拦住也不能当成已激活放过去——但**不得覆写硬拦
        // 档位**：与 _handleUnreachable 同一条不变量，否则吊销/封禁中的
        // 客户端遇到一次「看不懂的答复」就把主界面放回来了。
        _netDown = true;
        switch (_stage) {
          case LicenseStage.revoked:
          case LicenseStage.banned:
          case LicenseStage.unregistered:
          case LicenseStage.codeIssued:
            return LicenseResult(false, _stage, netFailHeadline);
          default:
            break;
        }
        _authLog('校验未通过：服务端返回了无法识别的状态「${res['status']}」，'
            '可能是服务端已升级而客户端版本偏旧');
        _set(LicenseStage.unreachable, '授权校验返回了无法识别的结果');
        return LicenseResult(
            false, LicenseStage.unreachable, '授权校验返回了无法识别的结果');
    }
  }

  /// 「本机已激活，下一次校验却拿到否定答复」的双读复核护栏。
  ///
  /// KV 是最终一致：管理端的吊销/恢复要约 60 秒才在全球边缘收敛
  /// （docs/archive/授权流程.md §8.3）。客户端恰好在这个窗口里校验，会读到旧值——
  /// 刚激活成功的机器被打回激活页，下一次复核又变回 active，来回翻面；
  /// 恢复操作的 resync 广播恰恰总在窗口刚打开时到达，等于每次都踩。
  ///
  /// 规则：stage == active 时收到「服务端明确说不」，第一次只记日志、
  /// 暂维持可用并安排 20 秒后自动复核；连续两次否定才真正切换。
  /// 真实的吊销因此最多延迟一个复核周期生效——相比旧的 30 分钟轮询
  /// 仍是秒级，而传播窗口里的来回翻页在结构上消失。fresh 启动
  /// （stage 还是 unknown）不受此护栏影响，第一次否定立即拦。
  ///
  /// 返回 true = 这次否定应当生效，调用方照常改状态；false = 已进入
  /// 复核期，调用方直接返回，不改状态、不清 _lastVerifiedAt。
  bool _shouldApplyNegative(LicenseStage next, String negUpdatedAt) {
    // 只有「从 active 翻到拦」值得复核：fresh 启动的第一次否定没有
    // 可失去的状态，立即生效。
    if (_stage != LicenseStage.active) {
      _negStreak = 0;
      return true;
    }
    if (next != LicenseStage.revoked &&
        next != LicenseStage.unregistered &&
        next != LicenseStage.codeIssued) {
      return true;
    }
    // 时间戳判别：否定答复携带记录的变更时间，与本机最近一次有效状态
    // （同样取服务端时钟）相比——
    //   比它新 → 这是刚发生的真实变更（真吊销），立即执行，不等复核；
    //   比它旧或无法比较 → 是 KV 过期读（旧数据的时间不可能比刚见过的
    //   新状态更新），走 20 秒双读复核，不误杀。
    final negAt = DateTime.tryParse(negUpdatedAt);
    final posAt = _lastPositiveAt;
    if (negAt != null && posAt != null && negAt.isAfter(posAt)) {
      _negStreak = 0;
      _negConfirm?.cancel();
      _negConfirm = null;
      _authLog('服务端答复的变更时间晚于本机最近一次有效状态——'
          '真实的最新变更，立即执行');
      return true;
    }
    _negStreak++;
    if (_negStreak >= 2) {
      _negStreak = 0;
      _negConfirm?.cancel();
      _negConfirm = null;
      return true;
    }
    _authLog('服务端给出否定答复（${_stageName(next)}），但其变更时间不晚于本机'
        '最近一次有效状态——大概率是 KV 传播未收敛的过期读。'
        '暂维持本机可用，20 秒后自动复核；复核仍是否定将立即拦下。');
    _negConfirm?.cancel();
    _negConfirm = Timer(const Duration(seconds: 20), () {
      if (!_changes.isClosed) verify(force: true, source: '否定复核');
    });
    return false;
  }

  int _negStreak = 0;
  Timer? _negConfirm;
  // 最近一次「有效」状态的记录变更时间（服务端时钟）。active 答复携带；
  // 为 null（老服务端/无字段）时时间戳判别不可用，退回纯双读复核。
  DateTime? _lastPositiveAt;

  /// 否定档的中文名，只用于授权日志那一行。
  static String _stageName(LicenseStage s) => switch (s) {
        LicenseStage.revoked => '已吊销',
        LicenseStage.banned => '已封禁',
        LicenseStage.unregistered => '未登记/码已更换',
        LicenseStage.codeIssued => '码已签发未领取',
        _ => s.name,
      };

  /// 连不上授权服务器时一律拦，没有例外分支。
  /// 原来这里有 7 天宽限期，见文件头「为什么连不上也拦」。
  LicenseResult _handleUnreachable() {
    // 连不上 ≠ 可以进：unreachable 永远不能顶掉一个「服务器明确说不」的
    // 结论。吊销/封禁/未登记/码已签发的客户端断网后必须停在激活页——
    // 否则拔根网线就能把拦截界面翻回主页面（2026-10-09 实测踩中：
    // 吊销后断网，stage 被覆写成 unreachable，主页面回来了）。
    // 档位保留原样，答复如实报「连不上」；网络恢复后 quickRetry 链
    // 自动重新校验，拿回最新结论。
    switch (_stage) {
      case LicenseStage.revoked:
      case LicenseStage.banned:
      case LicenseStage.unregistered:
      case LicenseStage.codeIssued:
        _netDown = true;
        _revalidateAt = null;
        // 结果的 stage 带原档位（revoked/…）而不是 unreachable：激活页据此
        // 把「授权服务器连接失败」写进激活提示行（红色），而不是让状态行
        // 一句「已吊销」把断网原因吞掉。
        return LicenseResult(false, _stage, netFailHeadline);
      default:
        break;
    }
    _netDown = true;
    // 连不上时 TTL 必须让位：快速重试链要能立即出发，不能被上次的
    // 服务端指示压住。
    _revalidateAt = null;
    final last = _lastVerifiedAt;
    // 带上「上次成功校验」的时间，用户报障时能少问一句话；也提醒他
    // 现在用的是本机缓存的状态，服务端那边发生了什么他看不到。
    final tail = last == null ? '' : '（上次成功校验：${_ago(last)}）';
    _set(LicenseStage.unreachable, '$netFailHeadline$tail');
    return LicenseResult(false, LicenseStage.unreachable, _message);
  }

  /// 最近一次授权请求是否因网络失败（与 stage 解耦：硬拦档位被保留时
  /// stage 不再是 unreachable，快速重试链靠这个标记继续走）。
  bool _netDown = false;

  /// 最近一次网络失败的分类原因（describeNetError；成功往返后清空）。
  String? _netErrorHint;

  /// 重新校验失败时状态行的那句话：带具体原因，一行说完——一行信息
  /// 原则下没有第二行放细节，原因就并进这一行。
  String get netFailHeadline {
    final h = _netErrorHint;
    return h == null || h.isEmpty
        ? '授权服务器连接失败，请检查网络'
        : '授权服务器连接失败：$h，请检查网络';
  }

  /// 本次 _verifyOnce 是否经历了「断网 → 恢复」的跳变（见 _verifyWithRetry
  /// 尾部的补发事件）。
  bool _netRecovered = false;

  /// 大致多久之前。只用于给人看，不参与任何判定。
  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 激活弹窗里「点我去 TG」要跳的链接。
  ///
  /// 链接放在服务端而不是编译进包里，是为了让管理员改链接不必重新发版。
  /// 取不到时回空串，界面上就不显示那个按钮——这一项只影响跳转，
  /// 为它失败没有意义（服务端这里也刻意返回 200 加空链接，见 License.js）。
  /// 「检查网络」的探测：与授权请求完全同一条降级链（直连 → 系统代理）、
  /// 同一深度（完整 TLS 握手并验证证书链）、同一套失败分类。此前是裸
  /// TCP 握手——TCP 可被任何中间设备代答，2026-10-10 实测 TCP「成功」
  /// 与 /verify 被假证书挡下同时发生，两个信号自相矛盾。探测不发任何
  /// API 请求，只对根路径发一个 HEAD（拿到任何 HTTP 状态都算链路通）。
  Future<({bool ok, int elapsedMs, String? failReason})> probeNetwork() async {
    if (!enabled) {
      return (ok: false, elapsedMs: 0, failReason: '未配置授权服务器');
    }
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) {
      return (ok: false, elapsedMs: 0, failReason: '未配置授权服务器');
    }
    final sw = Stopwatch()..start();
    Object? err;
    // 与 /verify 同一条链、同一个偏好（_preferProxy）：校验走哪条路能通，
    // 探测就走哪条路，两个信号永远一致。先查系统代理是否真开着（顺带
    // 刷新地址缓存）——不查的话可能拿 60 秒缓存里已失效的地址去探。
    final proxyOn = await _systemProxyOn();
    var ok = await _probeHost(host,
        viaProxy: _preferProxy && proxyOn, onErr: (e) => err = e);
    if (!ok && proxyOn) {
      ok = await _probeHost(host,
          viaProxy: !(_preferProxy && proxyOn), onErr: (e) => err = e);
    }
    sw.stop();
    return (
      ok: ok,
      elapsedMs: sw.elapsedMilliseconds,
      failReason:
          ok ? null : (describeNetError(err) ?? '网络异常，请检查本机网络'),
    );
  }

  Future<bool> _probeHost(String host,
      {required bool viaProxy, required void Function(Object) onErr}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (viaProxy) {
      final p = _systemProxyAddr();
      c.findProxy = (uri) => p == null ? 'DIRECT' : 'PROXY $p';
    } else {
      c.findProxy = (_) => 'DIRECT';
    }
    try {
      final req = await c.openUrl('HEAD', Uri.parse('https://$host/'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      return res.statusCode > 0; // 拿到任何 HTTP 状态 = 链路通
    } catch (e) {
      onErr(e);
      return false;
    } finally {
      c.close(force: true);
    }
  }

  Future<String> fetchInviteLink() async {
    if (!enabled) return '';
    // 与授权请求同一条降级链：直连被掐的环境里（恰恰是最需要这个按钮
    // 的环境），缓存永远写不进——直连失败再兜一发系统代理。
    for (final viaProxy in [false, true]) {
      if (viaProxy && !await _systemProxyOn()) break;
      final v = await _fetchInviteOnce(viaProxy);
      if (v.isNotEmpty) {
        if (viaProxy) _authLog('邀请链接直连失败，经系统代理获取成功');
        // 取到就落一份本地缓存：断网时激活页靠它保住「点我去 TG 群」
        // 按钮——入口不因网络消失，没网的时候恰恰最需要照着去求助。
        _saveInviteCache(v);
        return v;
      }
    }
    return '';
  }

  Future<String> _fetchInviteOnce(bool viaProxy) async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    if (viaProxy) {
      final p = _systemProxyAddr();
      c.findProxy = (uri) => p == null ? 'DIRECT' : 'PROXY $p';
    } else {
      c.findProxy = (_) => 'DIRECT';
    }
    try {
      final req = await c.getUrl(Uri.parse('$baseUrl/client-config'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode < 200 || res.statusCode >= 300) return '';
      final decoded = jsonDecode(await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8)));
      if (decoded is! Map) return '';
      final link = decoded['inviteLink'];
      return link is String ? link.trim() : '';
    } catch (_) {
      return '';
    } finally {
      c.close(force: true);
    }
  }

  /// 邀请链接的本地缓存文件：与 license.json 同目录（%APPDATA%\EchOS），
  /// 纯文本一行。写失败不影响任何流程（下次取到再写）。
  File get _inviteCacheFile =>
      File('${AppPaths.appDataDir.path}${Platform.pathSeparator}invite-link.txt');

  void _saveInviteCache(String link) {
    try {
      _inviteCacheFile.writeAsStringSync(link, flush: true);
    } catch (_) {}
  }

  /// 最近一次联网取到的 TG 群邀请链接（本地缓存）。服务端取不到时
  /// 激活页用它兜底显示按钮；从未联网取到过（全新机器且一直没网）
  /// 才是空——那种情况没有可跳的地址，隐藏按钮是诚实的做法。
  String get cachedInviteLink {
    try {
      return _inviteCacheFile.existsSync()
          ? _inviteCacheFile.readAsStringSync().trim()
          : '';
    } catch (_) {
      return '';
    }
  }

  // -------------------------------------------------------------------------
  // 激活
  // -------------------------------------------------------------------------

  /// 用激活码领授权。成功即本地落盘并进入 active。
  ///
  /// 格式在这里先卡一道：必须严格是 ECHS-XXXX-XXXX-XXXX-XXXX（大写、含连字符），
  /// 不再做「转大写、剥连字符」的静默归一——见 device_identity.dart 里
  /// isValidActivationCode 的注释。发出去的串就是用户看到的那串。
  Future<LicenseResult> activate(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) {
      _authLog('提交激活失败：没有输入任何内容');
      return const LicenseResult(false, LicenseStage.unknown, '请输入激活码');
    }
    if (!isValidActivationCode(code)) {
      _authLog('提交激活失败：激活码格式不正确'
          '（应为 ECHS-XXXX-XXXX-XXXX-XXXX，大写且含连字符，原样复制即可）');
      return const LicenseResult(
          false,
          LicenseStage.unknown,
          '激活码格式不正确，应为 ECHS-XXXX-XXXX-XXXX-XXXX（大写、含连字符）');
    }
    if (!enabled) {
      _authLog('提交激活失败：当前构建未配置授权服务器，无法激活');
      return const LicenseResult(false, LicenseStage.notConfigured, '未配置授权服务器');
    }

    // 码本身不落日志：授权日志是用户能直接看到的，留一份激活码在那里
    // 等于把它抄送给了每个看得到日志的人。要对账时看末四位即可。
    _authLog('提交激活：设备码 $deviceCode，激活码末四位 …${code.substring(code.length - 4)}');
    // 排到串行链上：此刻若有一个 /verify 在途，先让它落地——它的响应取自
    // 激活写入之前的服务端状态，一旦晚于 activate 返回，会把刚激活的机器
    // 又打回未激活。
    return _chain(() async {
      final res = await _post('/activate', {
        'deviceCode': deviceCode,
        'code': code,
        'appVersion': kAppVersionTag,
      });
      if (res == null) {
        final r = _handleUnreachable();
        _authLog('提交激活未完成：连不上授权服务器');
        return r;
      }
      _authLog(_httpNote('/activate', _lastStatusCode, res['status']));

      switch (res['status']) {
        case 'active':
          _code = raw.trim();
          _lastVerifiedAt = DateTime.now();
          _saveLocal();
          _authLog('激活成功：本机设备码与激活码已绑定，授权生效');
          _set(LicenseStage.active, '激活成功');
          return const LicenseResult(true, LicenseStage.active, '激活成功');
        case 'invalid_code':
          _authLog('激活失败：服务端不存在这张激活码，请确认是否复制完整或已被管理员回收');
          return const LicenseResult(false, LicenseStage.unknown, '该激活码不存在');
        case 'revoked':
          _authLog('激活失败：这张激活码已被管理员吊销');
          return const LicenseResult(false, LicenseStage.revoked, '该激活码已被吊销');
        case 'device_mismatch':
          // 最常见的原因：把另一台机器的码贴过来了。
          _authLog('激活失败：该激活码绑定的是另一台设备（本机 $deviceCode），'
              '一机一码，不能跨设备使用');
          return const LicenseResult(
              false, LicenseStage.unknown, '激活码与本机不匹配，请正确输入本机绑定的激活码。');
        case 'rate_limited':
          // 限流是激活这一步里唯一「稍后重试真的会好」的失败（按 IP 计数的
          // 闸门，见服务端 activateGate）。retryAfter 服务端必带，缺省给短值。
          final waitSec = ((res['retryAfter'] as num?)?.toInt() ?? 5).clamp(2, 60);
          _authLog('激活被限流：$waitSec 秒后可再试');
          return LicenseResult(
              false, LicenseStage.unknown, '操作过于频繁，请 $waitSec 秒后再试');
        case 'banned':
          // /activate 会把封禁直接报给激活页：它是终态，重试永远过不去，
          // 唯一出路是联系管理员——不能落进 default 的「请稍后重试」。
          _authLog('激活失败：该激活码对应的账号已被管理员封禁');
          return const LicenseResult(
              false, LicenseStage.banned, '该账号已被封禁，如有问题请联系管理员反馈。');
        default:
          // already_active 是管理端「生成」接口的错码，/activate 永远不会
          // 返回它——原先照它写的分支是死代码，已删。
          _authLog('激活失败：服务端返回了无法识别的状态「${res['status']}」');
          return const LicenseResult(false, LicenseStage.unknown, '激活失败，请稍后重试');
      }
    });
  }

  // -------------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------------

  /// 授权请求出口：**直连优先**（授权可用性不依赖代理，这是刻意的设计），
  /// 直连失败时用系统代理兜底一发——两发都失败才算 unreachable。
  ///
  /// 代理兜底成功过一次后 [_preferProxy] 置位：后续请求**代理优先**、直连
  /// 降为兜底。直连被持续劫持的环境（2026-10-10 实测：直连 443 被掏假证书，
  /// 系统代理正常）里，每次先撞一遍直连既白付一次 TLS 失败、也在日志里
  /// 刷一串「证书校验失败」——记住走哪条路能通，错误串从源头消失。每 30
  /// 分钟放一枪直连重探（[_preferProxyAt]），直连恢复即复位，不把人永久
  /// 锁在代理路径上。
  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) async {
    final proxyOn = await _systemProxyOn();
    if (_preferProxy &&
        _preferProxyAt != null &&
        DateTime.now().difference(_preferProxyAt!) > const Duration(minutes: 30)) {
      _preferProxy = false; // 放一枪直连重探：恢复了就回直连优先
    }
    final proxyFirst = _preferProxy && proxyOn;
    final a = await _postOnce(path, body, viaProxy: proxyFirst);
    if (a != null) return a;
    if (!proxyOn) return null;
    final b = await _postOnce(path, body, viaProxy: !proxyFirst);
    if (b != null) {
      if (proxyFirst) {
        _preferProxy = false;
        _savePreferProxyPref();
        _authLog('$path 系统代理失败，直连成功——恢复直连优先');
      } else {
        _preferProxy = true;
        _preferProxyAt = DateTime.now();
        _savePreferProxyPref();
        _authLog('$path 直连失败，经系统代理成功——此后代理优先（每 30 分钟重探直连）');
      }
      return b;
    }
    return null;
  }

  /// 代理优先标记与其置位时刻（见 _post 的说明）。
  bool _preferProxy = false;
  DateTime? _preferProxyAt;

  /// 代理偏好的落盘文件（与 license.json 同目录）。内容一行：'proxy' /
  /// 'direct'。跨重启的理由：直连被持续劫持的环境里，记忆只存内存的话
  /// 每次冷启动都要先撞一遍假证书才被兜底救回——auth.log 每早一串
  /// 「TLS 证书校验失败」（2026-10-10 反馈「启动总是 TLS 问题」）。
  /// 文件读不到/损坏一律按 direct 处理，不构成新失败路径。
  File get _netPrefFile =>
      File('${AppPaths.appDataDir.path}${Platform.pathSeparator}net-pref.txt');

  bool _loadPreferProxyPref() {
    try {
      return _netPrefFile.existsSync() &&
          _netPrefFile.readAsStringSync().trim() == 'proxy';
    } catch (_) {
      return false;
    }
  }

  void _savePreferProxyPref() {
    try {
      _netPrefFile
          .writeAsStringSync(_preferProxy ? 'proxy' : 'direct', flush: true);
    } catch (_) {}
  }

  // 系统代理查询结果缓存：直连被掐的环境里每次失败校验都会走到这里，
  // reg.exe 查询不能在 UI isolate 上反复同步跑（spawn cmd+reg 常态
  // 15-60ms，AV 忙时更久），也不能每次都 spawn——60 秒内复用。
  static const String _proxyRegKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static DateTime? _sysProxyCheckedAt;
  static bool _sysProxyOnCache = false;
  static String? _sysProxyAddrCache;

  /// 系统代理是否处于启用状态（ProxyEnable=1 且 ProxyServer 有值）。
  /// 没开就没有兜底可试，跳过第二发。查询结果缓存 60 秒，
  /// 地址落在 _sysProxyAddrCache 供 _systemProxyAddr() 读取。
  static Future<bool> _systemProxyOn() async {
    final now = DateTime.now();
    final checked = _sysProxyCheckedAt;
    if (checked != null && now.difference(checked).inSeconds < 60) {
      return _sysProxyOnCache;
    }
    final on = await _regDword('ProxyEnable');
    final server = on ? await _regSz('ProxyServer') : null;
    _sysProxyOnCache = on && server != null && server.isNotEmpty;
    _sysProxyAddrCache = _sysProxyOnCache ? _parseProxyAddr(server!) : null;
    _sysProxyCheckedAt = now;
    return _sysProxyOnCache;
  }

  /// 系统代理地址（host:port）。_systemProxyOn() 之后才有效。
  static String? _systemProxyAddr() => _sysProxyAddrCache;

  /// ProxyServer 多段格式（http=..;https=..;ftp=..）优先取 https 段，
  /// 退而取最后一段带寻址信息的；单段原样返回。
  static String _parseProxyAddr(String raw) {
    var v = raw.trim();
    if (v.contains(';')) {
      final parts = v.split(';');
      v = parts.firstWhere((p) => p.trim().startsWith('https='),
          orElse: () => '');
      if (v.trim().isEmpty) {
        v = parts.last;
      }
      if (v.contains('=')) v = v.split('=').last;
    }
    v = v.trim();
    return v;
  }

  static Future<String?> _regSz(String value) async {
    try {
      final r = await Process.run(
          'reg', ['query', _proxyRegKey, '/v', value], runInShell: true);
      if (r.exitCode != 0) return null;
      for (final l in (r.stdout as String).split('\n')) {
        if (l.contains('REG_SZ')) {
          return l.substring(l.indexOf('REG_SZ') + 6).trim();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _regDword(String value) async {
    try {
      final r = await Process.run(
          'reg', ['query', _proxyRegKey, '/v', value], runInShell: true);
      return (r.stdout as String).contains('0x1');
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _postOnce(String path, Map<String, dynamic> body,
      {required bool viaProxy}) async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    if (viaProxy) {
      final p = _systemProxyAddr();
      c.findProxy = (uri) => p == null ? 'DIRECT' : 'PROXY $p';
    } else {
      c.findProxy = (_) => 'DIRECT';
    }
    try {
      final req = await c.postUrl(Uri.parse('$baseUrl$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 10));
      // 响应头到了不等于 body 会来：劣质代理/半开连接能让 join 永久挂起，
      // 而在途合并会让一个挂死的请求冻结整个授权状态机（表现：重新校验
      // 永远转圈、激活永久排队，唯一出路重启进程）。body 读取同样限时，
      // 超时按网络失败走兜底链。
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      // 服务端的 4xx 是应用层答复（unknown_device / invalid_code /
      // already_active…），不是传输失败——照常解码交给调用方按 status
      // 分流。未登记设备在服务端就是 404 + unknown_device，
      // 把它吞成 null 会让新机器显示「连接失败」而不是「尚未登记」。
      // 只有解析不出 JSON 的响应（代理劫持页、网关错误页）才当「连不上」。
      final decoded = jsonDecode(text);
      _lastStatusCode = res.statusCode;
      _netErrorHint = null;
      if (res.statusCode >= 400 && res.statusCode < 500 && decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _authLog('$path 收到异常 HTTP ${res.statusCode}（应为 2xx/4xx 应用层答复），'
            '响应开头：${text.length > 200 ? '${text.substring(0, 200)}…' : text}');
        return null;
      }
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      _lastStatusCode = 0;
      // 分类后人话 + 罕见异常带一行原始摘要：直接打印 $e 会把
      // CERTIFICATE_VERIFY_FAILED: self signed certificate(boringssl 路径…)
      // 这类多行英文源码位置整段砸进授权日志，既难读也没有分类。
      final cls = describeNetError(e);
      _netErrorHint = cls;
      if (cls != null) {
        _authLog('$path 请求失败：$cls');
      } else {
        final raw = e.toString().replaceAll('\n', ' ');
        _authLog('$path 请求失败：未分类网络错误'
            '（${raw.length > 120 ? '${raw.substring(0, 120)}…' : raw}）');
      }
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// 网络层异常 → 人话分类（授权请求日志与激活页「检查网络」共用一份口径）。
  /// 返回 null 表示认不出来（调用方自行决定要不要带原始异常摘要）。
  static String? describeNetError(Object? e) {
    if (e is SocketException) {
      final m = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
      if (m.contains('timed out') || m.contains('timeout')) return '连接超时';
      if (m.contains('refused')) return '连接被拒绝';
      if (m.contains('lookup') || m.contains('nodename nor servname')) return '域名解析失败';
      if (m.contains('no route') || m.contains('unreachable') ||
          m.contains('network is down')) {
        return '网络不可达';
      }
      if (m.contains('reset')) return '连接被重置';
      if (m.contains('aborted')) return '连接被中断';
      return '系统网络栈错误（errno ${e.osError?.errorCode ?? '?'}）';
    }
    // HandshakeException 是 TlsException 的子类：自签证书报文就在这档。
    if (e is TlsException) {
      final m = '${e.message} ${e.osError ?? ''}'.toLowerCase();
      if (m.contains('certificate_verify_failed') || m.contains('self signed') ||
          m.contains('certificate')) {
        return 'TLS 证书校验失败';
      }
      return 'TLS 握手失败';
    }
    if (e is TimeoutException) return '等待响应超时';
    if (e is HttpException) return 'HTTP 传输中断';
    return null;
  }

  // -------------------------------------------------------------------------
  // 本地状态
  // -------------------------------------------------------------------------

  void _loadLocal() {
    try {
      final f = _storeFile;
      if (!f.existsSync()) {
        _authLog('读取本地授权记录：文件不存在，本机为首次启动（从未激活过）');
        return;
      }
      final m = jsonDecode(f.readAsStringSync());
      if (m is! Map) {
        _authLog('读取本地授权记录：内容不是有效对象，将按未激活处理');
        return;
      }
      _code = (m['code'] as String?) ?? '';
      final at = m['lastVerifiedAt'];
      if (at is String) _lastVerifiedAt = DateTime.tryParse(at);
      // 激活码同样只报末四位；读到的只是「本机上次记住了哪张码」，
      // 一机一码的比对仍以服务端为准，这里只用于讲清日志上下文。
      _authLog(_code.isEmpty
          ? '读取本地授权记录：未保存激活码（激活未完成或已被要求换码）'
          : '读取本地授权记录：本机保存的激活码末四位 '
              '…${_code.substring(_code.length - 4)}'
              '${_lastVerifiedAt == null ? '，且没有成功校验记录' : '，上次成功校验 ${_ago(_lastVerifiedAt!)}'}');
    } catch (e) {
      // 本地状态损坏不是致命错误：最坏情况退回「未激活」，重新走一遍流程。
      _authLog('读取本地授权记录失败（$e），按未激活处理');
    }
  }

  void _saveLocal() {
    try {
      _storeFile.writeAsStringSync(jsonEncode({
        'deviceCode': deviceCode,
        'code': _code,
        'lastVerifiedAt': _lastVerifiedAt?.toIso8601String(),
      }));
    } catch (e) {
      _authLog('写入本地授权记录失败（$e）：本次校验结论无法留到下次启动，'
          '不影响本次放行判定');
      LogService.instance.log('写入本地授权状态失败：$e', level: LogLevel.error);
    }
  }

  void _set(LicenseStage s, String msg) {
    final old = _stage;
    final changed = old != s;
    _stage = s;
    _message = msg;
    if (s == LicenseStage.active ||
        s == LicenseStage.enforcementOff ||
        s == LicenseStage.notConfigured) {
      _everUsable = true;
    }
    if (changed) _onStageChanged(old, s);
    if (changed && !_changes.isClosed) _changes.add(s);
  }

  /// 状态迁移的钩子：切断后的短周期复检。
  ///
  /// 从 active 落到任一「服务器明确说不」的档位时，隧道已被停掉，
  /// 运行期的 5 分钟轮询随之取消——若管理员其实刚刚做了「吊销→恢复」
  /// （或封禁→解封），客户端要等空闲兜底周期（最长约 1 小时）才能
  /// 回到 active，
  /// 用户看到的就是「恢复了好几分钟才缓过来」。KV 收敛只要 ~60 秒，
  /// 所以切断后头几分钟里用短周期复检兜底：30s / 120s / 300s 各补一发，
  /// 读到 active 立即恢复（幂等，纯读）；三发之后交回常规周期。
  /// 只覆盖「曾处于 active」的会话——全新机器的首次否定没有可失去的
  /// 东西，不排程。
  void _onStageChanged(LicenseStage old, LicenseStage s) {
    _cutRecheck?.cancel();
    _cutRecheck = null;
    _cutRecheckCount = 0;
    if (old != LicenseStage.active || s == LicenseStage.active) return;
    switch (s) {
      case LicenseStage.revoked:
      case LicenseStage.banned:
      case LicenseStage.unregistered:
      case LicenseStage.codeIssued:
        break;
      default:
        return;
    }
    _cutRecheckCount = 3;
    _scheduleCutRecheck(const Duration(seconds: 30));
  }

  int _cutRecheckCount = 0;
  Timer? _cutRecheck;

  void _scheduleCutRecheck(Duration delay) {
    _cutRecheck = Timer(delay, () {
      if (_changes.isClosed || _cutRecheckCount <= 0) return;
      _cutRecheckCount--;
      _authLog('切断后复检（剩余 $_cutRecheckCount 次）：确认服务端最新状态');
      verify(force: true, source: '切断复检');
      if (_cutRecheckCount > 0) {
        _scheduleCutRecheck(const Duration(seconds: 90));
      }
    });
  }
}
