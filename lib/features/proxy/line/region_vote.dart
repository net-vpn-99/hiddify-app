import 'dart:async';

import 'package:circle_flags/circle_flags.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class RegionItem {
  const RegionItem({
    required this.code,
    required this.name,
    required this.flag,
    required this.votes,
    required this.status,
    required this.note,
    required this.mine,
    required this.canVote,
    required this.reachedAt,
  });

  final String code;
  final String name;
  final String flag;
  final int votes;
  final String status;
  final String note;
  final bool mine;
  final bool canVote;
  final int reachedAt;

  bool get reached => status == 'reached';

  factory RegionItem.fromMap(Map raw) {
    return RegionItem(
      code: '${raw['code'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      flag: '${raw['flag'] ?? ''}',
      votes: raw['votes'] is num ? (raw['votes'] as num).toInt() : 0,
      status: '${raw['status'] ?? ''}',
      note: '${raw['note'] ?? ''}',
      mine: raw['mine'] == true,
      canVote: raw['can_vote'] != false,
      reachedAt: raw['reached_at'] is num ? (raw['reached_at'] as num).toInt() : 0,
    );
  }
}

class RegionHint {
  const RegionHint({required this.code, required this.name});
  final String code;
  final String name;
}

class RegionBoard {
  const RegionBoard({
    this.enabled = true,
    this.canVote = false,
    this.canCreate = false,
    this.voter = '',
    this.threshold = 20,
    this.promiseDays = 3,
    this.regions = const [],
    this.suggest = const [],
    this.lastCreated,
    this.nextCreateAt = 0,
    this.busy = false,
    this.voting = false,
    this.pendingCode = '',
    this.pendingCreate = false,
    this.loadFailed = false,
    this.banner = '',
    this.bannerOk = true,
    this.inputHint = '',
    this.resultName = '',
  });

  final bool enabled;
  final bool canVote;
  final bool canCreate;
  final String voter;
  final int threshold;
  final int promiseDays;
  final List<RegionItem> regions;
  final List<RegionHint> suggest;
  final Map<String, dynamic>? lastCreated;
  final int nextCreateAt;
  final bool busy;
  final bool voting;
  final String pendingCode;
  final bool pendingCreate;
  final bool loadFailed;
  final String banner;
  final bool bannerOk;
  final String inputHint;
  final String resultName;

  bool get member => voter == 'member' || (voter.isEmpty && canVote);
  bool get allowCreate => member && canCreate;

  RegionBoard copyWith({
    bool? enabled,
    bool? canVote,
    bool? canCreate,
    String? voter,
    int? threshold,
    int? promiseDays,
    List<RegionItem>? regions,
    List<RegionHint>? suggest,
    Map<String, dynamic>? lastCreated,
    int? nextCreateAt,
    bool? busy,
    bool? voting,
    String? pendingCode,
    bool? pendingCreate,
    bool? loadFailed,
    String? banner,
    bool? bannerOk,
    String? inputHint,
    String? resultName,
    bool clearLast = false,
    bool clearBanner = false,
    bool clearHint = false,
  }) {
    return RegionBoard(
      enabled: enabled ?? this.enabled,
      canVote: canVote ?? this.canVote,
      canCreate: canCreate ?? this.canCreate,
      voter: voter ?? this.voter,
      threshold: threshold ?? this.threshold,
      promiseDays: promiseDays ?? this.promiseDays,
      regions: regions ?? this.regions,
      suggest: suggest ?? this.suggest,
      lastCreated: clearLast ? null : (lastCreated ?? this.lastCreated),
      nextCreateAt: nextCreateAt ?? this.nextCreateAt,
      busy: busy ?? this.busy,
      voting: voting ?? this.voting,
      pendingCode: pendingCode ?? this.pendingCode,
      pendingCreate: pendingCreate ?? this.pendingCreate,
      loadFailed: loadFailed ?? this.loadFailed,
      banner: clearBanner ? '' : (banner ?? this.banner),
      bannerOk: bannerOk ?? this.bannerOk,
      inputHint: clearHint ? '' : (inputHint ?? this.inputHint),
      resultName: resultName ?? this.resultName,
    );
  }
}

String regionEntrySubtitle(RegionBoard board) {
  final need = board.threshold > 0 ? board.threshold : 20;
  final regions = board.regions;
  if (regions.isEmpty) return '会员投票，够 $need 票就开';
  RegionItem? earliest;
  for (final row in regions) {
    if (!row.reached) continue;
    if (earliest == null || (row.reachedAt > 0 && (earliest.reachedAt == 0 || row.reachedAt < earliest.reachedAt))) {
      earliest = row;
    }
  }
  if (earliest != null) {
    if (earliest.note.contains('正在准备')) return '${earliest.name}已达成，正在准备';
    final matched = RegExp(r'(\d{2}-\d{2})').firstMatch(earliest.note);
    if (matched != null) return '${earliest.name}已达成，${matched.group(1)} 前上线';
    return '${earliest.name}已达成，正在准备';
  }
  for (final row in regions) {
    if (row.mine) return '你投了${row.name} · ${row.votes} / $need 票';
  }
  var top = regions.first;
  for (final row in regions) {
    if (row.votes > top.votes) top = row;
  }
  return '票最多：${top.name} ${top.votes} / $need';
}

final regionVoteProvider = NotifierProvider<RegionVoteNotifier, RegionBoard>(RegionVoteNotifier.new);

class RegionVoteNotifier extends Notifier<RegionBoard> {
  int _loadSerial = 0;
  int _suggestSerial = 0;
  int _bannerSerial = 0;

  @override
  RegionBoard build() => const RegionBoard();

  Future<Options?> _opt() async {
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) return null;
    return Options(headers: {'auth_data': token, 'Authorization': token});
  }

  void clearInputHint() {
    if (state.inputHint.isEmpty) return;
    state = state.copyWith(clearHint: true);
  }

  void setInputHint(String text) {
    state = state.copyWith(inputHint: text);
  }

  Future<void> load() async {
    final opt = await _opt();
    if (opt == null) return;
    final serial = ++_loadSerial;
    state = state.copyWith(busy: true, voting: false, loadFailed: false, suggest: const []);
    try {
      final res = await PanelApiBase.dio().get<dynamic>('/api/v1/gsl_shop/regions', options: opt);
      if (serial != _loadSerial) return;
      state = _boardFrom(res.data, state).copyWith(busy: false, suggest: const [], loadFailed: false);
    } catch (_) {
      if (serial != _loadSerial) return;
      state = state.copyWith(busy: false, loadFailed: state.regions.isEmpty);
    }
  }

  Future<void> suggest(String q) async {
    final text = q.trim();
    if (text.isEmpty) {
      state = state.copyWith(suggest: const []);
      return;
    }
    final opt = await _opt();
    if (opt == null) return;
    final serial = ++_suggestSerial;
    try {
      final res = await PanelApiBase.dio().get<dynamic>(
        '/api/v1/gsl_shop/regions/suggest',
        queryParameters: {'q': text},
        options: opt,
      );
      if (serial != _suggestSerial) return;
      final raw = res.data;
      final data = raw is Map ? raw['data'] : null;
      final hints = <RegionHint>[];
      if (data is List) {
        for (final row in data) {
          if (row is Map) hints.add(RegionHint(code: '${row['code'] ?? ''}', name: '${row['name'] ?? ''}'));
        }
      }
      state = state.copyWith(
        suggest: hints,
        inputHint: hints.isEmpty ? '没找到这个地区。换个写法试试，比如 新加坡、Singapore、SG' : '',
        clearHint: hints.isNotEmpty,
      );
    } catch (_) {}
  }

  Future<void> vote(String code, {bool creating = false}) async {
    final opt = await _opt();
    if (opt == null) return;
    final serial = ++_loadSerial;
    state = state.copyWith(
      busy: true,
      voting: true,
      pendingCode: creating ? '' : code,
      pendingCreate: creating,
      suggest: const [],
      clearHint: true,
    );
    try {
      final res = await PanelApiBase.dio().post<dynamic>(
        '/api/v1/gsl_shop/regions/vote',
        data: {'code': code, 'create': creating},
        options: opt,
      );
      if (serial != _loadSerial) return;
      _present(res.data is Map ? res.data as Map : const {}, state);
    } on DioException catch (e) {
      if (serial != _loadSerial) return;
      final body = e.response?.data;
      _present(body is Map ? body : const {}, state);
    } catch (_) {
      if (serial != _loadSerial) return;
      _present(const {}, state);
    }
  }

  void _present(Map body, RegionBoard prev) {
    final data = body['data'];
    var next = prev;
    if (data is Map && data['regions'] is List) {
      next = _boardFrom({'data': data}, prev);
    }
    next = next.copyWith(
      busy: false,
      voting: false,
      pendingCreate: false,
      pendingCode: '',
      suggest: const [],
      resultName: '${body['name'] ?? next.resultName}',
    );
    final reason = '${body['reason'] ?? ''}';
    final action = '${body['action'] ?? ''}';
    if (reason == 'not_member' || reason == 'reached' || reason == 'disabled') {
      state = next.copyWith(clearBanner: true, clearHint: true);
      return;
    }
    if (reason.isEmpty && action.isEmpty && body['ok'] != true) {
      _flash(next, '没投上，网络不稳定，再试一次', ok: false, seconds: 3);
      return;
    }
    if (reason == 'mainland') {
      state = next.copyWith(inputHint: '中国大陆不需要加速');
      return;
    }
    if (reason == 'has_line') {
      state = next.copyWith(inputHint: 'has_line', resultName: '${body['name'] ?? ''}');
      return;
    }
    if (reason == 'not_found') {
      state = next.copyWith(inputHint: '没找到这个地区。换个写法试试，比如 新加坡、Singapore、SG');
      return;
    }
    if (reason == 'create_limit') {
      state = next.copyWith(inputHint: '30 天内只能发起 1 个新地区');
      return;
    }
    final name = '${body['name'] ?? ''}';
    final need = next.threshold > 0 ? next.threshold : 20;
    if (body['reached_now'] == true) {
      _flash(next, '$name够 $need 票了，我们会在 ${body['promise'] ?? ''} 前开通', ok: true, seconds: 5);
      return;
    }
    final from = '${body['from_name'] ?? ''}';
    final text = switch (action) {
      'voted' => '已投给$name',
      'switched' => '已改投$name，$from那一票已收回',
      'cancelled' => '已取消投票',
      'created' => '已发起$name，并投了第一票',
      'joined' => '$name已经在列表里，已投给它',
      _ => '',
    };
    if (text.isNotEmpty) {
      _flash(next, text, ok: true, seconds: 3);
      return;
    }
    state = next;
  }

  void _flash(RegionBoard base, String text, {required bool ok, required int seconds}) {
    final serial = ++_bannerSerial;
    state = base.copyWith(banner: text, bannerOk: ok, clearHint: true);
    Future<void>.delayed(Duration(seconds: seconds), () {
      if (_bannerSerial != serial) return;
      state = state.copyWith(clearBanner: true);
    });
  }
}

RegionBoard _boardFrom(dynamic body, RegionBoard prev) {
  final data = (body is Map && body['data'] is Map) ? body['data'] as Map : null;
  if (data == null || data['regions'] is! List) return prev.copyWith(busy: false);
  final regions = <RegionItem>[];
  for (final row in data['regions'] as List) {
    if (row is Map) regions.add(RegionItem.fromMap(row));
  }
  final threshold = data['threshold'] is num ? (data['threshold'] as num).toInt() : prev.threshold;
  final days = data['promise_days'] is num ? (data['promise_days'] as num).toInt() : prev.promiseDays;
  final voter = '${data['voter'] ?? ''}';
  final member = voter == 'member' || (voter.isEmpty && data['can_vote'] == true);
  final last = data['last_created'] is Map ? Map<String, dynamic>.from(data['last_created'] as Map) : null;
  return RegionBoard(
    enabled: data['enabled'] != false,
    canVote: data['can_vote'] == true || (voter.isEmpty && member),
    canCreate: member && data['can_create'] != false,
    voter: voter.isEmpty ? (member ? 'member' : 'guest') : voter,
    threshold: threshold > 0 ? threshold : 20,
    promiseDays: days > 0 ? days : 3,
    regions: regions,
    lastCreated: last,
    nextCreateAt: data['next_create_at'] is num ? (data['next_create_at'] as num).toInt() : 0,
    banner: prev.banner,
    bannerOk: prev.bannerOk,
    inputHint: prev.inputHint,
    resultName: prev.resultName,
  );
}

String _mmdd(int unix) {
  if (unix <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$m-$day';
}

/// 关掉抽屉时，如果点了「去看看」，返回要定位的地区名。
Future<String?> showRegionSheet(BuildContext context, WidgetRef ref) async {
  await ref.read(regionVoteProvider.notifier).load();
  if (!context.mounted) return null;
  final height = MediaQuery.sizeOf(context).height * 0.85;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(height: height, child: const _RegionSheet()),
  );
}

class _RegionSheet extends ConsumerStatefulWidget {
  const _RegionSheet();

  @override
  ConsumerState<_RegionSheet> createState() => _RegionSheetState();
}

class _RegionSheetState extends ConsumerState<_RegionSheet> {
  final _field = TextEditingController();
  String _picked = '';
  Timer? _suggestTimer;

  @override
  void dispose() {
    _suggestTimer?.cancel();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(regionVoteProvider);
    final tokens = PurchaseTokens.of(context);
    final firstLoad = board.busy && !board.voting && board.regions.isEmpty && !board.loadFailed;
    final failed = board.loadFailed && board.regions.isEmpty;
    final voted = board.regions.any((row) => row.mine);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
            child: Row(
              children: [
                const Expanded(child: Text('想要的地区', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '够 ${board.threshold} 票，${board.promiseDays} 天内开通。每人 1 票，可以改投。',
              style: TextStyle(fontSize: 12, color: tokens.secondary),
            ),
          ),
          if (board.banner.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: board.bannerOk ? tokens.okSoft : tokens.empty,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    board.banner,
                    style: TextStyle(fontSize: 12, color: board.bannerOk ? tokens.remaining : tokens.raised),
                  ),
                ),
              ),
            ),
          Expanded(
            child: firstLoad
                ? ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (var i = 0; i < 3; i++)
                        Container(
                          height: 46,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(color: tokens.fill, borderRadius: BorderRadius.circular(10)),
                        ),
                    ],
                  )
                : failed
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('没读到投票，检查网络后重试', style: TextStyle(fontSize: 13, color: tokens.secondary)),
                            const SizedBox(height: 8),
                            FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: tokens.text, foregroundColor: tokens.raised),
                              onPressed: () => ref.read(regionVoteProvider.notifier).load(),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          if (board.regions.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 28, bottom: 12),
                              child: Column(
                                children: [
                                  const Text('🌐', style: TextStyle(fontSize: 28)),
                                  const SizedBox(height: 6),
                                  Text('还没有人发起', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: tokens.text)),
                                  const SizedBox(height: 4),
                                  Text(
                                    board.member ? '输入一个国家或地区，发起第一个投票' : '会员可以发起第一个地区',
                                    style: TextStyle(fontSize: 12, color: tokens.secondary),
                                  ),
                                ],
                              ),
                            ),
                          for (final row in board.regions) _regionRow(row, board, tokens, voted),
                        ],
                      ),
          ),
          if (!firstLoad && !failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: board.allowCreate ? _composer(board, tokens) : _card(board, tokens),
            ),
        ],
      ),
    );
  }

  Widget _regionRow(RegionItem row, RegionBoard board, PurchaseTokens tokens, bool voted) {
    final showButton = board.member && !row.reached && row.canVote;
    final spinning = board.voting && !board.pendingCreate && (row.mine ? board.pendingCode.isEmpty : board.pendingCode == row.code);
    final label = row.mine ? '取消' : (voted ? '改投' : '投票');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (row.code.length == 2)
                CircleFlag(row.code.toLowerCase(), size: 18)
              else
                Text(row.flag, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(row.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tokens.text)),
              if (row.mine) ...[
                const SizedBox(width: 4),
                Text('· 你投的', style: TextStyle(fontSize: 11, color: tokens.remaining)),
              ],
              const Spacer(),
              if (row.reached)
                Flexible(
                  child: Text(row.note.isEmpty ? '已达成' : row.note, style: TextStyle(fontSize: 11, color: tokens.remaining)),
                )
              else
                Text('${row.votes} / ${board.threshold}', style: TextStyle(fontSize: 11, color: tokens.secondary)),
              if (showButton) ...[
                const SizedBox(width: 8),
                Material(
                  color: row.mine ? Colors.transparent : tokens.text,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: row.mine ? BorderSide(color: tokens.border) : BorderSide.none,
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: board.voting
                        ? null
                        : () => ref.read(regionVoteProvider.notifier).vote(row.mine ? '' : row.code),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      child: spinning
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: row.mine ? tokens.text : tokens.raised),
                            )
                          : Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: row.mine ? tokens.text : tokens.raised,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: row.reached ? 1 : (row.votes / board.threshold).clamp(0, 1).toDouble(),
              color: (row.mine || row.reached) ? tokens.remaining : tokens.secondary,
              backgroundColor: tokens.fill,
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(RegionBoard board, PurchaseTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final hint in board.suggest)
          InkWell(
            onTap: () {
              setState(() {
                _picked = hint.code;
                _field.text = hint.name;
              });
              ref.read(regionVoteProvider.notifier).clearInputHint();
              ref.read(regionVoteProvider.notifier).suggest('');
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Text(hint.name, style: TextStyle(fontSize: 13, color: tokens.text)),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _field,
                enabled: !board.voting,
                decoration: const InputDecoration(hintText: '输入国家或地区，如 新加坡', isDense: true),
                onChanged: (text) {
                  _picked = '';
                  ref.read(regionVoteProvider.notifier).clearInputHint();
                  _suggestTimer?.cancel();
                  _suggestTimer = Timer(const Duration(milliseconds: 300), () {
                    ref.read(regionVoteProvider.notifier).suggest(text);
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: tokens.text,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: board.voting
                    ? null
                    : () {
                        if (_picked.isEmpty) {
                          ref.read(regionVoteProvider.notifier).clearInputHint();
                          // 本地提示不走接口。
                          _localHint();
                          return;
                        }
                        ref.read(regionVoteProvider.notifier).vote(_picked, creating: true);
                        setState(() {
                          _picked = '';
                          _field.clear();
                        });
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: board.voting && board.pendingCreate
                      ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.raised))
                      : Text('发起', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tokens.raised)),
                ),
              ),
            ),
          ],
        ),
        if (board.inputHint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: board.inputHint == 'has_line'
                ? Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('已经有${board.resultName}线路了 · ', style: TextStyle(fontSize: 12, color: tokens.empty)),
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(board.resultName),
                        child: Text('去看看', style: TextStyle(fontSize: 12, color: tokens.remaining, decoration: TextDecoration.underline)),
                      ),
                    ],
                  )
                : Text(board.inputHint, style: TextStyle(fontSize: 12, color: tokens.empty)),
          ),
      ],
    );
  }

  void _localHint() {
    ref.read(regionVoteProvider.notifier).setInputHint('从下面的提示里选一个地区');
  }

  Widget _card(RegionBoard board, PurchaseTokens tokens) {
    final voter = board.voter.isEmpty ? (board.member ? 'member' : 'guest') : board.voter;
    var title = '投票和发起是付费会员的权益';
    var sub = '你现在是试用账号';
    var button = '开通会员';
    if (voter == 'expired') {
      title = '你的会员已到期，之前投的票暂时不算';
      sub = '续费后自动恢复';
      button = '去续费';
    } else if (voter == 'member') {
      final last = board.lastCreated;
      title = '你 ${_mmdd(last?['at'] is num ? (last!['at'] as num).toInt() : 0)} 发起过${last?['name'] ?? ''}';
      sub = '${_mmdd(board.nextCreateAt)} 后可以再发起，现在可以给列表里的地区投票';
      button = '';
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 13, color: tokens.text)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 12, color: tokens.secondary)),
                ],
              ),
            ),
            if (button.isNotEmpty) ...[
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: tokens.text, foregroundColor: tokens.raised),
                onPressed: () => context.pushNamed('purchase'),
                child: Text(button),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
