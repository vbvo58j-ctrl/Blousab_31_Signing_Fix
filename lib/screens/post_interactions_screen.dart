import 'dart:io';

import 'package:flutter/material.dart';

import '../services/presence_service.dart';
import '../widgets/blousab_page.dart';
import '../widgets/blousab_time.dart';
import '../widgets/blousab_visuals.dart';
import 'user_profile_screen.dart';

/// إجمالي الإعجابات والمشاركات لقائمة منشورات (لصاحب الحساب فقط).
({int likes, int shares}) blousabInteractionTotals(Iterable<Map<String, dynamic>> posts) {
  var likes = 0, shares = 0;
  for (final p in posts) {
    likes += (p['likes'] as List?)?.length ?? 0;
    final log = (p['shareLog'] as List?)?.length ?? 0;
    final legacy = (p['shares'] as num?)?.toInt() ?? 0;
    shares += log > legacy ? log : legacy;
  }
  return (likes: likes, shares: shares);
}

class _Event {
  _Event({required this.userId, required this.name, required this.at, required this.post, this.detail = ''});
  final String userId;
  final String name;
  final int at;
  final Map<String, dynamic> post;
  final String detail;
}

/// شاشة التفاعلات: منشور واحد أو كل منشورات الحساب. تُفتح لصاحب المنشور فقط.
class PostInteractionsScreen extends StatefulWidget {
  const PostInteractionsScreen({super.key, required this.posts, required this.title});
  final List<Map<String, dynamic>> posts;
  final String title;
  @override
  State<PostInteractionsScreen> createState() => _PostInteractionsScreenState();
}

class _PostInteractionsScreenState extends State<PostInteractionsScreen> {
  int _tab = 0; // 0 إعجابات، 1 مشاركات
  late List<_Event> _likes;
  late List<_Event> _shares;
  int _legacyShares = 0;

  @override
  void initState() {
    super.initState();
    _build();
  }

  void _build() {
    final likes = <_Event>[];
    final shares = <_Event>[];
    var legacy = 0;
    for (final post in widget.posts) {
      final log = Map<String, dynamic>.from(post['likeLog'] as Map? ?? const {});
      for (final uid in List<String>.from(post['likes'] as List? ?? const [])) {
        final info = log[uid] is Map ? Map<String, dynamic>.from(log[uid] as Map) : const <String, dynamic>{};
        likes.add(_Event(
          userId: uid,
          name: BlousabPresence.instance.nameOf(uid, (info['name'] ?? 'مستخدم بلوساب').toString()),
          at: (info['at'] as num?)?.toInt() ?? 0,
          post: post,
        ));
      }
      final sl = (post['shareLog'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      for (final e in sl) {
        final uid = e['userId']?.toString() ?? '';
        shares.add(_Event(
          userId: uid,
          name: BlousabPresence.instance.nameOf(uid, (e['name'] ?? 'مستخدم بلوساب').toString()),
          at: (e['at'] as num?)?.toInt() ?? 0,
          post: post,
          detail: (e['toName'] ?? '').toString(),
        ));
      }
      final count = (post['shares'] as num?)?.toInt() ?? 0;
      if (count > sl.length) legacy += count - sl.length;
    }
    likes.sort((a, b) => b.at.compareTo(a.at));
    shares.sort((a, b) => b.at.compareTo(a.at));
    _likes = likes;
    _shares = shares;
    _legacyShares = legacy;
  }

  Widget _thumb(Map<String, dynamic> post) {
    final path = post['mediaPath']?.toString() ?? '';
    final type = post['mediaType']?.toString() ?? 'text';
    Widget child;
    if (type == 'image' && path.isNotEmpty && File(path).existsSync()) {
      child = Image.file(File(path), fit: BoxFit.cover);
    } else if (type == 'video') {
      child = const Center(child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 26));
    } else {
      final t = (post['text']?.toString() ?? '').trim();
      child = Padding(
        padding: const EdgeInsets.all(4),
        child: Center(child: Text(t.isEmpty ? 'نص' : t, maxLines: 3, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 9.5))),
      );
    }
    return BlousabKeepColors(
      child: Container(
        width: 52, height: 52,
        decoration: BoxDecoration(color: const Color(0xFF0E1740), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF2B48A8))),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  Widget _row(_Event e, bool isShare) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: blousabCardDecoration(radius: 16),
        child: Row(children: [
          BlousabUserAvatar(userId: e.userId, name: e.name, size: 46),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              BlousabUserTap(
                userId: e.userId,
                name: e.name,
                child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 2),
              Row(children: [
                Icon(isShare ? Icons.reply_rounded : Icons.favorite_rounded, size: 15, color: isShare ? const Color(0xFF28C7FF) : const Color(0xFFFF4D6D)),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    isShare ? (e.detail.isEmpty ? 'شارك المنشور' : 'شارك المنشور مع ${e.detail}') : 'أعجبه المنشور',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFD5DEFF), fontSize: 13.5),
                  ),
                ),
              ]),
              const SizedBox(height: 2),
              BlousabTimeText(time: e.at, fallback: 'الوقت غير مسجّل', style: const TextStyle(color: Color(0xFF8FA3D8), fontSize: 11.5)),
            ]),
          ),
          const SizedBox(width: 8),
          _thumb(e.post),
        ]),
      );

  Widget _tabChip(int index, IconData icon, Color color, String label) {
    final on = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = index),
        child: Container(
          height: 46,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: on ? color.withOpacity(.22) : const Color(0xFF06122E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? color : const Color(0xFF2B48A8), width: 1.6),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _tab == 0 ? _likes : _shares;
    final totalShares = _shares.length + _legacyShares;
    return BlousabPage(
      title: widget.title,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
          child: Row(children: [
            _tabChip(0, Icons.favorite_rounded, const Color(0xFFFF4D6D), 'الإعجابات ${_likes.length}'),
            _tabChip(1, Icons.reply_rounded, const Color(0xFF28C7FF), 'المشاركات $totalShares'),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 20), children: [
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Center(child: Text(_tab == 0 ? 'لا توجد إعجابات بعد.' : 'لا توجد مشاركات بعد.', style: const TextStyle(color: Color(0xFFC6D0F2), fontSize: 16))),
              )
            else
              ...list.map((e) => _row(e, _tab == 1)),
            if (_tab == 1 && _legacyShares > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('إضافة إلى $_legacyShares مشاركة قديمة لا تتوفر تفاصيل أصحابها.', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF8FA3D8), fontSize: 12.5)),
              ),
          ]),
        ),
      ]),
    );
  }
}
