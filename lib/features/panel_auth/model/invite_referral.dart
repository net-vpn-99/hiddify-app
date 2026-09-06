/// 「我邀请的人」列表里的一条（服务端 GslInviteBonus 插件
/// `GET /api/v1/user/gsl_invite/referrals` 返回，邮箱已打码）。
class InviteReferral {
  const InviteReferral({
    required this.emailMask,
    required this.createdAt,
    required this.paid,
    required this.commissionCents,
  });

  final String emailMask;

  /// 注册时间，unix 秒。
  final int createdAt;

  /// 好友是否已付过费。
  final bool paid;

  /// 你从这个人身上拿到的返利，单位「分」。
  final int commissionCents;

  double get commissionYuan => commissionCents / 100;

  factory InviteReferral.fromJson(Map<String, dynamic> j) {
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    return InviteReferral(
      emailMask: (j['email_mask'] as String?)?.trim() ?? '***',
      createdAt: n(j['created_at']).toInt(),
      paid: j['paid'] == true,
      commissionCents: n(j['commission']).toInt(),
    );
  }
}
