import 'dart:async';

import 'package:flutter/material.dart';

/// تنسيق الوقت الموحّد في كل التطبيق (رسائل، منشورات، قصص، إشعارات، تفاعلات):
///  - أقل من دقيقة: «الآن»
///  - دقائق / ساعات / أيام: «قبل 5 دقائق»، «قبل ساعتين»، «قبل يوم»، «قبل 3 أيام»
///  - شهر فأكثر: التاريخ «5 نوفمبر» (ومعه السنة إن كانت سنة سابقة)
const List<String> _kMonths = <String>[
  'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
  'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
];

String _unit(int n, String one, String two, String few, String many) {
  if (n == 1) return one;
  if (n == 2) return two;
  if (n >= 3 && n <= 10) return '$n $few';
  return '$n $many';
}

DateTime? _toDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is num) {
    final ms = value.toInt();
    return ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
    final asInt = int.tryParse(value);
    if (asInt != null && asInt > 0) return DateTime.fromMillisecondsSinceEpoch(asInt);
  }
  return null;
}

/// يعيد نصاً فارغاً إن كان الوقت غير معروف.
String blousabTimeAgo(Object? value, {DateTime? now}) {
  final t = _toDate(value)?.toLocal();
  if (t == null) return '';
  final current = now ?? DateTime.now();
  final d = current.difference(t);
  if (d.inSeconds < 60) return 'الآن'; // يشمل أي فارق ساعة صغير سالب بين جهازين
  if (d.inMinutes < 60) return 'قبل ${_unit(d.inMinutes, 'دقيقة', 'دقيقتين', 'دقائق', 'دقيقة')}';
  if (d.inHours < 24) return 'قبل ${_unit(d.inHours, 'ساعة', 'ساعتين', 'ساعات', 'ساعة')}';
  if (d.inDays < 30) return 'قبل ${_unit(d.inDays, 'يوم', 'يومين', 'أيام', 'يوماً')}';
  final base = '${t.day} ${_kMonths[t.month - 1]}';
  return t.year == current.year ? base : '$base ${t.year}';
}

/// ساعة مشتركة: تُحدّث كل النصوص الزمنية الظاهرة تلقائياً مع مرور الوقت.
class BlousabClock {
  BlousabClock._();
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);
  static Timer? _timer;
  static void ensureStarted() {
    _timer ??= Timer.periodic(const Duration(seconds: 20), (_) => tick.value++);
  }
}

class BlousabTimeText extends StatelessWidget {
  const BlousabTimeText({super.key, required this.time, this.style, this.textDirection, this.fallback = '', this.textAlign});
  final Object? time;
  final TextStyle? style;
  final TextDirection? textDirection;
  final TextAlign? textAlign;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    BlousabClock.ensureStarted();
    return ValueListenableBuilder<int>(
      valueListenable: BlousabClock.tick,
      builder: (context, _, __) {
        final text = blousabTimeAgo(time);
        // الوقت صغير دائماً (لا يتجاوز 10.5) كي لا يأخذ مساحة من المحتوى.
        final base = style ?? const TextStyle(color: Color(0xFF8FA3D8));
        final size = base.fontSize == null || base.fontSize! > 10.5 ? 10.5 : base.fontSize;
        return Text(
          text.isEmpty ? fallback : text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: textDirection,
          textAlign: textAlign,
          style: base.copyWith(fontSize: size, height: 1.1, fontWeight: FontWeight.w500),
        );
      },
    );
  }
}
