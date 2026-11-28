import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_metrics.dart';
import '../theme/motion.dart';

/// 点击版本号的书语诗签彩蛋：连点 5 次弹出一张随机"书语"卡片，
/// 墨迹晕开后浮现一句与读书相关的古文及其出处。纯加法彩蛋，不碰
/// 任何主流程；文案只本地化界面按钮，诗签内容本身是古籍原文
/// （含 Web 服务页那首"邂逅相遇"的出处），各语言通用。
///
/// 数据故意不走 ARB：诗签是内容不是界面文案，塞进 5 个 locale 的
/// 翻译没有意义（"读万卷书"翻成英文就不再是那句诗了）。
class BookQuote {
  final String text;
  final String source;
  const BookQuote(this.text, this.source);
}

const List<BookQuote> kBookQuotes = [
  BookQuote('邂逅相遇，适我愿兮。', '《诗经·郑风·野有蔓草》'),
  BookQuote('学而时习之，不亦说乎？', '《论语·学而》'),
  BookQuote('敏而好学，不耻下问。', '《论语·公冶长》'),
  BookQuote('尽信书，则不如无书。', '《孟子·尽心下》'),
  BookQuote('读书破万卷，下笔如有神。', '杜甫《奉赠韦左丞丈二十二韵》'),
  BookQuote('腹有诗书气自华。', '苏轼《和董传留别》'),
  BookQuote('旧书不厌百回读，熟读深思子自知。', '苏轼《送安惇秀才失解西归》'),
  BookQuote('问渠那得清如许？为有源头活水来。', '朱熹《观书有感》'),
  BookQuote('纸上得来终觉浅，绝知此事要躬行。', '陆游《冬夜读书示子聿》'),
  BookQuote('书卷多情似故人，晨昏忧乐每相亲。', '于谦《观书》'),
  BookQuote('三更灯火五更鸡，正是男儿读书时。', '颜真卿《劝学》'),
  BookQuote('读万卷书，行万里路。', '董其昌《画禅室随笔》'),
];

/// 弹出诗签。由设置页连点版本号 5 次触发（见 settings_screen）。
Future<void> showBookQuoteSlip(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    builder: (_) => const BookQuoteSlip(),
  );
}

class BookQuoteSlip extends StatefulWidget {
  const BookQuoteSlip({super.key});

  @override
  State<BookQuoteSlip> createState() => _BookQuoteSlipState();
}

class _BookQuoteSlipState extends State<BookQuoteSlip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ink;
  late final Animation<double> _blob1;
  late final Animation<double> _blob2;
  late final Animation<double> _blob3;
  late final Animation<double> _textIn;
  late final Animation<double> _sourceIn;
  late final Animation<double> _actionIn;
  late BookQuote _current;
  int _lastIndex = -1;
  final math.Random _random = math.Random();

  @override
  void initState() {
    super.initState();
    _ink = AnimationController(vsync: this, duration: AppMotion.slowest);
    // 三团墨迹错峰晕开（0 → 0.66），随后文字、出处、按钮依次浮现。
    _blob1 = _ink.withInterval(
      Tween<double>(begin: 0.0, end: 1.0),
      begin: 0.0,
      end: 0.45,
    );
    _blob2 = _ink.withInterval(
      Tween<double>(begin: 0.0, end: 1.0),
      begin: 0.12,
      end: 0.55,
    );
    _blob3 = _ink.withInterval(
      Tween<double>(begin: 0.0, end: 1.0),
      begin: 0.24,
      end: 0.66,
    );
    _textIn = _ink.withInterval(
      Tween<double>(begin: 0.0, end: 1.0),
      begin: 0.4,
      end: 0.75,
      curve: MotionCurves.enter,
    );
    _sourceIn = _ink.withInterval(
      Tween<double>(begin: 0.0, end: 1.0),
      begin: 0.6,
      end: 0.88,
    );
    _actionIn = _ink.withInterval(
      Tween<double>(begin: 0.0, end: 1.0),
      begin: 0.8,
      end: 1.0,
    );
    _reshuffle();
    unawaited(_ink.forward());
  }

  /// 换一张：排除刚展示的那句，重放墨迹动画。
  void _reshuffle() {
    final pool = [
      for (var i = 0; i < kBookQuotes.length; i++)
        if (i != _lastIndex) kBookQuotes[i],
    ];
    _current = pool[_random.nextInt(pool.length)];
    _lastIndex = kBookQuotes.indexOf(_current);
  }

  void _drawAgain() {
    setState(() {
      _reshuffle();
      _ink
        ..reset()
        ..forward();
    });
  }

  @override
  void dispose() {
    _ink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 36, 28, 20),
            child: AnimatedBuilder(
              animation: _ink,
              builder: (context, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 墨迹：三团主色低透明度圆斑错峰晕开，铺在文字底层。
                    SizedBox(
                      width: 120,
                      height: 120,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          _inkBlob(_blob1.value, 110, 0.10, cs.primary),
                          Transform.translate(
                            offset: const Offset(-18, 14),
                            child: _inkBlob(_blob2.value, 70, 0.14, cs.primary),
                          ),
                          Transform.translate(
                            offset: const Offset(20, -10),
                            child: _inkBlob(_blob3.value, 56, 0.12, cs.primary),
                          ),
                          // 签头：书图标压在墨迹上，随墨迹一起显现。
                          Opacity(
                            opacity: _blob1.value.clamp(0.0, 1.0),
                            child: Icon(
                              Icons.auto_stories_rounded,
                              color: cs.primary,
                              size: 34,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Opacity(
                      opacity: _textIn.value.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - _textIn.value)),
                        child: Text(
                          _current.text,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.7,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Opacity(
                      opacity: _sourceIn.value.clamp(0.0, 1.0),
                      child: Text(
                        '—— ${_current.source}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Opacity(
                      opacity: _actionIn.value.clamp(0.0, 1.0),
                      child: TextButton.icon(
                        onPressed: _drawAgain,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(t.bookQuoteAgain),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _inkBlob(double t, double size, double alpha, Color color) {
    if (t <= 0) return const SizedBox.shrink();
    // 墨迹不是圆，是洇开的晕：径向渐变从实到虚。
    return Opacity(
      opacity: (t * alpha).clamp(0.0, 1.0),
      child: Transform.scale(
        scale: 0.4 + 0.6 * t,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: 1),
                color.withValues(alpha: 0.35),
                color.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
