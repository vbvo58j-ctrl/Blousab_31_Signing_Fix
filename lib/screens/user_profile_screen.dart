import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/presence_service.dart';
import '../services/bluetooth_classic_service.dart';
import '../services/qr_friend_store.dart';
import '../widgets/blousab_page.dart';
import '../widgets/blousab_visuals.dart';
import 'chat_screen.dart';

Future<Map<String, String>> _me() async {
  final prefs = await SharedPreferences.getInstance();
  return {
    'id': prefs.getString('wasl_user_id') ?? '',
    'name': prefs.getString('wasl_user_name') ?? 'مستخدم بلوساب',
  };
}

/// يفتح ملفاً شخصياً عاماً لمستخدم آخر (الصورة والاسم والمنشورات والمتابعون فقط).
/// الشرط: أن يكون صاحب الحساب متصلاً الآن أو سبق أن تزامنت منشوراته.
Future<void> blousabOpenUserProfile(BuildContext context, {required String userId, String name = ''}) async {
  final me = await _me();
  if (!context.mounted) return;
  if (userId.isEmpty) {
    BlousabToast.show(context, 'هذا الحساب غير متوفر حالياً.');
    return;
  }
  if (userId == me['id']) {
    BlousabToast.show(context, 'هذا حسابك أنت. افتح ملفك من تبويب الملف الشخصي.');
    return;
  }
  final presence = BlousabPresence.instance;
  final available = presence.isOnline(userId) || await presence.hasSyncedPosts(userId);
  if (!context.mounted) return;
  if (!available) {
    BlousabToast.show(context, 'هذا الحساب غير متوفر حالياً.');
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => UserProfileScreen(userId: userId, fallbackName: name)));
}

/// مراسلة مستخدم: صديق + متوفر → المحادثة. غير متوفر → رسالة خطأ. غير صديق → واجهة طلب الصداقة.
Future<String?> _knownBluetoothAddress(String peerId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (key.startsWith('blousab_peer_id_') && prefs.getString(key) == peerId) {
        return key.substring('blousab_peer_id_'.length);
      }
    }
  } catch (_) {}
  return null;
}

Future<void> blousabMessageUser(BuildContext context, {required String userId, String name = ''}) async {
  final me = await _me();
  final myId = me['id'] ?? '';
  final myName = me['name'] ?? 'مستخدم بلوساب';
  if (!context.mounted) return;
  if (userId.isEmpty) {
    BlousabToast.show(context, 'هذا الحساب غير متوفر حالياً.');
    return;
  }
  if (userId == myId) {
    BlousabToast.show(context, 'هذا حسابك أنت.');
    return;
  }
  final presence = BlousabPresence.instance;
  final displayName = presence.nameOf(userId, name.isEmpty ? 'مستخدم بلوساب' : name);
  final friends = await QrFriendStore.loadFriends();
  if (!context.mounted) return;
  if (!friends.contains(userId)) {
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('طلب صداقة'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          BlousabRingAvatar(name: displayName, size: 64, photoPath: presence.photoPathOf(userId)),
          const SizedBox(height: 10),
          Text(displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          const Text('لا تستطيع مراسلة هذا المستخدم قبل أن يصبح صديقاً. أرسل له طلب صداقة، وبعد قبوله اضغط على المراسلة مجدداً للدخول مباشرة إلى المحادثة.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال طلب الصداقة')),
        ],
      ),
    );
    if (send == true) {
      final ok = await FriendRequests.send(myId: myId, myName: myName, recipientId: userId);
      if (context.mounted) {
        BlousabToast.show(context, ok ? 'أُرسل طلب الصداقة إلى $displayName.' : 'تعذر إرسال الطلب الآن. تأكد من تشغيل البلوتوث وWi-Fi.');
      }
    }
    return;
  }
  final peerAddress = await _knownBluetoothAddress(userId);
  var connected = false;
  if (peerAddress != null && peerAddress.isNotEmpty) {
    try {
      final bluetooth = BluetoothClassicService.instance;
      if (await bluetooth.requestPermissions() && await bluetooth.isEnabled()) {
        await bluetooth.connect(peerAddress).timeout(const Duration(seconds: 8));
        connected = true;
      }
    } catch (_) {}
  }
  if (!connected && !presence.isOnline(userId)) {
    BlousabToast.show(context, 'الصديق غير متاح الآن. تأكد أنه قريب وبلوساب مفتوح.');
    return;
  }
  final ids = <String>[myId, userId]..sort();
  final conversationId = 'dm_${ids[0]}_${ids[1]}';
  await _saveDirectChat(conversationId, displayName, userId, peerAddress: connected ? peerAddress ?? '' : '');
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(
        conversationId: conversationId,
        title: displayName,
        currentUserId: myId,
        currentUserName: myName,
        initialPeerAddress: connected ? peerAddress : null,
        connectionAlreadyEstablished: connected,
      )));
}

Future<void> _saveDirectChat(String conversationId, String peerName, String peerId, {String peerAddress = ''}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList('blousab_direct_chats_v1') ?? <String>[];
    entries.removeWhere((raw) {
      try { final m = jsonDecode(raw); return m is Map && m['conversationId']?.toString() == conversationId; }
      catch (_) { return false; }
    });
    entries.insert(0, jsonEncode({'conversationId': conversationId, 'peerName': peerName, 'peerAddress': peerAddress, 'peerId': peerId}));
    await prefs.setStringList('blousab_direct_chats_v1', entries.take(100).toList());
  } catch (_) {}
}

/// يلفّ أي صورة أو اسم ليصبح قابلاً للضغط ويفتح ملف صاحبه.
class BlousabUserTap extends StatelessWidget {
  const BlousabUserTap({super.key, required this.userId, required this.name, required this.child});
  final String userId;
  final String name;
  final Widget child;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => blousabOpenUserProfile(context, userId: userId, name: name),
        child: child,
      );
}

/// صورة مستخدم: صورته الحقيقية إن عُرفت (حسابي أو ما وصل من الآخرين) وإلا حرف اسمه.
class BlousabUserAvatar extends StatelessWidget {
  const BlousabUserAvatar({super.key, required this.userId, required this.name, this.size = 40, this.ownPhotoPath = '', this.tappable = true});
  final String userId;
  final String name;
  final double size;
  final String ownPhotoPath;
  final bool tappable;
  @override
  Widget build(BuildContext context) {
    final presence = BlousabPresence.instance;
    return ValueListenableBuilder<int>(
      valueListenable: presence.version,
      builder: (context, _, __) {
        final isMe = userId == presence.myId || userId.isEmpty;
        final path = isMe ? ownPhotoPath : presence.photoPathOf(userId);
        final avatar = BlousabRingAvatar(name: name, size: size, ring: 2, photoPath: path);
        return tappable && !isMe ? BlousabUserTap(userId: userId, name: name, child: avatar) : avatar;
      },
    );
  }
}

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, required this.userId, this.fallbackName = ''});
  final String userId;
  final String fallbackName;
  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  List<Map<String, dynamic>> _posts = [];
  bool _isFriend = false;
  int _followersCount = 0;
  int _followingCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
    BlousabPresence.instance.version.addListener(_refresh);
  }

  @override
  void dispose() {
    BlousabPresence.instance.version.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() { if (mounted) setState(() {}); }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final friends = await QrFriendStore.loadFriends();
    final me = prefs.getString('wasl_user_id') ?? '';
    final isFriend = friends.contains(widget.userId);
    final followers = prefs.getStringList('blousab_followers_${widget.userId}') ?? <String>[];
    final following = prefs.getStringList('blousab_following_${widget.userId}') ?? <String>[];
    final out = <Map<String, dynamic>>[];
    for (final raw in prefs.getStringList('blousab_public_feed_v1') ?? const <String>[]) {
      try {
        final m = jsonDecode(raw);
        if (m is! Map || m['authorId']?.toString() != widget.userId) continue;
        final post = Map<String, dynamic>.from(m);
        // الرؤية حسب صلاحيات صاحب المنشور: الأصدقاء فقط، أو الجميع ما عدا مستثنين.
        if ((post['visibility']?.toString() ?? 'everyone') == 'friends' && !isFriend) continue;
        if (List<String>.from(post['exceptIds'] as List? ?? const []).contains(me)) continue;
        out.add(post);
      } catch (_) {}
    }
    out.sort((a, b) => ((b['createdAt'] as num?) ?? 0).compareTo((a['createdAt'] as num?) ?? 0));
    if (mounted) setState(() {
      _posts = out;
      _isFriend = isFriend;
      _followersCount = followers.toSet().length;
      _followingCount = following.toSet().length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final presence = BlousabPresence.instance;
    final profile = presence.profileOf(widget.userId);
    final name = presence.nameOf(widget.userId, widget.fallbackName.isEmpty ? 'مستخدم بلوساب' : widget.fallbackName);
    final tag1 = profile?.tag1 ?? '';
    final tag2 = profile?.tag2 ?? '';
    return BlousabPage(
      title: 'الملف الشخصي',
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 6, 14, 24), children: [
        Center(child: BlousabRingAvatar(name: name, size: 104, ring: 4, photoPath: presence.photoPathOf(widget.userId))),
        const SizedBox(height: 10),
        Center(child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800))),
        Center(child: BlousabPresenceText(userId: widget.userId, fontSize: 13)),
        const SizedBox(height: 8),
        if (tag1.trim().isNotEmpty) Center(child: Text(tag1, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w600))),
        if (tag2.trim().isNotEmpty) Center(child: Text(tag2, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFD5DEFF), fontSize: 14))),
        const SizedBox(height: 14),
        Row(children: [
          _stat('المنشورات', _posts.length),
          _stat('المتابعون', _followersCount, onTap: () => _openConnections('followers')),
          _stat('المتابَعون', _followingCount, onTap: () => _openConnections('following')),
        ]),
        const SizedBox(height: 12),
        if (!_isFriend) ...[
          BlousabPrimaryButton(
            label: 'إرسال طلب صداقة',
            icon: Icons.person_add_alt_1_rounded,
            onTap: () => _sendFriendRequest(name),
          ),
          const SizedBox(height: 8),
        ],
        BlousabPrimaryButton(
          label: 'مراسلة',
          icon: Icons.chat_bubble_outline_rounded,
          onTap: () async {
            await blousabMessageUser(context, userId: widget.userId, name: name);
            await _load();
          },
        ),
        const SizedBox(height: 14),
        const BlousabSectionLabel('المنشورات'),
        if (_posts.isEmpty)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('لا توجد منشورات متزامنة بعد.', style: TextStyle(color: Color(0xFFC6D0F2)))))
        else
          ..._posts.map(_postCard),
      ]),
    );
  }

  Future<void> _sendFriendRequest(String name) async {
    final me = await _me();
    final ok = await FriendRequests.send(myId: me['id'] ?? '', myName: me['name'] ?? 'مستخدم بلوساب', recipientId: widget.userId);
    if (!mounted) return;
    BlousabToast.show(context, ok ? 'أُرسل طلب الصداقة إلى $name.' : 'تعذر إرسال الطلب الآن. تأكد من تشغيل البلوتوث وWi-Fi.');
  }

  Future<void> _openConnections(String kind) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProfileConnectionsScreen(userId: widget.userId, kind: kind)));
  }

  Widget _stat(String label, int value, {VoidCallback? onTap}) => Expanded(
        child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            Text('$value', style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
            Text(label, style: const TextStyle(color: Color(0xFFA9B8E8), fontSize: 13)),
          ]))),
      );

  Widget _postCard(Map<String, dynamic> post) {
    final text = post['text']?.toString() ?? '';
    final type = post['mediaType']?.toString() ?? 'text';
    final path = post['mediaPath']?.toString() ?? '';
    final hasImage = type == 'image' && path.isNotEmpty && File(path).existsSync();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: blousabCardDecoration(radius: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (hasImage)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BlousabKeepColors(child: Image.file(File(path), fit: BoxFit.cover, width: double.infinity, height: 200)),
          )
        else if (type == 'video')
          const SizedBox(height: 60, child: Center(child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 44))),
        if (text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 15.5))),
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.favorite_rounded, color: Color(0xFFFF4D6D), size: 16),
          const SizedBox(width: 4),
          Text(post['hideLikes'] == true ? '•' : '${(post['likes'] as List?)?.length ?? 0}', style: const TextStyle(color: Color(0xFFC6D0F2), fontSize: 13)),
          const SizedBox(width: 14),
          const Icon(Icons.mode_comment_outlined, color: Color(0xFFC6D0F2), size: 16),
          const SizedBox(width: 4),
          Text('${(post['comments'] as List?)?.length ?? 0}', style: const TextStyle(color: Color(0xFFC6D0F2), fontSize: 13)),
        ]),
      ]),
    );
  }
}


class ProfileConnectionsScreen extends StatefulWidget {
  const ProfileConnectionsScreen({super.key, required this.userId, required this.kind});
  final String userId;
  final String kind;
  @override
  State<ProfileConnectionsScreen> createState() => _ProfileConnectionsScreenState();
}

class _ProfileConnectionsScreenState extends State<ProfileConnectionsScreen> {
  List<String> _ids = const [];
  bool _loading = true;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final key = widget.kind == 'followers' ? 'blousab_followers_${widget.userId}' : 'blousab_following_${widget.userId}';
    final ids = (prefs.getStringList(key) ?? <String>[]).where((id) => id.isNotEmpty && id != widget.userId).toSet().toList();
    if (mounted) setState(() { _ids = ids; _loading = false; });
  }
  @override
  Widget build(BuildContext context) {
    final title = widget.kind == 'followers' ? 'المتابعون' : 'المتابَعون';
    final presence = BlousabPresence.instance;
    return BlousabPage(title: title, child: _loading ? const Center(child: CircularProgressIndicator()) : _ids.isEmpty
      ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('لا توجد قائمة متابعة متزامنة لهذا الحساب بعد.', textAlign: TextAlign.center)))
      : ListView.builder(itemCount: _ids.length, itemBuilder: (_, i) {
          final id = _ids[i]; final name = presence.nameOf(id, 'مستخدم بلوساب');
          return ListTile(leading: BlousabUserAvatar(userId: id, name: name, size: 44, tappable: false), title: Text(name),
            subtitle: BlousabPresenceText(userId: id, fontSize: 12), onTap: () => blousabOpenUserProfile(context, userId: id, name: name));
        }));
  }
}
