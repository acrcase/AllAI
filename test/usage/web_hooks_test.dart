import 'dart:io';

import 'package:allai/l10n/l10n.dart';
import 'package:allai/usage/prompt_counter.dart';
import 'package:allai/usage/sources/counted_sources.dart';
import 'package:allai/usage/sources/m365_copilot_source.dart';
import 'package:allai/usage/usage_models.dart';
import 'package:allai/usage/web_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('yalnız gemini ve deepseek için sayaç betiği eklenir', () {
    expect(WebUsageHooks.scriptsFor('gemini'), hasLength(1));
    expect(WebUsageHooks.scriptsFor('deepseek'), hasLength(1));
    expect(WebUsageHooks.scriptsFor('chatgpt'), isEmpty);
    expect(WebUsageHooks.scriptsFor('ozel'), isEmpty);
  });

  test('sayaç gün anahtarıyla artar, eski gün sıfırlanır', () async {
    SharedPreferences.setMockInitialValues({
      'usage.prompts.gemini.day': '2000-01-01',
      'usage.prompts.gemini.count': 41,
    });
    expect(await PromptCounter.today('gemini'), 0);
    await Future.wait([PromptCounter.increment('gemini'), PromptCounter.increment('gemini')]);
    expect(await PromptCounter.today('gemini'), 2);
    expect(await PromptCounter.today('deepseek'), 0);
  });

  test('Gemini ve DeepSeek raporları sayacı gösterir, sayı uydurmaz', () async {
    await PromptCounter.increment('deepseek');
    final g = await GeminiSource(planHint: () => 'Google AI Pro').fetch();
    expect(g.status, UsageStatus.noData);
    expect(g.plan, 'Google AI Pro');
    expect(g.message, contains('varsayıldı'));
    expect(g.sections.single.meters[0].detail, 'Standart limitin 4 katı');
    expect(g.sections.single.meters[0].remaining, isNull);
    expect(g.sections.single.meters[1].detail, '0 istem (bu uygulamadan sayıldı)');

    final d = await DeepSeekSource().fetch();
    expect(d.status, UsageStatus.ok);
    expect(d.sections.single.meters[0].unlimited, isTrue);
    expect(d.sections.single.meters[1].detail, '1 mesaj');

    final m = await M365CopilotSource().fetch();
    expect(m.status, UsageStatus.noData);
    expect(m.title, 'Microsoft Copilot');
    expect(m.sections.single.meters.single.remaining, isNull);
  });

  test('sayaç betiği sayfayı bozmaz, yalnız istem POST\'unu sayar (node)', () async {
    final node = ['/usr/local/bin/node', '/opt/homebrew/bin/node'].where((p) => File(p).existsSync()).firstOrNull;
    if (node == null) {
      markTestSkipped('node yok');
      return;
    }
    final script = WebUsageHooks.promptCounterScript(r'StreamGenerate');
    final harness = '''
const calls = [];
const window = globalThis;
window.flutter_inappwebview = {callHandler: (...a) => calls.push(a)};
window.fetch = function (input, init) { return Promise.resolve('ok:' + (typeof input === 'string' ? input : input.url)); };
function XMLHttpRequest() {}
XMLHttpRequest.prototype.open = function (m, u) { this.m = m; this.u = u; };
XMLHttpRequest.prototype.send = function () { this.sent = true; };
globalThis.XMLHttpRequest = XMLHttpRequest;
$script
$script
(async () => {
  const r1 = await fetch('/_/BardChatUi/data/StreamGenerate?x=1', {method: 'POST'});
  await fetch('/_/BardChatUi/data/StreamGenerate?x=1');
  await fetch({url: '/other', method: 'POST'});
  const x = new XMLHttpRequest(); x.open('POST', '/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate'); x.send();
  const y = new XMLHttpRequest(); y.open('GET', '/StreamGenerate'); y.send();
  delete window.flutter_inappwebview;
  const z = new XMLHttpRequest(); z.open('POST', '/StreamGenerate'); z.send();
  console.log(JSON.stringify({calls, r1, sent: x.sent && z.sent}));
})();
''';
    final r = await Process.run(node, ['-e', harness]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(r.stdout.toString().trim(),
        '{"calls":[["allaiUsage","prompt"],["allaiUsage","prompt"]],"r1":"ok:/_/BardChatUi/data/StreamGenerate?x=1","sent":true}');
  });
}
