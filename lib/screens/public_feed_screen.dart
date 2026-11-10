import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../services/local_network_service.dart';
import '../services/qr_friend_store.dart';
import '../services/presence_service.dart';
import 'user_profile_screen.dart';
import 'post_interactions_screen.dart';
import '../widgets/blousab_time.dart';
import '../services/wifi_aware_service.dart';
import '../services/notification_service.dart';
import '../services/bluetooth_classic_service.dart';
import '../widgets/blousab_visuals.dart';
import 'chat_screen.dart';
import 'media_editor.dart';
import 'stories_strip.dart';

/// Nearby public feed. Media is compressed and chunked; delivery uses direct
/// Wi-Fi Aware data paths when supported, with LAN as a compatible fallback.
/// يُزاد عند الضغط على «المنشورات» من الملف الشخصي ليعرض المنشورات الرئيسية (الكل).
final ValueNotifier<int> blousabFeedShowAllRequest = ValueNotifier<int>(0);

class PublicFeedScreen extends StatefulWidget {
  final String userName;
  final String profilePhotoPath;
  const PublicFeedScreen({super.key, required this.userName, required this.profilePhotoPath});

  @override
  State<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

class _PublicFeedScreenState extends State<PublicFeedScreen> {
  static const _key = 'blousab_public_feed_v1';
  static const _friendsKey = 'blousab_accepted_friends_v1';
  static const _requestsKey = 'blousab_friend_requests_v1';
  final _picker = ImagePicker();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _posts = [];
  StreamSubscription? _subscription;
  StreamSubscription? _awareSubscription;
  Timer? _feedSyncTimer;
  bool _busy = false;
  bool _loading = true;
  bool _loaded = false;
  final List<dynamic> _pendingFeedEvents = <dynamic>[];
  String? _loadError;
  bool _randomOrder = false;
  int _shuffleSeed = DateTime.now().millisecondsSinceEpoch;
  String _myId = 'blousab-user';
  Set<String> _friends = <String>{};
  List<Map<String, dynamic>> _friendRequests = <Map<String, dynamic>>[];
  final Map<String, _IncomingFeedMedia> _incomingMedia = <String, _IncomingFeedMedia>{};
  static const int _mediaChunkBytes = 256 * 1024;
  static const int _maxPostMediaBytes = 32 * 1024 * 1024;

  void _showAllRequested() {
    if (mounted) {
      setState(() => _filter = 0);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void initState() {
    super.initState();
    blousabFeedShowAllRequest.addListener(_showAllRequested);
    QrFriendStore.changes.addListener(_reloadFriendsFromStore);
    _loadShared();
    _load().then((_) async {
      _loaded = true;
      final pending = List<dynamic>.from(_pendingFeedEvents);
      _pendingFeedEvents.clear();
      for (final event in pending) { await _onLanEvent(event); }
      await _requestFeedSync();
    }).catchError((_) { if (mounted) setState(() { _loading = false; _loadError = 'تعذر تحميل الخلاصة المحفوظة.'; }); });
    _subscription = LocalNetworkService.instance.events.listen(_onLanEvent);
    _awareSubscription = WifiAwareService.instance.events.listen((event) {
      if (event.type == 'dataConnected') {
        _requestFeedSync();
      } else if (event.type == 'dataPacket' && event.payload != null) {
        _onLanEvent(BlousabEvent(type: 'message', message: event.payload));
      }
    });
    // Periodic lightweight reconciliation catches missed broadcasts and
    // retries media that was incomplete during a temporary disconnect.
    _feedSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (LocalNetworkService.instance.isRunning || WifiAwareService.instance.connectedPeerIds.isNotEmpty) { _requestFeedSync(); _flushSharePending(); }
    });
  }

  @override
  void dispose() { blousabFeedShowAllRequest.removeListener(_showAllRequested); QrFriendStore.changes.removeListener(_reloadFriendsFromStore); _feedSyncTimer?.cancel(); _reelController.dispose(); _subscription?.cancel(); _awareSubscription?.cancel(); _incomingMedia.clear(); _pendingFeedEvents.clear(); _scroll.dispose(); super.dispose(); }

  Future<Directory> _feedDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/blousab_public_feed');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _myId = prefs.getString('wasl_user_id') ?? '';
    if (_myId.trim().isEmpty || _myId == 'blousab-user') {
      _myId = 'blousab-${DateTime.now().microsecondsSinceEpoch}-${DateTime.now().millisecondsSinceEpoch.remainder(100000)}';
      await prefs.setString('wasl_user_id', _myId);
    }
    _friends = (prefs.getStringList(_friendsKey) ?? <String>[]).toSet();
    _friendRequests = (prefs.getStringList(_requestsKey) ?? <String>[])
        .map((item) { try { return Map<String, dynamic>.from(jsonDecode(item) as Map); } catch (_) { return <String, dynamic>{}; } })
        .where((item) => item.isNotEmpty).toList();
    final raw = prefs.getStringList(_key) ?? <String>[];
    final byId = <String, Map<String, dynamic>>{};
    for (final item in raw) {
      try {
        final post = Map<String, dynamic>.from(jsonDecode(item) as Map);
        final id = post['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        // One canonical entry per post ID; retain the newest copy if storage
        // contains a replayed duplicate.
        final existing = byId[id];
        final incomingUpdated = (post['updatedAt'] as num?)?.toInt() ?? (post['createdAt'] as num?)?.toInt() ?? 0;
        final existingUpdated = (existing?['updatedAt'] as num?)?.toInt() ?? (existing?['createdAt'] as num?)?.toInt() ?? 0;
        if (existing == null || incomingUpdated >= existingUpdated) byId[id] = post;
      } catch (_) {}
    }
    final posts = byId.values.toList();
    _sortPosts(posts);
    if (mounted) setState(() { _posts = posts; _loading = false; _loadError = null; });
  }

  void _sortPosts(List<Map<String, dynamic>> posts) {
    if (_randomOrder) {
      // Stable shuffle for the current view; tapping shuffle changes the seed.
      posts.sort((a, b) => _shuffleKey(a['id']?.toString() ?? '').compareTo(_shuffleKey(b['id']?.toString() ?? '')));
    } else {
      posts.sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
    }
  }

  int _shuffleKey(String id) {
    var hash = _shuffleSeed;
    for (final unit in id.codeUnits) { hash = ((hash * 31) ^ unit) & 0x7fffffff; }
    return hash;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    // Persist canonical unique posts in chronological order, independent of
    // the currently selected display ordering.
    final unique = <String, Map<String, dynamic>>{};
    for (final post in _posts) {
      final id = post['id']?.toString() ?? '';
      if (id.isNotEmpty) unique[id] = post;
    }
    final stored = unique.values.toList()..sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
    await prefs.setStringList(_key, stored.map(jsonEncode).toList());
  }

  Future<void> _refreshFeed() async {
    if (mounted) setState(() { _loading = true; _loadError = null; });
    try {
      await _load();
      await _requestFeedSync();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _loadError = 'تعذر تحديث الخلاصة. حاول مرة أخرى.'; });
    }
  }

  void _toggleOrder() {
    setState(() {
      _randomOrder = !_randomOrder;
      _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
      _sortPosts(_posts);
    });
  }

  bool get _hasFeedTransport => LocalNetworkService.instance.isRunning || WifiAwareService.instance.connectedPeerIds.isNotEmpty;

  Future<void> _broadcastFeedPacket(String payload) async {
    var sent = false;
    Object? lastError;
    final lanPeerIds = LocalNetworkService.instance.discoveredPeers
        .map((peer) => peer['id'] ?? '').where((id) => id.isNotEmpty).toSet();
    if (LocalNetworkService.instance.isRunning) {
      try { await LocalNetworkService.instance.broadcastMessage(payload); sent = true; }
      catch (error) { lastError = error; }
    }
    try { await WifiAwareService.instance.broadcastPacket(payload, excludePeerIds: lanPeerIds); sent = true; }
    catch (error) { lastError = error; }
    if (!sent) throw StateError('لا يوجد مسار مباشر متاح لإرسال المنشور: $lastError');
  }

  Future<void> _broadcastFeedFrames(Iterable<String> frames) async {
    var sent = false;
    Object? lastError;
    final lanPeerIds = LocalNetworkService.instance.discoveredPeers
        .map((peer) => peer['id'] ?? '').where((id) => id.isNotEmpty).toSet();
    if (LocalNetworkService.instance.isRunning) {
      try { await LocalNetworkService.instance.broadcastMessages(frames); sent = true; }
      catch (error) { lastError = error; }
    }
    try { await WifiAwareService.instance.broadcastPackets(frames, excludePeerIds: lanPeerIds); sent = true; }
    catch (error) { lastError = error; }
    if (!sent) throw StateError('تعذر نقل وسائط المنشور عبر أي اتصال مباشر: $lastError');
  }

  Future<void> _requestFeedSync() async {
    try {
      if (!_hasFeedTransport) return;
      final knownPosts = _posts.take(1000).map((post) {
        final path = post['mediaPath']?.toString() ?? '';
        final hasMedia = path.isNotEmpty && File(path).existsSync();
        return <String, dynamic>{
          'id': post['id']?.toString() ?? '',
          'updatedAt': (post['updatedAt'] as num?)?.toInt() ?? 0,
          'hasMedia': hasMedia,
        };
      }).where((item) => (item['id'] as String).isNotEmpty).toList();
      await _broadcastFeedPacket(jsonEncode({
        'type': 'public_feed_sync_request', 'requesterId': _myId,
        'knownPosts': knownPosts,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  Future<void> _broadcastPost(Map<String, dynamic> post, {int hops = 0}) async {
    if (!_hasFeedTransport) return;
    final outgoing = Map<String, dynamic>.from(post);
    outgoing.remove('mediaPath');
    outgoing.remove('profilePhotoPath');
    final profilePath = post['profilePhotoPath']?.toString().isNotEmpty == true
        ? post['profilePhotoPath'].toString()
        : (post['authorId']?.toString() == _myId ? widget.profilePhotoPath : '');
    if (profilePath.isNotEmpty) {
      try {
        final file = File(profilePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty && bytes.length <= 80 * 1024) {
            outgoing['profilePhotoBase64'] = base64Encode(bytes);
          }
        }
      } catch (_) {}
    }

    final mediaPath = post['mediaPath']?.toString() ?? '';
    if (mediaPath.isEmpty || post['mediaType'] == 'text') {
      await _broadcastFeedPacket(jsonEncode({
        'type': 'public_feed_post', 'post': outgoing, 'hops': hops,
      }));
      return;
    }

    final mediaFile = File(mediaPath);
    if (!await mediaFile.exists()) throw StateError('ملف وسائط المنشور غير موجود');
    final source = await mediaFile.readAsBytes();
    if (source.isEmpty || source.length > _maxPostMediaBytes) {
      throw StateError('حجم الوسائط يتجاوز الحد المسموح لمزامنة المنشورات (32 ميجابايت)');
    }

    // لا نعيد ضغط MP4/JPEG إذا كانت نتيجة GZIP أكبر؛ الضغط اختياري تلقائيًا.
    final zipped = gzip.encode(source);
    final useGzip = zipped.length < source.length;
    final transferBytes = useGzip ? zipped : source;
    final transferId = '${post['id']}_${DateTime.now().microsecondsSinceEpoch}';
    final chunkCount = (transferBytes.length / _mediaChunkBytes).ceil();
    await _broadcastFeedFrames(_feedMediaFrames(
      transferId: transferId, post: outgoing, hops: hops,
      originalBytes: source.length, compressed: transferBytes, chunkCount: chunkCount,
      useGzip: useGzip, sha256Hex: sha256.convert(source).toString(),
    ));
  }

  Iterable<String> _feedMediaFrames({required String transferId,
      required Map<String, dynamic> post, required int hops,
      required int originalBytes, required List<int> compressed,
      required int chunkCount, required bool useGzip, required String sha256Hex}) sync* {
    yield jsonEncode({
      'type': 'public_feed_media_start', 'transferId': transferId,
      'post': post, 'hops': hops,
      'originalBytes': originalBytes, 'compressedBytes': compressed.length,
      'chunkCount': chunkCount, 'gzip': useGzip, 'sha256': sha256Hex,
    });
    for (var index = 0; index < chunkCount; index++) {
      final from = index * _mediaChunkBytes;
      final to = (from + _mediaChunkBytes).clamp(0, compressed.length).toInt();
      yield jsonEncode({
        'type': 'public_feed_media_chunk', 'transferId': transferId,
        'index': index, 'data': base64Encode(compressed.sublist(from, to)),
      });
    }
    yield jsonEncode({'type': 'public_feed_media_end', 'transferId': transferId});
  }

  Future<void> _broadcastPostUpdate(Map<String, dynamic> post, {int hops = 0}) async {
    try {
      if (!_hasFeedTransport) return;
      await _broadcastFeedPacket(jsonEncode({
        'type': 'public_feed_update', 'postId': post['id'],
        'likes': post['likes'] ?? <String>[],
        'comments': post['comments'] ?? <Map<String, dynamic>>[],
        'likeLog': post['likeLog'] ?? <String, dynamic>{},
        'shareLog': post['shareLog'] ?? <Map<String, dynamic>>[],
        'shares': (post['shares'] as num?)?.toInt() ?? 0,
        'updatedAt': (post['updatedAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        'hops': hops,
      }));
    } catch (_) {}
  }

  Future<void> _persistFriends() async {
    final prefs = await SharedPreferences.getInstance();
    // دمج مع المخزَّن حتى لا تُمحى صداقات أُضيفت عبر مسح QR من شاشة أخرى.
    _friends = {...(prefs.getStringList(_friendsKey) ?? <String>[]), ..._friends};
    await prefs.setStringList(_friendsKey, _friends.toList());
    QrFriendStore.changes.value++;
  }

  Future<void> _reloadFriendsFromStore() async {
    final stored = await QrFriendStore.loadFriends();
    final requests = await FriendRequests.load();
    if (!mounted) return;
    setState(() { _friends = {..._friends, ...stored}; _friendRequests = requests; });
  }

  /// يعيد إرسال إشعارات الاتصال عبر QR التي لم يؤكدها الطرف الآخر بعد.
  Future<void> _flushQrPending([String? peerId]) async {
    try {
      for (final p in await QrFriendStore.loadPending()) {
        if (peerId != null && peerId.isNotEmpty && p['recipientId']?.toString() != peerId) continue;
        try { await _broadcastFeedPacket(jsonEncode(p)); } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _persistFriendRequests() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_requestsKey, _friendRequests.map(jsonEncode).toList());
  }

  Future<void> _acceptFriendRequest(Map<String, dynamic> request) async {
    final peerId = request['senderId']?.toString() ?? '';
    if (peerId.isEmpty || peerId == _myId) return;
    await FriendRequests.accept(request, myId: _myId, myName: widget.userName);
    _friends.add(peerId);
    _friendRequests = await FriendRequests.load();
    if (mounted) setState(() {});
    if (mounted) BlousabToast.show(context, 'تم قبول الطلب وأصبحتما صديقين.');
  }

  Future<void> _rejectFriendRequest(Map<String, dynamic> request) async {
    await FriendRequests.reject(request, myId: _myId, myName: widget.userName);
    _friendRequests = await FriendRequests.load();
    if (mounted) setState(() {});
  }

  Future<void> _showNotifications() async {
    unawaited(BlousabBadges.markRequestsSeen());
    await showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final requests = List<Map<String, dynamic>>.from(_friendRequests);
        return SafeArea(child: SizedBox(height: MediaQuery.of(ctx).size.height * .65, child: Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('الإشعارات وطلبات الصداقة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          Expanded(child: requests.isEmpty ? const Center(child: Text('لا توجد طلبات صداقة جديدة')) : ListView(children: requests.map((r) => ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1)), title: Text('طلب صداقة من ${r['senderName'] ?? 'مستخدم'}'), subtitle: Text(_time(r['createdAt'])),
            trailing: Wrap(spacing: 0, children: [IconButton(tooltip:'قبول', onPressed: () async { await _acceptFriendRequest(r); setSheet(() {}); }, icon: const Icon(Icons.check_circle_outline, color: Colors.green)), IconButton(tooltip:'رفض', onPressed: () async { await _rejectFriendRequest(r); setSheet(() {}); }, icon: const Icon(Icons.close))]),
          )).toList())),
        ])));
      }));
  }

  Future<void> _onLanEvent(dynamic event) async {
    if (!_loaded) {
      // Keep startup packets until local storage has been loaded, otherwise
      // an early peer post could be overwritten by the initial disk read.
      if (_pendingFeedEvents.length < 512) _pendingFeedEvents.add(event);
      return;
    }
    if (event.type == 'lanStarted' || event.type == 'peerDiscovered') {
      // A newly reachable peer automatically triggers reconciliation. No
      // manual refresh or device selection is required for the public feed.
      await _requestFeedSync();
      await _flushQrPending(event.type == 'peerDiscovered' ? event.message?.toString() : null);
      await _flushSharePending(event.type == 'peerDiscovered' ? event.message?.toString() : null);
      return;
    }
    if (event.type != 'message' || event.message == null) return;
    try {
      final packet = jsonDecode(event.message!);
      if (packet is! Map) return;
      final packetType = packet['type']?.toString();

      if (packetType == 'public_feed_media_start') {
        final id = packet['transferId']?.toString() ?? '';
        final postRaw = packet['post'];
        final chunks = (packet['chunkCount'] as num?)?.toInt() ?? 0;
        final compressedBytes = (packet['compressedBytes'] as num?)?.toInt() ?? -1;
        final originalBytes = (packet['originalBytes'] as num?)?.toInt() ?? -1;
        if (id.isEmpty || postRaw is! Map || chunks < 1 || chunks > 160 ||
            compressedBytes < 1 || compressedBytes > _maxPostMediaBytes + 256 * 1024 ||
            originalBytes < 1 || originalBytes > _maxPostMediaBytes) return;
        _incomingMedia.removeWhere((_, value) => DateTime.now().difference(value.createdAt) > const Duration(minutes: 3));
        int pendingBytes() => _incomingMedia.values.fold<int>(0, (sum, item) => sum + item.compressedBytes);
        while (!_incomingMedia.containsKey(id) && _incomingMedia.isNotEmpty &&
            (_incomingMedia.length >= 2 || pendingBytes() + compressedBytes > 40 * 1024 * 1024)) {
          final oldest = _incomingMedia.entries.reduce((a, b) =>
              a.value.createdAt.isBefore(b.value.createdAt) ? a : b).key;
          _incomingMedia.remove(oldest);
        }
        _incomingMedia[id] = _IncomingFeedMedia(
          post: Map<String, dynamic>.from(postRaw), chunkCount: chunks,
          compressedBytes: compressedBytes, originalBytes: originalBytes,
          hops: (packet['hops'] as num?)?.toInt() ?? 0,
          useGzip: packet['gzip'] == true, sha256Hex: packet['sha256']?.toString() ?? '',
        );
        return;
      }
      if (packetType == 'public_feed_media_chunk') {
        final id = packet['transferId']?.toString() ?? '';
        final transfer = _incomingMedia[id];
        final index = (packet['index'] as num?)?.toInt() ?? -1;
        final encoded = packet['data']?.toString() ?? '';
        if (transfer == null || index < 0 || index >= transfer.chunkCount || encoded.isEmpty || encoded.length > 400 * 1024) return;
        if (!transfer.chunks.containsKey(index)) {
          final bytes = base64Decode(encoded);
          transfer.receivedBytes += bytes.length;
          if (transfer.receivedBytes > transfer.compressedBytes) {
            _incomingMedia.remove(id);
            return;
          }
          transfer.chunks[index] = bytes;
        }
        return;
      }
      if (packetType == 'public_feed_media_end') {
        final id = packet['transferId']?.toString() ?? '';
        final transfer = _incomingMedia.remove(id);
        if (transfer != null) await _completeIncomingMedia(transfer);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      _myId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      if (packetType == 'post_share' && packet['recipientId']?.toString() == _myId) {
        // منشور شاركه لي صديق: يبقى باسم صاحبه الأصلي وهويته.
        final postId = packet['postId']?.toString() ?? '';
        final sharerId = packet['sharerId']?.toString() ?? '';
        if (postId.isEmpty || sharerId.isEmpty || sharerId == _myId) return;
        final isNew = !_shared.containsKey(postId);
        _shared[postId] = {
          'byId': sharerId,
          'byName': packet['sharerName']?.toString() ?? 'مستخدم بلوساب',
          'authorId': packet['authorId']?.toString() ?? '',
          'authorName': packet['authorName']?.toString() ?? '',
          'at': packet['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
        };
        await _saveShared();
        if (isNew) await _addShareNotification(packet['sharerName']?.toString() ?? 'مستخدم بلوساب', packet['shareId']?.toString() ?? postId);
        try { await _broadcastFeedPacket(jsonEncode({'type': 'post_share_ack', 'recipientId': sharerId, 'senderId': _myId, 'shareId': packet['shareId']})); } catch (_) {}
        if (mounted) {
          setState(() {});
          if (isNew) BlousabToast.show(context, '${packet['sharerName'] ?? 'مستخدم'} شاركك منشوراً.');
        }
        return;
      }
      if (packetType == 'post_share_ack' && packet['recipientId']?.toString() == _myId) {
        final shareId = packet['shareId']?.toString() ?? '';
        final pending = await _loadSharePending();
        pending.removeWhere((p) => p['shareId']?.toString() == shareId);
        await _saveSharePending(pending);
        return;
      }
      if (packetType == 'friend_qr_connect' && packet['recipientId']?.toString() == _myId) {
        // اتصال مباشر عبر مسح رمز QR: يُحتسب صديقاً فوراً دون طلب صداقة.
        final senderId = packet['senderId']?.toString() ?? '';
        if (senderId.isEmpty || senderId == _myId) return;
        if (!await QrFriendStore.isTokenValid(packet['token']?.toString())) return;
        final isNew = !_friends.contains(senderId);
        _friends.add(senderId);
        _friendRequests.removeWhere((r) => r['senderId']?.toString() == senderId);
        await _persistFriends(); await _persistFriendRequests();
        try {
          await _broadcastFeedPacket(jsonEncode({'type':'friend_qr_ack','recipientId':senderId,'senderId':_myId}));
        } catch (_) {}
        if (mounted) {
          setState(() {});
          if (isNew) BlousabToast.show(context, '${packet['senderName'] ?? 'مستخدم'} اتصل بك مباشرة عبر QR وأصبح صديقاً لك.');
        }
        return;
      }
      if (packetType == 'friend_qr_ack' && packet['recipientId']?.toString() == _myId) {
        final peerId = packet['senderId']?.toString() ?? '';
        if (peerId.isNotEmpty) await QrFriendStore.removePending(peerId);
        return;
      }
      if (packetType == 'friend_request' && packet['recipientId']?.toString() == _myId) {
        final senderId = packet['senderId']?.toString() ?? '';
        if (senderId.isEmpty || senderId == _myId || _friends.contains(senderId)) return;
        final requestId = packet['requestId']?.toString() ?? '${senderId}_${packet['createdAt']}';
        if (!_friendRequests.any((r) => r['senderId']?.toString() == senderId)) {
          await FriendRequests.add({'requestId':requestId,'senderId':senderId,'senderName':packet['senderName']?.toString() ?? 'مستخدم','createdAt':packet['createdAt'] ?? DateTime.now().millisecondsSinceEpoch});
          _friendRequests = await FriendRequests.load(); if (mounted) setState(() {});
        }
        return;
      }
      if (packetType == 'friend_request_response' && packet['recipientId']?.toString() == _myId) {
        final peerId = packet['senderId']?.toString() ?? '';
        if (peerId.isNotEmpty && peerId != _myId && packet['accepted'] == true) {
          _friends.add(peerId); await _persistFriends();
          if (mounted) { setState(() {}); BlousabToast.show(context, 'وافق ${packet['senderName'] ?? 'المستخدم'} على طلب الصداقة. تم حفظ الصداقة.'); }
        } else if (mounted && peerId.isNotEmpty) { BlousabToast.show(context, 'تم رفض طلب الصداقة.'); }
        return;
      }
      if (packetType == 'public_feed_sync_request') {
        final known = <String, Map<String, dynamic>>{};
        for (final item in (packet['knownPosts'] as List? ?? const [])) {
          if (item is! Map) continue;
          final id = item['id']?.toString() ?? '';
          if (id.isNotEmpty) known[id] = Map<String, dynamic>.from(item);
        }
        for (final savedPost in List<Map<String, dynamic>>.from(_posts)) {
          final id = savedPost['id']?.toString() ?? '';
          final remote = known[id];
          final localUpdated = (savedPost['updatedAt'] as num?)?.toInt() ?? 0;
          final remoteUpdated = (remote?['updatedAt'] as num?)?.toInt() ?? -1;
          final mediaPath = savedPost['mediaPath']?.toString() ?? '';
          final senderHasMedia = savedPost['mediaType'] != 'text' &&
              mediaPath.isNotEmpty && File(mediaPath).existsSync();
          final receiverHasMedia = remote?['hasMedia'] == true;
          final mediaAlreadyThere = !senderHasMedia || receiverHasMedia;
          if (remote != null && remoteUpdated >= localUpdated && mediaAlreadyThere) continue;
          try { await _broadcastPost(savedPost); } catch (_) {}
        }
        return;
      }
      if (packetType == 'public_feed_update') {
        final postId = packet['postId']?.toString() ?? '';
        final index = _posts.indexWhere((p) => p['id']?.toString() == postId);
        if (index < 0) return;
        final updated = Map<String, dynamic>.from(_posts[index]);
        final oldLikes = List<String>.from(updated['likes'] as List? ?? const []);
        final incomingLikes = List<String>.from(packet['likes'] as List? ?? const []);
        final oldComments = List<Map<String, dynamic>>.from((updated['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        final incomingComments = List<Map<String, dynamic>>.from((packet['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        if (updated['authorId']?.toString() == _myId) {
          for (final likerId in incomingLikes.where((id) => !oldLikes.contains(id) && id != _myId)) {
            final likerName = BlousabPresence.instance.nameOf(likerId, 'مستخدم');
            await NotificationService.instance.showActivityNotification(id: 'like_${postId}_$likerId', senderName: likerName, title: 'إعجاب جديد', body: '$likerName أعجب بمنشورك.');
          }
          final oldCommentIds = oldComments.map((c) => c['id']?.toString() ?? '').toSet();
          for (final comment in incomingComments.where((c) => !oldCommentIds.contains(c['id']?.toString() ?? '') && c['userId']?.toString() != _myId)) {
            final commenterId = comment['userId']?.toString() ?? '';
            final commenterName = comment['name']?.toString() ?? BlousabPresence.instance.nameOf(commenterId, 'مستخدم');
            await NotificationService.instance.showActivityNotification(id: 'comment_${comment['id'] ?? '${postId}_$commenterId'}', senderName: commenterName, title: 'تعليق جديد', body: '$commenterName علّق على منشورك.');
          }
        }
        final packetUpdatedAt = (packet['updatedAt'] as num?)?.toInt() ?? 0;
        final currentUpdatedAt = (updated['updatedAt'] as num?)?.toInt() ?? 0;
        if (packetUpdatedAt <= currentUpdatedAt) return;
        updated['likes'] = List<String>.from(packet['likes'] as List? ?? const []);
        updated['comments'] = List<Map<String, dynamic>>.from(
          (packet['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        final inLog = Map<String, dynamic>.from(packet['likeLog'] as Map? ?? const {});
        final curLog = _likeLogOf(_posts[index]);
        updated['likeLog'] = {for (final id in List<String>.from(updated['likes'] as List)) id: inLog[id] ?? curLog[id] ?? {'at': 0}};
        updated['shareLog'] = _mergeShareLog(_shareLogOf(_posts[index]), (packet['shareLog'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
        final inShares = (packet['shares'] as num?)?.toInt() ?? 0;
        final curShares = (updated['shares'] as num?)?.toInt() ?? 0;
        updated['shares'] = inShares > curShares ? inShares : curShares;
        updated['updatedAt'] = packetUpdatedAt;
        if (mounted) setState(() { _posts[index] = updated; _sortPosts(_posts); });
        await _save();
        final hops = (packet['hops'] as num?)?.toInt() ?? 0;
        await _broadcastPostUpdate(updated, hops: hops + 1);
        return;
      }
      if (packetType != 'public_feed_post') return;
      final post = Map<String, dynamic>.from(packet['post'] as Map);
      final hops = (packet['hops'] as num?)?.toInt() ?? 0;
      if (post['authorId']?.toString() != _myId && List<String>.from(post['exceptIds'] as List? ?? const []).contains(_myId)) return;
      if (post['mediaBase64'] != null) {
        try {
          final bytes = base64Decode(post['mediaBase64'].toString());
          if (bytes.length > _maxPostMediaBytes) return;
          final dir = await _feedDir();
          final ext = post['mediaType'] == 'video' ? 'mp4' : 'jpg';
          final safeId = (post['id']?.toString() ?? 'post').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final file = File('${dir.path}/received_$safeId.$ext');
          await file.writeAsBytes(bytes, flush: true);
          post['mediaPath'] = file.path;
        } catch (_) { return; }
        post.remove('mediaBase64');
      }
      await _mergeIncomingPost(post, hops: hops);
    } catch (_) { /* Ignore malformed, incomplete, or oversized peer packets. */ }
  }

  Future<void> _completeIncomingMedia(_IncomingFeedMedia transfer) async {
    try {
      if (transfer.chunks.length != transfer.chunkCount ||
          transfer.receivedBytes != transfer.compressedBytes) return;
      final compressed = BytesBuilder(copy: false);
      for (var i = 0; i < transfer.chunkCount; i++) {
        final chunk = transfer.chunks[i];
        if (chunk == null) return;
        compressed.add(chunk);
      }
      final transferred = compressed.takeBytes();
      final media = transfer.useGzip ? gzip.decode(transferred) : transferred;
      if (media.length != transfer.originalBytes || media.length > _maxPostMediaBytes) return;
      if (transfer.sha256Hex.isNotEmpty && sha256.convert(media).toString() != transfer.sha256Hex) return;
      final post = transfer.post;
      final dir = await _feedDir();
      final ext = post['mediaType'] == 'video' ? 'mp4' : 'jpg';
      final safeId = (post['id']?.toString() ?? 'post').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final file = File('${dir.path}/received_$safeId.$ext');
      await file.writeAsBytes(media, flush: true);
      post['mediaPath'] = file.path;
      post.remove('mediaBase64');
      await _mergeIncomingPost(post, hops: transfer.hops);
    } catch (_) {
      // A truncated/corrupt transfer is discarded; the next peer reconciliation retries it.
    }
  }

  Future<void> _mergeIncomingPost(Map<String, dynamic> post, {int hops = 0}) async {
    if (post['authorId']?.toString() == _myId) return;
    final profileData = post['profilePhotoBase64']?.toString();
    if (profileData != null && profileData.isNotEmpty) {
      try {
        final bytes = base64Decode(profileData);
        if (bytes.length <= 80 * 1024) {
          final dir = await _feedDir();
          final safeAuthor = (post['authorId']?.toString() ?? 'user').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final photoFile = File('${dir.path}/profile_$safeAuthor.jpg');
          await photoFile.writeAsBytes(bytes, flush: true);
          post['profilePhotoPath'] = photoFile.path;
        }
      } catch (_) {}
      post.remove('profilePhotoBase64');
    }

    final duplicateIndex = _posts.indexWhere((p) => p['id']?.toString() == post['id']?.toString());
    if (duplicateIndex >= 0) {
      final current = _posts[duplicateIndex];
      final incomingUpdated = (post['updatedAt'] as num?)?.toInt() ?? (post['createdAt'] as num?)?.toInt() ?? 0;
      final currentUpdated = (current['updatedAt'] as num?)?.toInt() ?? (current['createdAt'] as num?)?.toInt() ?? 0;
      final currentMediaPath = current['mediaPath']?.toString() ?? '';
      final incomingMediaPath = post['mediaPath']?.toString() ?? '';
      final currentHasMedia = current['mediaType'] == 'text' ||
          (currentMediaPath.isNotEmpty && File(currentMediaPath).existsSync());
      final hasMissingMedia = !currentHasMedia && incomingMediaPath.isNotEmpty &&
          File(incomingMediaPath).existsSync();
      if (incomingUpdated <= currentUpdated && !hasMissingMedia) return;
      final merged = Map<String, dynamic>.from(current);
      if (incomingUpdated > currentUpdated) {
        merged['likes'] = List<String>.from(post['likes'] as List? ?? const []);
        merged['comments'] = List<Map<String, dynamic>>.from((post['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        final inLog2 = Map<String, dynamic>.from(post['likeLog'] as Map? ?? const {});
        final curLog2 = _likeLogOf(current);
        merged['likeLog'] = {for (final id in List<String>.from(merged['likes'] as List)) id: inLog2[id] ?? curLog2[id] ?? {'at': 0}};
        merged['shareLog'] = _mergeShareLog(_shareLogOf(current), _shareLogOf(post));
        final inSh = (post['shares'] as num?)?.toInt() ?? 0;
        final curSh = (merged['shares'] as num?)?.toInt() ?? 0;
        merged['shares'] = inSh > curSh ? inSh : curSh;
        merged['updatedAt'] = incomingUpdated;
      }
      if (hasMissingMedia) merged['mediaPath'] = post['mediaPath'];
      if (mounted) setState(() { _posts[duplicateIndex] = merged; _sortPosts(_posts); });
      await _save();
      if (incomingUpdated > currentUpdated) {
        await _broadcastPostUpdate(merged, hops: hops + 1);
      } else if (hasMissingMedia) {
        try { await _broadcastPost(merged, hops: hops + 1); } catch (_) {}
      }
      return;
    }
    if (post['mediaPath'] == null && post['mediaType'] != 'text') return;
    if (!mounted) return;
    setState(() { _posts.add(post); _sortPosts(_posts); });
    await _save();
    try { await _broadcastPost(post, hops: hops + 1); } catch (_) {}
  }

  /// خيارات الخصوصية قبل النشر. «تخطي» ينشر بالإعدادات الافتراضية للتطبيق. null = إلغاء النشر.
  Future<Map<String, dynamic>?> _askPostPrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('blousab_posts_visibility') ?? 'everyone';
    final defaults = <String, dynamic>{
      'visibility': stored == 'friends' ? 'friends' : 'everyone',
      'exceptIds': <String>[],
      'allowComments': true,
      'allowShares': true,
      'hideLikes': false,
    };
    var visibility = defaults['visibility'] as String;
    var allowComments = true, allowShares = true, hideLikes = false;
    final except = <String>{};
    final friends = _friends.where((id) => id.isNotEmpty && id != _myId).toList();
    if (!mounted) return null;
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('خصوصية المنشور', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('اختر من يرى منشورك وماذا يستطيع أن يفعل به، أو اضغط «تخطي» للنشر بالإعدادات الافتراضية.', style: TextStyle(fontSize: 13.5)),
            const SizedBox(height: 12),
            const Text('من يمكنه رؤية المنشور؟', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              ChoiceChip(label: const Text('الجميع'), selected: visibility == 'everyone', onSelected: (_) => setSheet(() => visibility = 'everyone')),
              ChoiceChip(label: const Text('الأصدقاء فقط'), selected: visibility == 'friends', onSelected: (_) => setSheet(() => visibility = 'friends')),
              ChoiceChip(label: const Text('الجميع ما عدا...'), selected: visibility == 'except', onSelected: (_) => setSheet(() => visibility = 'except')),
            ]),
            if (visibility == 'except') ...[
              const SizedBox(height: 6),
              if (friends.isEmpty)
                const Text('لا يوجد أصدقاء لاستثنائهم بعد.', style: TextStyle(fontSize: 13))
              else
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_off_outlined),
                  label: Text(except.isEmpty ? 'اختيار الأصدقاء المستثنين' : 'المستثنون: ${except.length}'),
                  onPressed: () async {
                    await showDialog<void>(
                      context: ctx,
                      builder: (dctx) => StatefulBuilder(builder: (dctx, setDialog) => AlertDialog(
                        title: const Text('لا أريدهم أن يروا المنشور'),
                        content: SizedBox(width: double.maxFinite, child: ListView(shrinkWrap: true, children: friends.map((id) {
                          final name = BlousabPresence.instance.nameOf(id, 'صديق');
                          return CheckboxListTile(
                            value: except.contains(id),
                            onChanged: (v) => setDialog(() { if (v == true) { except.add(id); } else { except.remove(id); } }),
                            title: Text(name),
                            secondary: BlousabUserAvatar(userId: id, name: name, size: 38, tappable: false),
                            controlAffinity: ListTileControlAffinity.trailing,
                          );
                        }).toList())),
                        actions: [FilledButton(onPressed: () => Navigator.pop(dctx), child: const Text('تم'))],
                      )),
                    );
                    setSheet(() {});
                  },
                ),
            ],
            const SizedBox(height: 6),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('السماح بالتعليقات'), value: allowComments, onChanged: (v) => setSheet(() => allowComments = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('السماح بمشاركة المنشور'), value: allowShares, onChanged: (v) => setSheet(() => allowShares = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('إخفاء عدد الإعجابات عن الآخرين'), value: hideLikes, onChanged: (v) => setSheet(() => hideLikes = v)),
            const SizedBox(height: 6),
            Row(children: [
              TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('إلغاء')),
              const Spacer(),
              OutlinedButton(onPressed: () => Navigator.pop(ctx, defaults), child: const Text('تخطي')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, <String, dynamic>{
                  'visibility': visibility == 'except' && except.isEmpty ? 'everyone' : visibility,
                  'exceptIds': visibility == 'except' ? except.toList() : <String>[],
                  'allowComments': allowComments,
                  'allowShares': allowShares,
                  'hideLikes': hideLikes,
                }),
                child: const Text('نشر'),
              ),
            ]),
          ]),
        ),
      )),
    );
  }

  Future<File> _applyVideoEditWithProgress(String sourcePath, VideoEditResult edit) async {
    final progress = ValueNotifier<double>(0);
    // يظهر شريط تجهيز مستمر فور انتهاء التعديل، ولا يكشف صيغة الملف الداخلية.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('جارٍ تجهيز الفيديو'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: value <= 0 ? null : value, minHeight: 9),
                ),
                const SizedBox(height: 10),
                Text(value > 0 ? 'جارٍ التجهيز… ${(value * 100).round()}%' : 'جارٍ تجهيز الفيديو للنشر…'),
              ],
            ),
          ),
        ),
      ),
    ).then<void>((_) {}));
    // السماح بإظهار نافذة التقدم قبل بدء عملية الضغط الثقيلة.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      return await applyVideoEdit(sourcePath, edit, onProgress: (value) => progress.value = value);
    } finally {
      progress.dispose();
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    }
  }

  Future<void> _createPost() async {
    final kind = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo_outlined), title: const Text('نشر صورة'), onTap: () => Navigator.pop(ctx, 'image')),
      ListTile(leading: const Icon(Icons.video_library_outlined), title: const Text('نشر فيديو'), onTap: () => Navigator.pop(ctx, 'video')),
      ListTile(leading: const Icon(Icons.notes_outlined), title: const Text('نشر نص فقط'), onTap: () => Navigator.pop(ctx, 'text')),
      const SizedBox(height: 8),
    ])));
    if (kind == null || !mounted || _busy) return;
    setState(() => _busy = true);
    String? mediaPath;
    try {
      if (kind == 'image') {
        final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 68, maxWidth: 1280, maxHeight: 1280);
        if (picked == null) return;
        if (!mounted) return;
        final edited = await openImageEditor(context, picked.path);
        if (edited == null) return;
        final dir = await _feedDir(); mediaPath = '${dir.path}/post_${DateTime.now().microsecondsSinceEpoch}.jpg';
        await File(edited).copy(mediaPath);
      } else if (kind == 'video') {
        final picked = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
        if (picked == null) return;
        if (!mounted) return;
        final videoEdit = await openVideoEditor(context, picked.path, maxSeconds: 60, initialQuality: VideoQuality.LowQuality);
        if (videoEdit == null) return;
        final file = await _applyVideoEditWithProgress(picked.path, videoEdit);
        final dir = await _feedDir(); mediaPath = '${dir.path}/post_${DateTime.now().microsecondsSinceEpoch}.mp4';
        await file.copy(mediaPath);
      }
      if (!mounted) return;
      final textController = TextEditingController();
      final tagsController = TextEditingController();
      final content = await showDialog<Map<String,String>?>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('منشور جديد'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (mediaPath != null) Container(width: double.infinity, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)), child: Row(children: [Icon(kind == 'video' ? Icons.play_circle_outline : Icons.image_outlined), const SizedBox(width: 8), Expanded(child: Text(kind == 'video' ? 'فيديو جاهز للنشر' : 'صورة جاهزة للنشر'))])),
          TextField(controller: textController, maxLines: 4, maxLength: 1200, decoration: const InputDecoration(labelText: 'ماذا تريد أن تنشر؟', border: OutlineInputBorder())),
          const SizedBox(height: 10), TextField(controller: tagsController, decoration: const InputDecoration(labelText: 'هاشتاجات (مثال #بلوساب #أصدقاء)', border: OutlineInputBorder())),
          const SizedBox(height: 8), const Text('يُحفظ المنشور على جهازك ويُزامن تلقائيًا مع أجهزة بلوساب القريبة عند توفر الاتصال.', style: TextStyle(fontSize: 12)),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () { if (kind == 'text' && textController.text.trim().isEmpty) return; Navigator.pop(ctx, {'text':textController.text.trim(),'tags':tagsController.text.trim()}); }, child: const Text('نشر'))],
      ));
      textController.dispose(); tagsController.dispose();
      if (content == null) return;
      final privacy = await _askPostPrivacy();
      if (privacy == null) return;
      final prefs = await SharedPreferences.getInstance();
      _myId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      final post = <String,dynamic>{
        'id': '${_myId}_${DateTime.now().microsecondsSinceEpoch}', 'authorId': _myId,
        'authorName': widget.userName.isEmpty ? 'مستخدم بلوساب' : widget.userName,
        'profilePhotoPath': widget.profilePhotoPath, 'mediaType': kind, 'mediaPath': mediaPath,
        'text': content['text'] ?? '', 'hashtags': content['tags'] ?? '',
        'createdAt': DateTime.now().millisecondsSinceEpoch, 'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'visibility': privacy['visibility'],
        'exceptIds': privacy['exceptIds'],
        'allowComments': privacy['allowComments'],
        'allowShares': privacy['allowShares'],
        'hideLikes': privacy['hideLikes'],
        'likeLog': <String, dynamic>{}, 'shareLog': <Map<String, dynamic>>[],
        'likes': <String>[], 'comments': <Map<String,dynamic>>[],
      };
      setState(() => _posts.insert(0, post));
      await _save();
      try {
        if (LocalNetworkService.instance.isRunning) {
          await _broadcastPost(post);
          if (mounted) BlousabToast.show(context, 'نُشر المنشور وأُرسل إلى أجهزة بلوساب المتاحة.');
        } else if (mounted) {
          BlousabToast.show(context, 'حُفظ المنشور على جهازك، وستتم مزامنته تلقائيًا عند توفر اتصال مباشر بالأجهزة القريبة.');
        }
      } catch (_) {
        if (mounted) BlousabToast.show(context, 'حُفظ المنشور على جهازك، لكن تعذّر إرساله للأجهزة القريبة حاليًا.');
      }
    } catch (e) {
      if (mounted) BlousabToast.show(context, 'تعذر تجهيز المنشور: $e');
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Map<String, dynamic> _likeLogOf(Map p) => Map<String, dynamic>.from(p['likeLog'] as Map? ?? const {});

  List<Map<String, dynamic>> _shareLogOf(Map p) =>
      (p['shareLog'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  List<Map<String, dynamic>> _mergeShareLog(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    final byId = <String, Map<String, dynamic>>{};
    for (final e in [...a, ...b]) {
      final id = e['id']?.toString() ?? '';
      if (id.isNotEmpty) byId[id] = e;
    }
    final out = byId.values.toList()..sort((x, y) => ((y['at'] as num?) ?? 0).compareTo((x['at'] as num?) ?? 0));
    return out;
  }

  Future<void> _toggleLike(Map<String,dynamic> post) async {
    final likes = List<String>.from(post['likes'] as List? ?? const []);
    final log = _likeLogOf(post);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (likes.contains(_myId)) {
      likes.remove(_myId);
      log.remove(_myId);
    } else {
      likes.add(_myId);
      log[_myId] = {'at': now, 'name': widget.userName};
    }
    setState(() { post['likes'] = likes; post['likeLog'] = log; post['updatedAt'] = now; });
    await _save();
    await _broadcastPostUpdate(post);
  }

  Future<void> _comments(Map<String,dynamic> post) async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (ctx) => StatefulBuilder(builder: (ctx,setSheet) {
      final comments = List<Map<String,dynamic>>.from((post['comments'] as List? ?? const []).map((e) => Map<String,dynamic>.from(e as Map)));
      return Padding(padding: EdgeInsets.only(left: 16,right: 16,top: 8,bottom: MediaQuery.of(ctx).viewInsets.bottom+16), child: SizedBox(height: MediaQuery.of(ctx).size.height*0.55, child: Column(children: [
        const Text('التعليقات',style: TextStyle(fontSize: 18,fontWeight: FontWeight.bold)), const SizedBox(height: 12),
        Expanded(
          child: comments.isEmpty
              ? const Center(child: Text('لا توجد تعليقات بعد.'))
              : ListView(
                  children: comments.map((c) {
                    final cid = c['userId']?.toString() ?? '';
                    final cname = c['name']?.toString() ?? 'مستخدم';
                    final mineC = cid.isEmpty || cid == _myId;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        BlousabUserAvatar(userId: mineC ? '' : cid, name: cname, size: 44, ownPhotoPath: widget.profilePhotoPath),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(child: mineC
                                ? Text(cname, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))
                                : BlousabUserTap(userId: cid, name: cname, child: Text(cname, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)))),
                            const SizedBox(width: 8),
                            BlousabTimeText(time: c['createdAt'], style: const TextStyle(fontSize: 11.5, color: Color(0xFF8FA3D8))),
                          ]),
                          if (!mineC) BlousabPresenceText(userId: cid, fontSize: 12),
                          const SizedBox(height: 2),
                          Text(c['text']?.toString() ?? '', style: const TextStyle(fontSize: 15, height: 1.4)),
                        ])),
                      ]),
                    );
                  }).toList(),
                ),
        ),
        if (post['allowComments'] == false) const Padding(padding: EdgeInsets.all(12), child: Text('التعليقات متوقفة لهذا المنشور.', textAlign: TextAlign.center)) else Row(children: [Expanded(child: TextField(controller: controller, maxLength: 500, decoration: const InputDecoration(hintText:'اكتب تعليقًا', counterText:'', border: OutlineInputBorder()))), const SizedBox(width:8), IconButton.filled(onPressed: () async { final text = controller.text.trim(); if (text.isEmpty) return; comments.add({'id':'${_myId}_${DateTime.now().microsecondsSinceEpoch}','name':widget.userName,'userId':_myId,'text':text,'createdAt':DateTime.now().millisecondsSinceEpoch}); post['comments'] = comments; post['updatedAt'] = DateTime.now().millisecondsSinceEpoch; controller.clear(); setSheet((){}); setState((){}); await _save(); await _broadcastPostUpdate(post); }, icon: const Icon(Icons.send))]),
      ])));
    }));
    controller.dispose();
  }

  // أيقونة المراسلة: صديق + متوفر → المحادثة، غير ذلك → رسالة خطأ أو طلب صداقة.
  Future<void> _requestChat(Map<String,dynamic> post) async {
    final authorId = post['authorId']?.toString() ?? '';
    if (authorId.isEmpty || authorId == _myId) { BlousabToast.show(context, 'هذا منشورك أنت.'); return; }
    await blousabMessageUser(context, userId: authorId, name: post['authorName']?.toString() ?? '');
    await _reloadFriendsFromStore();
  }


  int _filter = 0; // 0 all, 1 nearby (others), 2 friends, 3 liked
  bool _reels = false; // وضع الريلز
  int _reelIndex = 0;
  final PageController _reelController = PageController();
  Map<String, Map<String, dynamic>> _shared = <String, Map<String, dynamic>>{}; // منشورات شاركها لي الآخرون
  static const String _sharedKey = 'blousab_feed_shared_v1';
  static const String _sharePendingKey = 'blousab_share_pending_v1';

  // إعداد «من يمكنه رؤية منشوراتك»: المنشورات المحددة للأصدقاء لا تظهر لغيرهم.
  bool _canSeePost(Map<String, dynamic> p) {
    final author = p['authorId']?.toString() ?? '';
    if (author == _myId) return true;
    if (_shared.containsKey(p['id']?.toString())) return true;
    if ((p['visibility']?.toString() ?? 'everyone') == 'friends') return _friends.contains(author);
    if (List<String>.from(p['exceptIds'] as List? ?? const []).contains(_myId)) return false;
    return true;
  }

  List<Map<String, dynamic>> get _visiblePosts {
    final base = _posts.where(_canSeePost).toList();
    switch (_filter) {
      case 1:
        return base.where((p) => p['authorId']?.toString() != _myId).toList();
      case 2:
        return base.where((p) => _friends.contains(p['authorId']?.toString())).toList();
      case 3:
        return base.where((p) => List<String>.from(p['likes'] as List? ?? const []).contains(_myId)).toList();
      default:
        return base;
    }
  }

  Widget _filterChip(int value, String label, IconData icon) {
    final selected = _filter == value;
    final iconWidget = Icon(icon, size: 22, color: selected ? Colors.white : const Color(0xFF3FA2FF));
    final text = Text(label, maxLines: 1, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700));
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _filter = value),
        onLongPress: value == 0 ? _toggleOrder : null,
        child: Container(
          height: 46,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: selected ? const LinearGradient(colors: [Color(0xFF1FA2FF), Color(0xFF3A6BFF), Color(0xFF9A3BFF)]) : null,
            color: selected ? null : const Color(0xFF0A1330),
            border: Border.all(color: selected ? const Color(0xFF3FA2FF) : const Color(0xFF2B48A8), width: 1.3),
            boxShadow: selected ? const [BoxShadow(color: Color(0x443A6BFF), blurRadius: 7.2)] : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: selected ? [text, const SizedBox(width: 7), iconWidget] : [iconWidget, const SizedBox(width: 7), text],
          ),
        ),
      ),
    );
  }

  String _countText(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';

  Widget _reactionDots() => Container(
    width: 28, height: 28,
    decoration: BoxDecoration(color: const Color(0xFFFF2D55), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF0A1330), width: 2)),
    child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 15),
  );

  // ---------- مشاركة المنشور كاملاً (مع هوية صاحبه وحقوقه) ----------
  Future<void> _loadShared() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sharedKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw);
      if (map is Map && mounted) {
        setState(() => _shared = map.map((k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map))));
      }
    } catch (_) {}
  }

  Future<void> _saveShared() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sharedKey, jsonEncode(_shared));
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _loadSharePending() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <Map<String, dynamic>>[];
    for (final raw in prefs.getStringList(_sharePendingKey) ?? const <String>[]) {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        if (now - ((m['createdAt'] as num?)?.toInt() ?? 0) < const Duration(days: 3).inMilliseconds) out.add(m);
      } catch (_) {}
    }
    return out;
  }

  Future<void> _saveSharePending(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_sharePendingKey, list.map(jsonEncode).toList());
  }

  Future<void> _flushSharePending([String? peerId]) async {
    try {
      for (final notice in await _loadSharePending()) {
        if (peerId != null && peerId.isNotEmpty && notice['recipientId']?.toString() != peerId) continue;
        final index = _posts.indexWhere((p) => p['id']?.toString() == notice['postId']?.toString());
        if (index >= 0) { try { await _broadcastPost(_posts[index]); } catch (_) {} }
        try { await _broadcastFeedPacket(jsonEncode(notice)); } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _addShareNotification(String sharerName, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = prefs.getStringList('blousab_notifications_v1') ?? <String>[];
      items.insert(0, jsonEncode({'id': 'share_$id', 'sender': sharerName, 'type': 'share', 'at': DateTime.now().toIso8601String()}));
      if (items.length > 100) items.removeRange(100, items.length);
      await prefs.setStringList('blousab_notifications_v1', items);
      await BlousabBadges.refresh();
    } catch (_) {}
  }

  Future<void> _sendShare(Map<String, dynamic> post, Set<String> recipients) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try { await _broadcastPost(post); } catch (_) {}
    final pending = await _loadSharePending();
    final shareLog = _shareLogOf(post);
    for (final r in recipients) {
      final notice = <String, dynamic>{
        'type': 'post_share',
        'shareId': '${_myId}_${now}_$r',
        'recipientId': r,
        'sharerId': _myId,
        'sharerName': widget.userName,
        'postId': post['id']?.toString() ?? '',
        'authorId': post['authorId']?.toString() ?? '',
        'authorName': post['authorName']?.toString() ?? '',
        'createdAt': now,
      };
      pending.removeWhere((p) => p['recipientId'] == r && p['postId'] == notice['postId']);
      pending.add(notice);
      shareLog.add({'id': notice['shareId'], 'userId': _myId, 'name': widget.userName, 'toId': r, 'toName': BlousabPresence.instance.nameOf(r, 'صديق'), 'at': now});
      try { await _broadcastFeedPacket(jsonEncode(notice)); } catch (_) {}
    }
    await _saveSharePending(pending);
    if (mounted) {
      setState(() {
        post['shareLog'] = shareLog;
        post['shares'] = ((post['shares'] as num?)?.toInt() ?? 0) + recipients.length;
        post['updatedAt'] = now;
      });
    }
    await _save();
    await _broadcastPostUpdate(post);
    if (mounted) BlousabToast.show(context, 'تمت مشاركة المنشور كاملاً مع ${recipients.length} ${recipients.length == 1 ? 'صديق' : 'أصدقاء'}.');
  }

  Future<void> _sharePost(Map<String, dynamic> post) async {
    if (post['allowShares'] == false && post['authorId']?.toString() != _myId) {
      BlousabToast.show(context, 'صاحب المنشور عطّل مشاركته.');
      return;
    }
    final friends = _friends.where((id) => id.isNotEmpty && id != _myId).toList();
    final selected = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('مشاركة المنشور', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('يصل المنشور كاملاً بصورته ونصّه وباسم صاحبه الأصلي (${post['authorName'] ?? 'مستخدم'}) وحقوقه محفوظة له.', style: const TextStyle(fontSize: 13.5)),
            const SizedBox(height: 8),
            if (friends.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Text('لا يوجد أصدقاء بعد. أضف أصدقاء عبر مسح رمز QR أو طلب صداقة ثم شارك المنشور معهم.'))
            else
              Flexible(child: ListView(shrinkWrap: true, children: friends.map((id) {
                final name = BlousabPresence.instance.nameOf(id, 'صديق');
                return CheckboxListTile(
                  value: selected.contains(id),
                  onChanged: (v) => setSheet(() { if (v == true) { selected.add(id); } else { selected.remove(id); } }),
                  title: Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  subtitle: BlousabPresenceText(userId: id, fontSize: 12),
                  secondary: BlousabUserAvatar(userId: id, name: name, size: 42, tappable: false),
                  controlAffinity: ListTileControlAffinity.trailing,
                );
              }).toList())),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () async {
                  final text = [post['text']?.toString() ?? '', post['hashtags']?.toString() ?? ''].where((e) => e.trim().isNotEmpty).join('\n');
                  await Clipboard.setData(ClipboardData(text: text.isEmpty ? 'منشور من بلوساب' : '$text\n— ${post['authorName'] ?? ''} (بلوساب)'));
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) BlousabToast.show(context, 'تم نسخ نص المنشور.');
                },
                icon: const Icon(Icons.copy_rounded), label: const Text('نسخ النص'),
              )),
              const SizedBox(width: 10),
              Expanded(child: FilledButton.icon(
                onPressed: selected.isEmpty ? null : () async {
                  Navigator.pop(ctx);
                  await _sendShare(post, Set<String>.from(selected));
                },
                icon: const Icon(Icons.send_rounded), label: Text(selected.isEmpty ? 'إرسال' : 'إرسال (${selected.length})'),
              )),
            ]),
          ]),
        ),
      )),
    );
  }

  Widget _shareBanner(Map<String, dynamic> post) {
    final info = _shared[post['id']?.toString()] ?? const <String, dynamic>{};
    final author = post['authorName']?.toString() ?? 'صاحب المنشور';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: const Color(0x2228C7FF),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.reply_rounded, color: Color(0xFF28C7FF), size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text('شاركه لك ${info['byName'] ?? 'صديق'}', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 2),
        Text('© المنشور الأصلي لـ $author — جميع الحقوق محفوظة له', style: const TextStyle(color: Color(0xFFB4C3F0), fontSize: 12.5)),
      ]),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white, Widget? iconWidget}) => Expanded(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          iconWidget ?? Icon(icon, color: color == Colors.white ? const Color(0xFFD5DEFF) : color, size: 26),
          const SizedBox(width: 5),
          Text(label, textDirection: TextDirection.rtl, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
      ),
    ),
  );

  Widget _postCard(Map<String, dynamic> post) {
    final author = post['authorName']?.toString() ?? 'مستخدم بلوساب';
    final photo = post['profilePhotoPath']?.toString() ?? '';
    final media = post['mediaPath']?.toString() ?? '';
    final type = post['mediaType']?.toString() ?? 'text';
    final likes = List<String>.from(post['likes'] as List? ?? const []);
    final comments = post['comments'] as List? ?? const [];
    final shares = (post['shares'] as num?)?.toInt() ?? 0;
    final hashtags = post['hashtags']?.toString() ?? '';
    final text = post['text']?.toString() ?? '';
    final mine = post['authorId']?.toString() == _myId;
    final liked = likes.contains(_myId);
    final authorId = post['authorId']?.toString() ?? '';
    return BlousabKeepColors(child: Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      decoration: blousabCardDecoration(radius: 20),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!mine && _shared.containsKey(post['id']?.toString())) _shareBanner(post),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 0),
          child: Row(children: [
            mine
                ? BlousabRingAvatar(name: author, photoPath: widget.profilePhotoPath.isNotEmpty ? widget.profilePhotoPath : photo, size: 52, ring: 2.5)
                : BlousabUserAvatar(userId: authorId, name: author, size: 52),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: mine
                    ? Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))
                    : BlousabUserTap(userId: authorId, name: author, child: Text(BlousabPresence.instance.nameOf(authorId, author), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)))),
                if (mine) const Padding(padding: EdgeInsetsDirectional.only(start: 5), child: BlousabVerifiedBadge(size: 20)),
              ]),
              if (!mine) BlousabPresenceText(userId: authorId, fontSize: 12),
              Row(mainAxisSize: MainAxisSize.min, children: [
                BlousabTimeText(time: post['createdAt'], style: const TextStyle(color: Color(0xFFB4C3F0), fontSize: 12)),
                const SizedBox(width: 6),
                const Text('•', style: TextStyle(color: Color(0xFFB4C3F0), fontSize: 13)),
                const SizedBox(width: 6),
                const Icon(Icons.public, color: Color(0xFFB4C3F0), size: 17),
              ]),
            ])),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Color(0xFF8FB2FF), size: 24),
              onSelected: (v) async {
                if (v == 'interactions' && mine) { Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PostInteractionsScreen(posts: [post], title: 'تفاعلات المنشور'))); }
                else if (v == 'delete' && mine) { setState(() => _posts.remove(post)); await _save(); }
                else if (v == 'report') { BlousabToast.show(context, 'تم تسجيل البلاغ محليًا.'); }
              },
              itemBuilder: (_) => [
                if (mine) const PopupMenuItem(value: 'interactions', child: Text('التفاعلات والمشاركات')),
                if (mine) const PopupMenuItem(value: 'delete', child: Text('حذف المنشور')),
                const PopupMenuItem(value: 'report', child: Text('إبلاغ')),
              ],
            ),
          ]),
        ),
        if (text.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(14, 8, 14, 2), child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.55))),
        if (hashtags.isNotEmpty) Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
          child: Text(
            hashtags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).map((tag) => tag.startsWith('#') ? tag : '#$tag').join('   '),
            style: const TextStyle(color: Color(0xFF2F8BFF), fontSize: 15.5, fontWeight: FontWeight.w600)),
        ),
        if (type == 'image' && media.isNotEmpty) Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: BlousabKeepColors(child: Image.file(File(media), width: double.infinity, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(height: 180, child: Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54))))),
            ),
          ),
        ),
        if (type == 'video' && media.isNotEmpty) Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: ClipRRect(borderRadius: BorderRadius.circular(16), child: BlousabKeepColors(child: _FeedVideo(path: media))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(children: [
              _reactionDots(),
              const SizedBox(width: 8),
              Text((post['hideLikes'] == true && !mine) ? '•' : _countText(likes.length), style: const TextStyle(color: Color(0xFFD5DEFF), fontSize: 15)),
              const Spacer(),
              Text('${comments.length} تعليق', textDirection: TextDirection.rtl, style: const TextStyle(color: Color(0xFFB4C3F0), fontSize: 13.5)),
              const SizedBox(width: 10),
              Text('$shares مشاركة', textDirection: TextDirection.rtl, style: const TextStyle(color: Color(0xFFB4C3F0), fontSize: 13.5)),
            ]),
          ),
        ),
        Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 12), color: const Color(0xFF1E2F6B)),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(children: [
            _actionButton(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, 'أعجبني', () => _toggleLike(post), color: liked ? const Color(0xFFFF3B5C) : Colors.white),
            _actionButton(Icons.mode_comment_outlined, 'تعليق', () => _comments(post)),
            _actionButton(Icons.reply_rounded, 'مشاركة', () => _sharePost(post)),
            if (!mine) _actionButton(Icons.chat_bubble_outline, 'مراسلة', () => _requestChat(post), iconWidget: const BlousabMessageIcon(size: 26)),
          ]),
        ),
      ]),
    ));
  }

  Widget _addPill() => GestureDetector(
    onTap: _busy ? null : _createPost,
    child: Tooltip(
      message: 'إنشاء منشور',
      child: Container(
        width: 54, height: 30,
        decoration: BoxDecoration(
          color: const Color(0xFF06122E),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: const Color(0xFF28C7FF), width: 1.6),
        ),
        child: const Icon(Icons.add_rounded, color: Color(0xFF28C7FF), size: 22),
      ),
    ),
  );

  Widget _modeBtn(IconData icon, bool on, String tip, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Tooltip(
      message: tip,
      child: Container(
        width: 40, height: 30,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          gradient: on ? const LinearGradient(colors: [Color(0xFF0F4DD8), Color(0xFF1B2F9A)]) : null,
        ),
        child: Icon(icon, size: 22, color: on ? Colors.white : const Color(0xFF8FB2FF)),
      ),
    ),
  );

  Widget _modeToggle() => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: const Color(0xFF06122E),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF3B5BDB), width: 1.4),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      _modeBtn(Icons.home_rounded, !_reels, 'الرئيسية', () => setState(() => _reels = false)),
      _modeBtn(Icons.slow_motion_video_rounded, _reels, 'ريلز', () => setState(() { _reels = true; _reelIndex = 0; })),
    ]),
  );

  Widget _reelAction(Widget icon, String label, VoidCallback onTap) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        icon,
        if (label.isNotEmpty) const SizedBox(height: 3),
        if (label.isNotEmpty) Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, shadows: [Shadow(color: Colors.black87, blurRadius: 4)])),
      ]),
    ),
  );

  Widget _reelsView(List<Map<String, dynamic>> posts) {
    if (posts.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('لا توجد منشورات لعرضها كريلز بعد.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700))));
    }
    return PageView.builder(
      controller: _reelController,
      scrollDirection: Axis.vertical,
      itemCount: posts.length,
      onPageChanged: (i) => setState(() => _reelIndex = i),
      itemBuilder: (context, i) => _reelPage(posts[i], i == _reelIndex),
    );
  }

  Widget _reelPage(Map<String, dynamic> post, bool active) {
    final media = post['mediaPath']?.toString() ?? '';
    final type = post['mediaType']?.toString() ?? 'text';
    final likes = List<String>.from(post['likes'] as List? ?? const []);
    final comments = post['comments'] as List? ?? const [];
    final text = post['text']?.toString() ?? '';
    final hashtags = post['hashtags']?.toString() ?? '';
    final authorId = post['authorId']?.toString() ?? '';
    final mine = authorId == _myId;
    final author = mine ? widget.userName : BlousabPresence.instance.nameOf(authorId, post['authorName']?.toString() ?? 'مستخدم بلوساب');
    final liked = likes.contains(_myId);
    final fileOk = media.isNotEmpty && File(media).existsSync();
    final shared = !mine && _shared.containsKey(post['id']?.toString());
    Widget background;
    if (type == 'image' && fileOk) {
      background = SizedBox.expand(child: Image.file(File(media), fit: BoxFit.cover));
    } else if (type == 'video' && fileOk) {
      background = _FeedVideo(key: ValueKey('reel_${post['id']}'), path: media, autoPlay: active, cover: true);
    } else {
      background = Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0B2E7A), Color(0xFF2B1470), Color(0xFF05102E)])),
        alignment: Alignment.center,
        padding: const EdgeInsets.fromLTRB(26, 26, 90, 120),
        child: Text(text.isEmpty ? '…' : text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.5)),
      );
    }
    final showCaption = (type == 'image' || type == 'video') && (text.isNotEmpty || hashtags.isNotEmpty);
    return BlousabKeepColors(
      child: GestureDetector(
        onDoubleTap: () { if (!liked) _toggleLike(post); },
        child: Container(
          color: const Color(0xFF050A1E),
          child: Stack(fit: StackFit.expand, children: [
            background,
            const Positioned(left: 0, right: 0, bottom: 0, height: 230, child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xE6000000), Color(0x00000000)])))),
            // معلومات صاحب المنشور (أسفل اليسار) — الهوية والحقوق محفوظة
            Positioned(
              left: 14, right: 78, bottom: 16,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  mine
                      ? BlousabRingAvatar(name: author, photoPath: widget.profilePhotoPath, size: 44, ring: 2)
                      : BlousabUserAvatar(userId: authorId, name: author, size: 44),
                  const SizedBox(width: 9),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    mine
                        ? Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))
                        : BlousabUserTap(userId: authorId, name: author, child: Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black87, blurRadius: 4)]))),
                    if (!mine) BlousabPresenceText(userId: authorId, fontSize: 12),
                  ])),
                ]),
                if (shared) Padding(padding: const EdgeInsets.only(top: 6), child: Text('شاركه لك ${_shared[post['id']?.toString()]?['byName'] ?? 'صديق'} • © للمنشور الأصلي', style: const TextStyle(color: Color(0xFFB9E6FF), fontSize: 12.5, fontWeight: FontWeight.w700))),
                if (showCaption) Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text([text, hashtags].where((e) => e.trim().isNotEmpty).join('\n'), maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35, shadows: [Shadow(color: Colors.black87, blurRadius: 4)])),
                ),
              ]),
            ),
            // الأيقونات الجانبية: إعجاب، تعليق، مشاركة، مراسلة
            Positioned(
              right: 8, bottom: 22,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _reelAction(Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? const Color(0xFFFF3B5C) : Colors.white, size: 34), (post['hideLikes'] == true && !mine) ? '' : _countText(likes.length), () => _toggleLike(post)),
                _reelAction(const Icon(Icons.mode_comment_outlined, color: Colors.white, size: 32), _countText(comments.length), () => _comments(post)),
                _reelAction(const Icon(Icons.reply_rounded, color: Colors.white, size: 34), _countText((post['shares'] as num?)?.toInt() ?? 0), () => _sharePost(post)),
                if (!mine) _reelAction(const BlousabMessageIcon(size: 32, color: Colors.white), 'مراسلة', () => _requestChat(post)),
                if (mine) _reelAction(const Icon(Icons.insights_rounded, color: Colors.white, size: 32), 'التفاعلات', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PostInteractionsScreen(posts: [post], title: 'تفاعلات المنشور')))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visiblePosts;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        BlousabTopBar(
          start: [_addPill()],
          end: [_modeToggle(), const SizedBox(width: 8), BlousabBell(count: _friendRequests.length, onTap: _showNotifications)],
        ),
        if (!_reels) Padding(
          padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
          child: Row(children: [
            _filterChip(3, 'المتابعة', Icons.star_border_rounded),
            _filterChip(2, 'المتابعون', Icons.groups_rounded),
            _filterChip(1, 'الأقرب', Icons.location_on_rounded),
            _filterChip(0, 'الكل', Icons.public),
          ]),
        ),
        if (!_reels) SizedBox(height: 112, child: StoriesStrip(userName: widget.userName, profilePhotoPath: widget.profilePhotoPath, networkSync: false, onAddPost: _busy ? null : _createPost)),
        if (!_reels) Container(height: 1, margin: const EdgeInsets.fromLTRB(0, 2, 0, 6), color: const Color(0xFF14224F)),
        Expanded(child: _reels && !_loading ? _reelsView(visible) : _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off_outlined, size: 52, color: Colors.white70),
                const SizedBox(height: 12),
                Text(_loadError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: _refreshFeed, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
              ])))
            : visible.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.dynamic_feed_outlined, size: 64, color: Color(0xFF3FA2FF)),
                  const SizedBox(height: 12),
                  Text(_posts.isEmpty ? 'لا توجد منشورات بعد' : 'لا توجد منشورات في هذا القسم', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  const Text('انشر صورة أو فيديو أو نص. ستظهر تلقائيًا المنشورات التي تصل من أجهزة بلوساب القريبة عند توفر قناة اتصال مباشرة.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFC6D0F2))),
                ])))
              : RefreshIndicator(
                  onRefresh: _refreshFeed,
                  child: ListView.builder(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: visible.length,
                    itemBuilder: (context, index) => _postCard(visible[index]),
                  ),
                )),
      ]),
    );
  }
}

class _IncomingFeedMedia {
  final Map<String, dynamic> post;
  final int chunkCount;
  final int compressedBytes;
  final int originalBytes;
  final int hops;
  final bool useGzip;
  final String sha256Hex;
  final DateTime createdAt = DateTime.now();
  final Map<int, List<int>> chunks = <int, List<int>>{};
  int receivedBytes = 0;
  _IncomingFeedMedia({required this.post, required this.chunkCount,
    required this.compressedBytes, required this.originalBytes, required this.hops,
    required this.useGzip, required this.sha256Hex});
}

class _FeedVideo extends StatefulWidget {
  final String path;
  final bool autoPlay;
  final bool cover;
  const _FeedVideo({super.key, required this.path, this.autoPlay = false, this.cover = false});
  @override
  State<_FeedVideo> createState() => _FeedVideoState();
}

class _FeedVideoState extends State<_FeedVideo> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (!mounted) return;
        if (widget.autoPlay) { _controller.setLooping(true); _controller.play(); }
        setState(() => _ready = true);
      }).catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant _FeedVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (widget.autoPlay && !oldWidget.autoPlay) { _controller.play(); }
    if (!widget.autoPlay && oldWidget.autoPlay) { _controller.pause(); }
  }

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return widget.cover
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    }
    final player = widget.cover
        ? SizedBox.expand(child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox(width: _controller.value.size.width, height: _controller.value.size.height, child: VideoPlayer(_controller))))
        : AspectRatio(aspectRatio: _controller.value.aspectRatio, child: VideoPlayer(_controller));
    return GestureDetector(
      onTap: () => setState(() => _controller.value.isPlaying ? _controller.pause() : _controller.play()),
      child: Stack(alignment: Alignment.center, children: [
        player,
        if (!_controller.value.isPlaying) const CircleAvatar(backgroundColor: Colors.black54, child: Icon(Icons.play_arrow, color: Colors.white)),
      ]),
    );
  }
}
