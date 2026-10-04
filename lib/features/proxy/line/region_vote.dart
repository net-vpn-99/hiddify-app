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
  });

  final String code;
  final String name;
  final String flag;
  final int votes;
  final String status;
  final String note;
  final bool mine;

  factory RegionItem.fromMap(Map raw) {
    return RegionItem(
      code: '${raw['code'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      flag: '${raw['flag'] ?? ''}',
      votes: raw['votes'] is num ? (raw['votes'] as num).toInt() : 0,
      status: '${raw['status'] ?? ''}',
      note: '${raw['note'] ?? ''}',
      mine: raw['mine'] == true,
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
    this.threshold = 20,
    this.promiseDays = 3,
    this.regions = const [],
    this.suggest = const [],
    this.message = '',
    this.hasLine = false,
    this.busy = false,
  });

  final bool enabled;
  final bool canVote;
  final int threshold;
  final int promiseDays;
  final List<RegionItem> regions;
  final List<RegionHint> suggest;
  final String message;
  final bool hasLine;
  final bool busy;

  RegionBoard copyWith({
    bool? enabled,
    bool? canVote,
    int? threshold,
    int? promiseDays,
    List<RegionItem>? regions,
    List<RegionHint>? suggest,
    String? message,
    bool? hasLine,
    bool? busy,
    bool clearMessage = false,
  }) {
    return RegionBoard(
      enabled: enabled ?? this.enabled,
      canVote: canVote ?? this.canVote,
      threshold: threshold ?? this.threshold,
      promiseDays: promiseDays ?? this.promiseDays,
      regions: regions ?? this.regions,
      suggest: suggest ?? this.suggest,
      message: clearMessage ? '' : (message ?? this.message),
      hasLine: hasLine ?? this.hasLine,
      busy: busy ?? this.busy,
    );
  }
}

final regionVoteProvider = NotifierProvider<RegionVoteNotifier, RegionBoard>(RegionVoteNotifier.new);

class RegionVoteNotifier extends Notifier<RegionBoard> {
  int _loadSerial = 0;
  int _suggestSerial = 0;

  @override
  RegionBoard build() => const RegionBoard();

  Future<Options?> _opt() async {
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) return null;
    return Options(headers: {'auth_data': token, 'Authorization': token});
  }

  Future<void> load() async {
    final opt = await _opt();
    if (opt == null) return;
    final serial = ++_loadSerial;
    state = state.copyWith(busy: true, clearMessage: true, hasLine: false);
    try {
      final res = await PanelApiBase.dio().get<dynamic>('/api/v1/gsl_shop/regions', options: opt);
      if (serial != _loadSerial) return;
      state = _boardFrom(res.data, state).copyWith(busy: false, suggest: const []);
    } catch (_) {
      if (serial != _loadSerial) return;
      state = state.copyWith(busy: false);
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
      state = state.copyWith(suggest: hints);
    } catch (_) {}
  }

  Future<void> vote(String code) async {
    final opt = await _opt();
    if (opt == null) return;
    final serial = ++_loadSerial;
    state = state.copyWith(busy: true, clearMessage: true, hasLine: false);
    try {
      final res = await PanelApiBase.dio().post<dynamic>(
        '/api/v1/gsl_shop/regions/vote',
        data: {'code': code},
        options: opt,
      );
      if (serial != _loadSerial) return;
      state = _boardFrom(res.data, state).copyWith(busy: false, suggest: const []);
    } on DioException catch (e) {
      if (serial != _loadSerial) return;
      final body = e.response?.data;
      final map = body is Map ? body : const {};
      final data = map['data'] is Map ? map['data'] as Map : const {};
      state = state.copyWith(
        busy: false,
        message: '${map['message'] ?? '没投上'}',
        hasLine: data['has_line'] == true,
      );
    }
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
  return RegionBoard(
    enabled: data['enabled'] != false,
    canVote: data['can_vote'] == true,
    threshold: threshold > 0 ? threshold : 20,
    promiseDays: days > 0 ? days : 3,
    regions: regions,
  );
}

Future<void> showRegionSheet(BuildContext context, WidgetRef ref) async {
  await ref.read(regionVoteProvider.notifier).load();
  if (!context.mounted) return;
  final height = MediaQuery.sizeOf(context).height * 0.85;
  await showModalBottomSheet<void>(
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
  String _local = '';

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(regionVoteProvider);
    final tokens = PurchaseTokens.of(context);
    const warn = Color(0xFFA66116);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text('想要的地区', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '会员可以投票想要的地区，一个地区够 ${board.threshold} 票，我们 ${board.promiseDays} 天内开通。每人同时投 1 票，可以改投。',
              style: TextStyle(fontSize: 12, color: tokens.secondary),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [for (final row in board.regions) _regionRow(row, board, tokens)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (board.message.isNotEmpty || _local.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      board.message.isNotEmpty ? board.message : _local,
                      style: const TextStyle(fontSize: 12, color: warn),
                    ),
                  ),
                if (board.hasLine)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('去线路列表')),
                  ),
                for (final hint in board.suggest)
                  InkWell(
                    onTap: () {
                      setState(() {
                        _picked = hint.code;
                        _local = '';
                        _field.text = hint.name;
                      });
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
                        decoration: const InputDecoration(hintText: '发起新地区', isDense: true),
                        onChanged: (text) {
                          _picked = '';
                          _local = '';
                          ref.read(regionVoteProvider.notifier).suggest(text);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        if (!board.canVote) {
                          Navigator.of(context).pop();
                          context.pushNamed('purchase');
                          return;
                        }
                        if (_picked.isEmpty) {
                          setState(() => _local = '没有找到这个地区');
                          return;
                        }
                        ref.read(regionVoteProvider.notifier).vote(_picked);
                        setState(() {
                          _picked = '';
                          _field.clear();
                        });
                      },
                      child: const Text('发起'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _regionRow(RegionItem row, RegionBoard board, PurchaseTokens tokens) {
    final label = !board.canVote ? '成为会员后投票' : (row.mine ? '取消' : '投票');
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
              const Spacer(),
              Text(
                row.mine ? '你投的 ✓' : '${row.votes} / ${board.threshold} 票',
                style: TextStyle(fontSize: 11, color: row.mine ? tokens.remaining : tokens.secondary),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  if (!board.canVote) {
                    Navigator.of(context).pop();
                    context.pushNamed('purchase');
                    return;
                  }
                  ref.read(regionVoteProvider.notifier).vote(row.mine ? '' : row.code);
                },
                child: Text(label, style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
          if (row.note.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: (row.votes / board.threshold).clamp(0, 1).toDouble(),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(row.note, style: TextStyle(fontSize: 11, color: tokens.remaining)),
            ),
        ],
      ),
    );
  }
}
