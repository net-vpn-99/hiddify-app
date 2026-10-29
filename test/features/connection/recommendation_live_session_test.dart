import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/proxy/active/auto_line_fixer.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/line/line_source.dart';
import 'package:hiddify/features/proxy/model/subscription_recommendation.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/stability_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/data/connect_reporter.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
class Repo implements ProxyRepository {
 int selections=0;final consumed=Completer<void>();
 late final StreamController<Either<ProxyFailure,OutboundGroup?>> events=StreamController<Either<ProxyFailure,OutboundGroup?>>(onListen:(){scheduleMicrotask(()=>events.add(right(OutboundGroup(tag:'proxy',selected:'Current',items:[OutboundInfo(tag:'Current')]))));},onCancel:(){if(!consumed.isCompleted)consumed.complete();});
 @override Stream<Either<ProxyFailure,OutboundGroup?>> watchProxies()=>events.stream;
 @override TaskEither<ProxyFailure,Unit> selectProxy(String groupTag,String outboundTag){selections++;return TaskEither.right(unit);}
 @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class Stable extends StabilityNotifier {@override StabilityState build()=>const StabilityState(10,confirmed:true);}
class Connection extends ConnectionNotifier {int stops=0;@override Stream<ConnectionStatus> build() async*{yield const Connected();}@override Future<void> abortConnection() async {stops++;}}
class Reporter extends ConnectReporter {Reporter(super.ref);@override Future<void> reportStepFailure(int step,String stage,String detail) async{}}
void main(){test('new none cannot disconnect an already confirmed live connection',() async {
 SharedPreferences.setMockInitialValues({});final prefs=await SharedPreferences.getInstance();
 final repo=Repo();late Connection connection;
 final raw=withConvertedRecommendation(jsonEncode({'schema':1,'gsl_transports':{'schema':1,'recommendation':{'schema':1,'status':'none'}}}),jsonEncode({'outbounds':[{'type':'vless','tag':'Current','server':'node.invalid','server_port':443}]}));
 final c=ProviderContainer(overrides:[
 sharedPreferencesProvider.overrideWith((ref)=>prefs),serviceRunningProvider.overrideWith((ref) async=>true),
 proxyRepositoryProvider.overrideWith((ref)=>repo),stabilityProvider.overrideWith(()=>Stable()),
 connectionNotifierProvider.overrideWith(()=>connection=Connection()), connectReporterProvider.overrideWith((ref)=>Reporter(ref)),
 activeProfileRawProvider.overrideWith((ref) async=>raw),lineSetProvider.overrideWith((ref) async=>const LineSet(locked:false,lines:[(name:'Current',desc:'',isps:null,pro:false,routeId:'')])),
 ]);addTearDown(c.dispose);
 await c.read(connectionNotifierProvider.future);c.listen(autoLineFixerProvider,(_,__){});await repo.consumed.future;
 expect(connection.stops,0);expect(repo.selections,0);
 });}
