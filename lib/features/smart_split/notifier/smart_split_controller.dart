import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hiddify/features/smart_split/data/clash_conns.dart';
import 'package:hiddify/features/smart_split/data/collector.dart';
import 'package:hiddify/features/smart_split/data/route_api.dart';
import 'package:hiddify/features/smart_split/data/route_writer.dart';
import 'package:hiddify/features/smart_split/model/classifier.dart';
import 'package:hiddify/features/smart_split/model/public_suffix.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/model/thing_list.dart';

/// 智能分流页用到的外部东西（测试里换成假的）。
class SmartSplitDeps {
  const SmartSplitDeps({
    required this.baseDir,
    required this.boxLog,
    required this.currentConfigPath,
    required this.psl,
    required this.loadThings,
    required this.saveThings,
    required this.api,
    required this.reconnect,
    required this.loggedIn,
    required this.appName,
    required this.appVer,
    required this.deviceId,
    this.accountId,
    this.ownDomains = const [],
    this.panelWait = const Duration(seconds: 3),
  });

  final Directory baseDir;
  final File boxLog;
  final String currentConfigPath;
  final PublicSuffix psl;
  final Future<ThingList?> Function() loadThings;
  final Future<void> Function(String json) saveThings;
  final RouteApi Function() api;

  /// 重连一次（连之前会照新的选择写规则），连上了回 true。
  final Future<bool> Function() reconnect;
  final bool Function() loggedIn;
  final String Function(String pkg) appName;
  final String appVer;
  final String deviceId;

  /// 账号编号（换账号时丢掉上个号的网站）；还不知道回空。
  final String Function()? accountId;

  /// 我们的面板 / 下载域名，采集里不列出。
  final List<String> ownDomains;

  /// 「开始采集」时拉名单最多等这么久，拉不到用手上的。
  final Duration panelWait;
}

/// 采集结果里的一行 + 页面上该亮哪个。
class SplitRow {
  const SplitRow(this.thing, {required this.now, required this.choice, required this.excluded});

  final SplitThing thing;

  /// 改过的按选的，没改过按看到的：direct / proxy（网站）；direct / split（App）
  final String now;

  /// 改过的选择；没改过为空
  final String choice;

  /// 取消勾选的关联网址
  final Set<String> excluded;

  String get key => thing.key;
  String get kind => thing.kind;
  String get name => thing.name;
}

@immutable
class SmartSplitState {
  const SmartSplitState({
    this.connected = false,
    this.collecting = false,
    this.pickable = const [],
    this.fixed = const [],
    this.mine = const [],
    this.rowNote = const {},
    this.mineNote = const {},
    this.loggedIn = false,
    this.holding = false,
    this.applying = const {},
    this.retryAs = const {},
  });

  final bool connected;
  final bool collecting;
  final List<SplitRow> pickable;
  final List<SplitRow> fixed;
  final List<SplitChoice> mine;

  /// 采集里那一行：reconnecting（正在改）/ done（好了）/ failed（没改成）/ full（满 50 个）
  final Map<String, String> rowNote;

  /// 我们自己正在重开隧道。页面留在原地，不要换成「还没连上」。
  final bool holding;

  /// 正在改成哪边：direct / proxy / default。按钮先写「正在改」，连上才亮新的那边。
  final Map<String, String> applying;

  /// 没改成时再点一下：当时点的那个选项；reset = 再改回默认。
  final Map<String, String> retryAs;

  /// 「我改过的」那一行：retry（没存上，点一下重试）
  final Map<String, String> mineNote;
  final bool loggedIn;
}

/// 智能分流页的逻辑（VPN 仓库 docs/计划/智能分流-自己改网站.md 三、四；Windows splitcontroller.cpp 的安卓版）。
/// 安卓改了要重连一次才生效（内核没有热更新）。采集记录只在内存：停止、离开这页、断开就清空；
/// 切到浏览器再回来列表还在；我们自己选了以后的那次重连不算断开。
class SmartSplitController {
  SmartSplitController(this.deps) : _collector = Collector(deps.boxLog);

  final SmartSplitDeps deps;
  final Collector _collector;
  void Function(SmartSplitState)? onChange;

  SmartSplitState _state = const SmartSplitState();
  SmartSplitState get state => _state;

  var _choices = SplitChoices();
  ThingList? _things;
  var _defaults = const RouteDefaults();
  var _last = <SplitThing>[];
  final _defaultNow = <String, String>{}; // 这次采集第一次看到它时走的那边
  final _listed = <String>{}; // 这次采集列出过的：全走本地的 App 也照样列
  final _excluded = <String, Set<String>>{};
  final _rowNote = <String, String>{};
  final _mineNote = <String, String>{};
  final _pendingDone = <String>{};
  // 一次只重连一次（审查 2）：重连中又选了的，等这次完了再重连一次；这些行一起等结果
  Future<bool>? _reconnecting;
  var _again = false;
  final _waitingRows = <String>{};
  var _connected = false;

  /// 这次重开是我们改规则，页面不要换成「还没连上」。失败后也留着，等人再点一次。
  var _applyHold = false;
  final _applying = <String, String>{};
  final _retryAs = <String, String>{};
  final _choiceBefore = <String, SplitChoice?>{};
  final _shownBefore = <String, String>{};
  var _starting = false;
  var _left = false; // 离开这页以后：还在路上的异步步骤不再开始采集、不再补发

  /// 打开这页：读本机的、拉新名单、跟账号对一下（补发没存上的、再删没删成的）。
  Future<void> open({required bool connected}) async {
    _connected = connected;
    _choices = loadChoices(deps.baseDir);
    adoptOwner(_choices, deps.accountId?.call() ?? '');
    _defaults = loadDefaults(deps.baseDir);
    _things = await deps.loadThings();
    if (_left) return;
    _emit();
    await _refreshThings();
    if (_left) return;
    await _syncAccount();
    _emit();
  }

  Future<void> _refreshThings() async {
    final now = _things;
    final body = await deps.api().things(now?.version ?? 0);
    if (body == null) return;
    final next = now == null ? ThingList.parse(body) : ThingList.pickNewer(now, body);
    if (next == null) return;
    _things = next;
    await deps.saveThings(body);
    for (final key in dropLocked(_choices, next)) {
      _choices.remove(key);
    }
    saveChoices(deps.baseDir, _choices);
  }

  /// 换了账号（页面还开着，或账号信息刚读出来）。上个号的网站丢掉，再跟这个号对。
  Future<void> onAccount(String account) async {
    if (_left || account.isEmpty) return;
    final prev = _choices.owner;
    adoptOwner(_choices, account);
    saveChoices(deps.baseDir, _choices);
    if (prev != account) _emit();
    await _syncAccount();
  }

  Future<void> _syncAccount() async {
    // 还不知道是哪个号：先留着不发。开机自动连时凭证已经是新号、账号信息还没读出来，会把上个号没存上的补发出去（10-26 审查）。
    if ((deps.accountId?.call() ?? '').isEmpty) return;
    final api = deps.api();
    final server = await api.list();
    if (server == null || _left) return;
    final merged = mergeAccountSites(_choices, server);
    _choices
      ..setItems(merged.items)
      ..setPendingDeletes(merged.redelete);
    saveChoices(deps.baseDir, _choices);
    for (final key in merged.resend) {
      await _upload(key);
    }
    for (final key in merged.redelete) {
      if (await api.del(key)) {
        _choices.setPendingDeletes(_choices.pendingDeletes.where((k) => k != key).toList());
        saveChoices(deps.baseDir, _choices);
      }
    }
  }

  Future<void> startCollect() async {
    if (!_connected || _state.collecting || _starting) return;
    _starting = true; // 连点两下只开一次
    try {
      // 面板慢时最多等 panelWait，拉不到用手上的名单（以前跟着 dio 15～20 秒超时卡在这里）
      await _refreshThings().timeout(deps.panelWait, onTimeout: () {});
      await closeBrowserConns(deps.currentConfigPath, browserPackages);
    } finally {
      _starting = false;
    }
    if (_left || !_connected) return;
    _collector.start();
    _last = [];
    _defaultNow.clear();
    _listed.clear();
    _excluded.clear();
    _rowNote.clear();
    _emit(collecting: true);
  }

  void stopCollect() => _clear();

  /// 返回键离开这页。
  void leave() {
    _left = true;
    _clear();
  }

  void _clear() {
    _collector.stop();
    _last = [];
    _rowNote.clear();
    _pendingDone.clear();
    _applyHold = false;
    _applying.clear();
    _retryAs.clear();
    _choiceBefore.clear();
    _shownBefore.clear();
    _emit(collecting: false);
  }

  /// 每秒一次（只在页面显示、正在采集时）。
  void tick() {
    if (!_collector.running) return;
    final things = _things;
    if (things == null) return;
    _last = classify(
      _collector.poll(),
      things,
      deps.psl,
      ownDomains: deps.ownDomains,
      appName: deps.appName,
      alwaysShow: {..._listed, for (final c in _choices.items) c.key},
    );
    for (final t in _last) {
      _defaultNow.putIfAbsent(t.key, () => t.now);
      _listed.add(t.key);
    }
    _emit();
  }

  /// 连接状态变了。断开就清空采集（我们自己选了以后的那次重连不算）。
  void onConnection({required bool connected}) {
    _connected = connected;
    if (!connected && !_applyHold && _reconnecting == null && _collector.running) {
      _clear();
      return;
    }
    if (connected) {
      for (final key in _pendingDone) {
        _commitApply(key);
        _rowNote[key] = 'done';
      }
      _pendingDone.clear();
      if (_reconnecting == null && !_rowNote.containsValue('failed')) _applyHold = false;
    }
    _emit();
  }

  /// 页面上每行只有两个选项、没有「默认」：选回原来走的那边 = 改回默认。
  Future<void> choose(String key, String picked) async {
    final found = _last.where((t) => t.key == key).firstOrNull;
    if (found == null) return;
    final thing = _withExclusions(found);
    var choice = picked;
    final chosen = _choices.choiceFor(key);
    final original = _defaultNow[key] ?? _choices.wasFor(key);
    final appDefaultDirect = thing.kind == 'app' && _defaults.appsDirect.contains(thing.pkg);
    if ((thing.kind == 'app' && choice == (appDefaultDirect ? 'direct' : 'split')) ||
        (thing.kind == 'downloader' && choice == 'direct')) {
      choice = 'default';
    } else if (thing.kind == 'site' && original.isNotEmpty && choice == original) {
      choice = 'default';
    }
    if (choice == 'default' && chosen.isEmpty && !_rowNote.containsKey(key)) return; // 本来就是这样
    _remember(key, thing, choice, picked);
    switch (_choices.set(thing, choice, was: thing.kind == 'site' ? original : '')) {
      case SetResult.full:
        _forget(key);
        _rowNote[key] = 'full';
        _emit();
        return;
      case SetResult.invalid:
        _forget(key);
        return;
      case SetResult.ok:
        break;
    }
    saveChoices(deps.baseDir, _choices);
    await _applyAndUpload(key, rowKey: key, accountKeyOf: _accountKeyOf(thing));
  }

  /// 「我改过的」里的「改回默认」。
  Future<void> resetOne(String key) async {
    final c = _choices.items.where((x) => x.key == key).firstOrNull;
    if (c == null) return;
    final shown = _last.where((t) => t.key == key).firstOrNull;
    if (shown != null) _remember(key, shown, 'default', 'reset');
    else {
      _choiceBefore[key] = c;
      _shownBefore[key] = c.choice;
      _applying[key] = 'default';
      _retryAs[key] = 'reset';
    }
    _choices.remove(key);
    _mineNote.remove(key);
    saveChoices(deps.baseDir, _choices);
    await _applyAndUpload(key, accountKeyOf: accountKey(c));
  }

  /// 「全部改回默认」（页面上先问过一句）。
  Future<void> resetAll() async {
    final snap = [..._choices.items];
    final deleted = [..._choices.pendingDeletes];
    _choices.clear();
    _mineNote.clear();
    saveChoices(deps.baseDir, _choices);
    final ok = await _reconnect(null);
    if (!ok) {
      _choices
        ..setItems(snap)
        ..setPendingDeletes(deleted);
      saveChoices(deps.baseDir, _choices);
      _applyHold = false;
      _emit();
      return;
    }
    if (await deps.api().reset()) {
      _choices.setPendingDeletes(const []);
      saveChoices(deps.baseDir, _choices);
    }
    _emit();
  }

  Future<void> retrySync(String key) async {
    await _upload(key);
    _emit();
  }

  void setDomainIncluded(String key, String domain, {required bool included}) {
    final set = _excluded.putIfAbsent(key, () => <String>{});
    included ? set.remove(domain) : set.add(domain);
    _emit();
  }

  @visibleForTesting
  void debugAddSite(String host, String choice) {
    _choices.set(
      SplitThing(key: 'site:$host')
        ..kind = 'site'
        ..name = host
        ..host = host
        ..domains = [host],
      choice,
    );
    saveChoices(deps.baseDir, _choices);
  }

  /// 本机先生效（重连），再存账号。没连回来就撤掉这次，不往账号里写。
  Future<void> _applyAndUpload(String key, {String? rowKey, required String accountKeyOf}) async {
    final ok = await _reconnect(rowKey);
    if (!ok) {
      _emit();
      return;
    }
    if (_choices.choiceFor(key).isEmpty) {
      await deps.api().del(accountKeyOf);
    } else {
      await _upload(key);
    }
    _emit();
  }

  /// 重连让新的选择生效。box.log 重连不清空，接着读就行（审查 1：以前从头读，把采集开始前的记录也读进来了）。
  Future<bool> _reconnect(String? rowKey) {
    _applyHold = true;
    if (rowKey != null) {
      _rowNote[rowKey] = 'reconnecting';
      _waitingRows.add(rowKey);
    }
    _emit();
    final running = _reconnecting;
    if (running != null) {
      _again = true;
      return running;
    }
    return _reconnecting = _reconnectLoop();
  }

  void _remember(String key, SplitThing thing, String choice, String retry) {
    _choiceBefore[key] = _choices.items.where((c) => c.key == key).firstOrNull;
    _shownBefore[key] = _shownNow(thing);
    _applying[key] = choice;
    _retryAs[key] = retry;
  }

  void _forget(String key) {
    _choiceBefore.remove(key);
    _shownBefore.remove(key);
    _applying.remove(key);
    _retryAs.remove(key);
  }

  void _commitApply(String key) => _forget(key);

  void _revert(String key) {
    final prev = _choiceBefore[key];
    _choices.putBack(key, prev);
    _applying.remove(key);
    _choiceBefore.remove(key);
    _shownBefore.remove(key);
  }

  String _shownNow(SplitThing t) {
    var choice = _choices.choiceFor(t.key);
    if (t.kind == 'app') {
      choice = effectiveAppChoice(choice, serverDefaultDirect: _defaults.appsDirect.contains(t.pkg));
    }
    if (choice == 'default') choice = '';
    return choice.isEmpty ? t.now : choice;
  }

  Future<bool> _reconnectLoop() async {
    var ok = true;
    do {
      _again = false;
      // 连之前那一步会读这份再写回去：以内存里的为准，每次重连前、重连后都存一次，中途选的不会被盖掉
      saveChoices(deps.baseDir, _choices);
      ok = await deps.reconnect();
    } while (_again && ok);
    // 重连过程里可能换了号：以现在这个号为准再存，别把上个号的网站写回去
    adoptOwner(_choices, deps.accountId?.call() ?? '');
    saveChoices(deps.baseDir, _choices);
    _reconnecting = null;
    final rows = {..._waitingRows};
    _waitingRows.clear();
    if (!ok) {
      for (final key in rows) {
        _revert(key);
        _rowNote[key] = 'failed';
      }
      saveChoices(deps.baseDir, _choices);
      // 人还在这一页：列表留着，按钮退回原来那边，行里写「没改成」。
      _applyHold = rows.isNotEmpty;
      _emit();
      return false;
    }
    for (final key in rows) {
      if (_connected) {
        _commitApply(key);
        _rowNote[key] = 'done';
      } else {
        _pendingDone.add(key);
      }
    }
    _applyHold = _pendingDone.isNotEmpty || _rowNote.containsValue('failed');
    return true;
  }

  Future<void> _upload(String key) async {
    final c = _choices.items.where((x) => x.key == key).firstOrNull;
    if (c == null) return;
    if (await deps.api().set(routeSetBody(c, deps.appVer, deps.deviceId))) {
      _choices.markSynced(key);
      saveChoices(deps.baseDir, _choices);
      _mineNote.remove(key);
    } else {
      _mineNote[key] = 'retry';
    }
  }

  SplitThing _withExclusions(SplitThing t) {
    final ex = _excluded[t.key];
    if (ex == null || ex.isEmpty) return t;
    return SplitThing(key: t.key)
      ..kind = t.kind
      ..name = t.name
      ..host = t.host
      ..pkg = t.pkg
      ..now = t.now
      ..lockWhy = t.lockWhy
      ..domains = t.domains.where((d) => !ex.contains(d) || d == t.host).toList();
  }

  String _accountKeyOf(SplitThing t) => t.kind == 'site' ? t.key : 'app:${t.pkg}';

  /// 还没连上之前，「我改过的」仍显示改之前的，不要先写上「走本地」。
  List<SplitChoice> _visibleMine() {
    final out = <SplitChoice>[];
    for (final c in _choices.items) {
      if (_applying.containsKey(c.key)) {
        final prev = _choiceBefore[c.key];
        if (prev != null) out.add(prev);
      } else {
        out.add(c);
      }
    }
    for (final key in _applying.keys) {
      final prev = _choiceBefore[key];
      if (prev != null && !out.any((c) => c.key == key)) out.add(prev);
    }
    return out;
  }

  void _emit({bool? collecting}) {
    final rows = <SplitRow>[];
    final fixed = <SplitRow>[];
    for (final t in _last) {
      var choice = _choices.choiceFor(t.key);
      var now = '';
      if (_applying.containsKey(t.key)) {
        final prev = _choiceBefore[t.key];
        choice = prev?.choice ?? '';
        now = _shownBefore[t.key] ?? '';
      }
      if (t.kind == 'app') {
        choice = effectiveAppChoice(choice, serverDefaultDirect: _defaults.appsDirect.contains(t.pkg));
      }
      if (choice == 'default') choice = '';
      if (now.isEmpty) now = choice.isEmpty ? t.now : choice;
      final row = SplitRow(t, now: now, choice: choice, excluded: {...?_excluded[t.key]});
      (t.kind == 'locked' ? fixed : rows).add(row);
    }
    _state = SmartSplitState(
      connected: _connected,
      collecting: collecting ?? _state.collecting,
      pickable: rows,
      fixed: fixed,
      mine: _visibleMine(),
      rowNote: Map.unmodifiable(_rowNote),
      mineNote: Map.unmodifiable(_mineNote),
      loggedIn: deps.loggedIn(),
      holding: _applyHold || _reconnecting != null || _rowNote.containsValue('reconnecting') || _rowNote.containsValue('failed'),
      applying: Map.unmodifiable(_applying),
      retryAs: Map.unmodifiable(_retryAs),
    );
    onChange?.call(_state);
  }
}
