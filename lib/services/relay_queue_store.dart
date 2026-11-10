import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Durable, bounded store for relay packets and IDs already seen by this device.
/// It stores opaque payloads; end-to-end encryption must be applied by the sender.
class RelayQueueStore {
  RelayQueueStore._();
  static final RelayQueueStore instance = RelayQueueStore._();
  static const maxEntries = 500;
  static const maxSeen = 5000;
  static const maxAge = Duration(hours: 24);
  Future<void> _tail = Future<void>.value();

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/$name');
  }
  Future<T> _serial<T>(Future<T> Function() action) {
    final c = Completer<T>();
    _tail = _tail.then((_) async { try { c.complete(await action()); } catch (e, st) { c.completeError(e, st); } });
    return c.future;
  }
  Future<List<Map<String,dynamic>>> _read(File f) async {
    if (!await f.exists()) return [];
    try {
      final d = jsonDecode(await f.readAsString());
      if (d is! List) throw const FormatException('Relay store root is not a list');
      return d.whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();
    } catch (error) {
      // Never turn a damaged durable queue into an empty queue: that would
      // silently overwrite unacknowledged messages. Keep the original file.
      throw StateError('تعذرت قراءة مخزن الترحيل؛ تم الحفاظ على الملف دون استبداله: $error');
    }
  }
  Future<void> _writeAtomic(File file, Object value) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    // On Android/Linux rename replaces the previous file atomically. Keeping
    // the old file until the rename prevents a crash window with no queue.
    await temp.rename(file.path);
  }
  Future<bool> markSeen(String id) => _serial(() async {
    if (id.isEmpty) return false;
    final f=await _file('blousab_relay_seen.json'); final rows=await _read(f);
    if (rows.any((e)=>e['id']==id)) return false;
    rows.add({'id':id,'at':DateTime.now().toIso8601String()});
    final cutoff=DateTime.now().subtract(maxAge);
    rows.removeWhere((e){ final d=DateTime.tryParse('${e['at']}'); return d==null || d.isBefore(cutoff); });
    if (rows.length>maxSeen) rows.removeRange(0,rows.length-maxSeen);
    await _writeAtomic(f, rows); return true;
  });
  /// Atomically reserves an ID and persists its relay packet. The queue is
  /// written before the seen-ID ledger, so a crash can at worst cause a
  /// duplicate enqueue (deduplicated by packet ID), never a silently lost hop.
  Future<bool> enqueueIfNew(Map<String,dynamic> packet) => _serial(() async {
    final id='${packet['id'] ?? ''}';
    if(id.isEmpty || id.length > 160) throw ArgumentError('معرّف حزمة الترحيل غير صالح');
    final encoded = jsonEncode(packet);
    if(utf8.encode(encoded).length > 1024 * 1024) {
      throw ArgumentError('حزمة الترحيل أكبر من حد الإطار؛ يجب تقسيم الملف قبل وضعه في قائمة الترحيل');
    }
    final queueFile=await _file('blousab_relay_queue.json');
    final seenFile=await _file('blousab_relay_seen.json');
    final rows=await _read(queueFile);
    final seen=await _read(seenFile);
    if(seen.any((e)=>e['id']==id) || rows.any((e)=>e['id']==id)) return false;
    if(rows.length >= maxEntries) {
      throw StateError('قائمة الترحيل ممتلئة؛ لم يتم تسجيل المعرّف كمستلم، ويمكن إعادة المحاولة لاحقاً');
    }
    rows.add({'id':id,'payload':encoded,'queuedAt':DateTime.now().toIso8601String(),'attempts':0});
    await _writeAtomic(queueFile, rows);
    seen.add({'id':id,'at':DateTime.now().toIso8601String()});
    final cutoff=DateTime.now().subtract(maxAge);
    seen.removeWhere((e){ final d=DateTime.tryParse('${e['at']}'); return d==null || d.isBefore(cutoff); });
    if(seen.length>maxSeen) seen.removeRange(0,seen.length-maxSeen);
    await _writeAtomic(seenFile, seen);
    return true;
  });

  Future<void> enqueue(Map<String,dynamic> packet) => _serial(() async {
    final id='${packet['id'] ?? ''}';
    if(id.isEmpty || id.length > 160) throw ArgumentError('معرّف حزمة الترحيل غير صالح');
    final encoded = jsonEncode(packet);
    if(utf8.encode(encoded).length > 1024 * 1024) {
      throw ArgumentError('حزمة الترحيل أكبر من حد الإطار؛ يجب تقسيم الملف قبل وضعه في قائمة الترحيل');
    }
    final f=await _file('blousab_relay_queue.json'); final rows=await _read(f);
    if(rows.any((e)=>e['id']==id)) return;
    // Never silently evict an unacknowledged packet: doing so would turn a
    // bounded queue into silent message loss. Apply back-pressure instead.
    if(rows.length >= maxEntries) {
      throw StateError('قائمة الترحيل ممتلئة؛ لن تُحذف الحزم القديمة غير المؤكدة لإفساح المجال لحزمة جديدة');
    }
    rows.add({'id':id,'payload':encoded,'queuedAt':DateTime.now().toIso8601String(),'attempts':0});
    await _writeAtomic(f, rows);
  });
  Future<List<Map<String,dynamic>>> list() => _serial(() async {
    final f=await _file('blousab_relay_queue.json'); final rows=await _read(f); final cutoff=DateTime.now().subtract(maxAge);
    rows.removeWhere((e){ final d=DateTime.tryParse('${e['queuedAt']}'); return d==null || d.isBefore(cutoff); });
    await _writeAtomic(f, rows); return rows;
  });
  Future<void> noteAttempt(String id) => _serial(() async {
    final f=await _file('blousab_relay_queue.json'); final rows=await _read(f); final i=rows.indexWhere((e)=>e['id']==id); if(i<0)return;
    rows[i]['attempts']=(rows[i]['attempts'] as num? ?? 0)+1; rows[i]['lastAttemptAt']=DateTime.now().toIso8601String();
    await _writeAtomic(f, rows);
  });
  Future<void> remove(String id) => _serial(() async {
    final f=await _file('blousab_relay_queue.json'); final rows=await _read(f); rows.removeWhere((e)=>e['id']==id); await _writeAtomic(f, rows);
  });
}
