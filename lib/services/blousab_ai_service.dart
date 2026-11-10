import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// حجم نموذج Blousab AI. الأحجام تقريبية وليست مواصفات نهائية؛ الحجم الفعلي
/// واستهلاك الذاكرة يعتمدان على النموذج وإعدادات التشغيل.
class BlousabAiTier {
  const BlousabAiTier({
    required this.id,
    required this.label,
    required this.approxGb,
    required this.description,
    this.downloadUrl = '',
    this.sha256Hex = '',
  });

  final String id;
  final String label;
  final double approxGb;
  final String description;

  /// رابط ملف النموذج لهذا الحجم. اتركه فارغًا حتى تحدد مصدر النموذج؛
  /// عندها يعرض التطبيق رسالة واضحة بدل أن يبدأ تنزيلًا وهميًا.
  final String downloadUrl;

  /// بصمة SHA-256 المتوقعة للملف (للتحقق من سلامته بعد التنزيل).
  final String sha256Hex;

  int get approxBytes => (approxGb * 1024 * 1024 * 1024).round();
  String get sizeLabel => approxGb < 1 ? '${(approxGb * 1024).round()} MB' : '${approxGb.toStringAsFixed(approxGb == approxGb.roundToDouble() ? 0 : 1)} GB';
}

/// نماذج حقيقية عامة (لا تحتاج حساب Hugging Face) بصيغة MediaPipe .task وتعمل دون إنترنت.
/// المصدر: litert-community على Hugging Face (Qwen2.5 Instruct، ترخيص Apache-2.0).
/// تُتحقق سلامة الملف بمقارنة SHA-256 المحسوب مع البصمة التي يعلنها الخادم نفسه (x-linked-etag).
const List<BlousabAiTier> blousabAiTiers = <BlousabAiTier>[
  BlousabAiTier(
    id: 'light',
    label: 'خفيف',
    approxGb: 0.55,
    description: 'Qwen2.5 0.5B — سريع وخفيف، مناسب لمعظم الهواتف',
    downloadUrl:
        'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
  ),
  BlousabAiTier(
    id: 'balanced',
    label: 'متوازن',
    approxGb: 1.6,
    description: 'Qwen2.5 1.5B — إجابات أفضل، يحتاج هاتفاً بذاكرة 4 GB أو أكثر',
    downloadUrl:
        'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
  ),
];

enum BlousabAiStatus { notLoaded, downloading, ready }

class BlousabAiMemoryInfo {
  const BlousabAiMemoryInfo({required this.totalRam, required this.availRam, required this.freeStorage});
  final int totalRam;
  final int availRam;
  final int freeStorage;
}

class BlousabAiCancelled implements Exception {
  @override
  String toString() => 'تم إلغاء التحميل';
}

class BlousabAiService {
  BlousabAiService._();
  static final BlousabAiService instance = BlousabAiService._();

  static const _channel = MethodChannel('com.blousab.messenger/device_info');
  static const _downloadChannel = MethodChannel('com.blousab.messenger/ai_download');
  static const _kStatus = 'blousab_ai_status_v1';
  static const _kTier = 'blousab_ai_tier_v1';
  static const _kPath = 'blousab_ai_model_path_v1';
  static const _kDownloadId = 'blousab_ai_download_id_v1';
  static const _kDownloadPath = 'blousab_ai_download_path_v1';
  static const _kExpectedHash = 'blousab_ai_expected_hash_v1';

  final ValueNotifier<BlousabAiStatus> status = ValueNotifier<BlousabAiStatus>(BlousabAiStatus.notLoaded);
  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String> progressText = ValueNotifier<String>('');
  String tierId = '';
  String modelPath = '';

  int? _downloadId;
  bool _pollingDownload = false;
  bool _cancelRequested = false;
  bool _loadedOnce = false;
  bool _gemmaReady = false;
  bool _activated = false;
  InferenceModel? _model;
  InferenceChat? _chat;

  static const String _systemPrompt =
      'أنت Blousab AI، مساعد ذكاء اصطناعي محلي داخل تطبيق بلوساب يعمل دون إنترنت. '
      'أجب بنفس لغة المستخدم، وبإيجاز ووضوح، وإذا لم تعرف الإجابة فقل ذلك.';

  BlousabAiTier? get currentTier {
    for (final t in blousabAiTiers) {
      if (t.id == tierId) return t;
    }
    return null;
  }

  Future<void> load() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kStatus) ?? 'notLoaded';
    tierId = prefs.getString(_kTier) ?? '';
    modelPath = prefs.getString(_kPath) ?? '';
    if (saved == 'ready' && modelPath.isNotEmpty && await File(modelPath).exists()) {
      status.value = BlousabAiStatus.ready;
    } else {
      final id = prefs.getInt(_kDownloadId);
      final path = prefs.getString(_kDownloadPath) ?? '';
      if (id != null && path.isNotEmpty) {
        _downloadId = id;
        status.value = BlousabAiStatus.downloading;
        progressText.value = 'جارٍ استعادة حالة التنزيل…';
        unawaited(_watchNativeDownload().catchError((Object _) {}));
      } else {
        status.value = BlousabAiStatus.notLoaded;
        await prefs.setString(_kStatus, 'notLoaded');
      }
    }
  }

  Future<BlousabAiMemoryInfo?> memoryInfo() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('memoryInfo');
      if (map == null) return null;
      return BlousabAiMemoryInfo(
        totalRam: (map['totalRam'] as num?)?.toInt() ?? 0,
        availRam: (map['availRam'] as num?)?.toInt() ?? 0,
        freeStorage: (map['freeStorage'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// يعيد نصًا تحذيريًا إن كانت الموارد غير كافية، أو null إن كانت كافية.
  Future<({String? warning, bool blocking})> checkResources(BlousabAiTier tier) async {
    final info = await memoryInfo();
    if (info == null) return (warning: null, blocking: false);
    if (info.freeStorage > 0 && info.freeStorage < (tier.approxBytes * 1.15)) {
      return (warning: 'مساحة التخزين الحرة غير كافية لتنزيل النموذج «${tier.label}» (${tier.sizeLabel}).', blocking: true);
    }
    if (info.totalRam > 0 && info.totalRam < tier.approxBytes * 2.5) {
      return (
        warning: 'ذاكرة الجهاز (${(info.totalRam / 1073741824).toStringAsFixed(1)} GB) قد لا تكفي لتشغيل النموذج «${tier.label}» بسلاسة. يُنصح باختيار حجم أصغر.',
        blocking: false,
      );
    }
    return (warning: null, blocking: false);
  }

  Future<File> _targetFile(BlousabAiTier tier) async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory('${dir.path}/blousab_ai');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/${tier.id}.task');
  }

  bool tierHasSource(BlousabAiTier tier) => tier.downloadUrl.trim().isNotEmpty;

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  Future<String> _fetchExpectedHash(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      var uri = Uri.parse(url);
      String? hash;
      for (var hop = 0; hop < 8; hop++) {
        final request = await client.openUrl('HEAD', uri);
        request.followRedirects = false;
        final response = await request.close();
        hash ??= response.headers.value('x-linked-etag');
        if (response.isRedirect) {
          final location = response.headers.value('location');
          await response.drain<void>();
          if (location == null) break;
          uri = uri.resolve(location);
          continue;
        }
        hash ??= response.headers.value('etag');
        await response.drain<void>();
        break;
      }
      return (hash ?? '').replaceAll('"', '').replaceFirst('W/', '').trim();
    } finally {
      client.close(force: true);
    }
  }

  /// يبدأ التنزيل بواسطة Android DownloadManager؛ لذلك لا يرتبط بعمر شاشة Flutter
  /// أو بقاء عملية التطبيق. يحتفظ مدير Android بالجزء المنزّل ويستأنف عند عودة الشبكة.
  Future<void> downloadAndActivate(BlousabAiTier tier) async {
    if (status.value == BlousabAiStatus.downloading) return;
    if (!tierHasSource(tier)) throw StateError('لم يُضبط مصدر تنزيل لهذا الحجم.');
    final prefs = await SharedPreferences.getInstance();
    _cancelRequested = false;
    progress.value = 0;
    progressText.value = 'جارٍ بدء التنزيل في الخلفية…';
    status.value = BlousabAiStatus.downloading;
    tierId = tier.id;
    try {
      final expectedHash = tier.sha256Hex.trim().isNotEmpty ? tier.sha256Hex.trim() : await _fetchExpectedHash(tier.downloadUrl);
      if (!_hex64.hasMatch(expectedHash)) throw const FormatException('تعذر الحصول على بصمة SHA-256 موثوقة من مصدر النموذج.');
      await prefs.setString(_kExpectedHash, expectedHash);
      final started = await _downloadChannel.invokeMapMethod<String, dynamic>('enqueue', {
        'url': tier.downloadUrl,
        'fileName': 'blousab_ai_${tier.id}.task.part',
      });
      if (started == null) throw StateError('لم يتمكن Android من بدء التنزيل.');
      _downloadId = (started['id'] as num).toInt();
      final path = started['path']?.toString() ?? '';
      if (path.isEmpty) throw StateError('تعذر تحديد مكان حفظ النموذج.');
      await prefs.setInt(_kDownloadId!, _downloadId!);
      await prefs.setString(_kDownloadPath, path);
      await prefs.setString(_kTier, tier.id);
      await prefs.setString(_kStatus, 'downloading');
      await _watchNativeDownload();
    } catch (_) {
      status.value = _downloadId == null ? BlousabAiStatus.notLoaded : BlousabAiStatus.downloading;
      rethrow;
    }
  }

  Future<void> _watchNativeDownload() async {
    if (_pollingDownload || _downloadId == null) return;
    _pollingDownload = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final tier = currentTier ?? blousabAiTiers.firstWhere((t) => t.id == (prefs.getString(_kTier) ?? 'light'), orElse: () => blousabAiTiers.first);
      final id = _downloadId!;
      final sourcePath = prefs.getString(_kDownloadPath) ?? '';
      while (!_cancelRequested) {
        final state = await _downloadChannel.invokeMapMethod<String, dynamic>('query', {'id': id});
        final label = state?['status']?.toString() ?? 'missing';
        final received = (state?['downloaded'] as num?)?.toInt() ?? 0;
        final total = (state?['total'] as num?)?.toInt() ?? 0;
        if (total > 0) progress.value = (received / total).clamp(0.0, 1.0).toDouble();
        progressText.value = label == 'paused'
            ? 'التنزيل متوقف مؤقتاً بانتظار اتصال الشبكة — سيُستأنف تلقائياً'
            : '${(received / 1048576).toStringAsFixed(1)} MB${total > 0 ? ' من ${(total / 1048576).toStringAsFixed(1)} MB' : ''}';
        if (label == 'complete') {
          final downloaded = File(sourcePath);
          if (!await downloaded.exists() || await downloaded.length() == 0) throw const FormatException('ملف النموذج غير مكتمل.');
          progressText.value = 'جارٍ التحقق من سلامة النموذج…';
          final digest = await sha256.bind(downloaded.openRead()).first;
          final expected = prefs.getString(_kExpectedHash) ?? tier.sha256Hex.trim();
          if (!_hex64.hasMatch(expected) || digest.toString().toLowerCase() != expected.toLowerCase()) {
            throw const FormatException('فشل التحقق من بصمة النموذج؛ لن يتم تفعيله.');
          }
          // لا نضغط ملف .task نفسه: صيغة النموذج مضغوطة/مهيأة أصلاً للمحرك،
          // وإعادة ضغطها قد تبطئ التنزيل وتضيف طبقة قد تضر بالتوافق.
          final target = await _targetFile(tier);
          final staging = File('${target.path}.verified');
          await downloaded.copy(staging.path);
          if (await target.exists()) await target.delete();
          await staging.rename(target.path);
          try { await downloaded.delete(); } catch (_) {}
          progressText.value = 'جارٍ تجهيز النموذج…';
          await _closeModel();
          tierId = tier.id;
          modelPath = target.path;
          await _activate();
          await prefs.setString(_kPath, modelPath);
          await prefs.setString(_kStatus, 'ready');
          await prefs.remove(_kDownloadId);
          await prefs.remove(_kDownloadPath);
          await prefs.remove(_kExpectedHash);
          _downloadId = null;
          progress.value = 1;
          progressText.value = 'اكتمل التنزيل والتحقق والتجهيز';
          status.value = BlousabAiStatus.ready;
          return;
        }
        if (label == 'failed' || label == 'missing') {
          final reason = state?['reason'];
          await prefs.remove(_kDownloadId);
          await prefs.remove(_kDownloadPath);
          await prefs.remove(_kExpectedHash);
          _downloadId = null;
          throw HttpException('تعذر تنزيل النموذج (الحالة: $label، الرمز: $reason). يمكنك إعادة المحاولة.');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (e) {
      if (e is FormatException && _downloadId != null) {
        try { await _downloadChannel.invokeMethod<bool>('remove', {'id': _downloadId}); } catch (_) {}
        await prefs.remove(_kDownloadId);
        await prefs.remove(_kDownloadPath);
        await prefs.remove(_kExpectedHash);
        _downloadId = null;
        status.value = BlousabAiStatus.notLoaded;
      } else {
        status.value = _downloadId == null ? BlousabAiStatus.notLoaded : BlousabAiStatus.downloading;
      }
      progressText.value = 'تعذر إكمال التنزيل: $e';
      rethrow;
    } finally {
      _pollingDownload = false;
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
    final id = _downloadId;
    if (id != null) {
      _downloadChannel.invokeMethod<bool>('remove', {'id': id});
      SharedPreferences.getInstance().then((prefs) async {
        await prefs.remove(_kDownloadId);
        await prefs.remove(_kDownloadPath);
        await prefs.remove(_kExpectedHash);
        await prefs.setString(_kStatus, 'notLoaded');
      });
    }
    status.value = BlousabAiStatus.notLoaded;
    progressText.value = 'تم إلغاء التنزيل';
  }

  // ------------------------------------------------------------ inference
  Future<void> _ensureGemma() async {
    if (_gemmaReady) return;
    await FlutterGemma.initialize(inferenceEngines: const [MediaPipeEngine()]);
    _gemmaReady = true;
  }

  Future<void> _activate() async {
    await _ensureGemma();
    await FlutterGemma.installModel(modelType: ModelType.qwen, fileType: ModelFileType.task)
        .fromFile(modelPath)
        .install();
    _activated = true;
  }

  Future<void> _ensureChat() async {
    if (_chat != null) return;
    if (!_activated) await _activate();
    _model ??= await FlutterGemma.getActiveModel(maxTokens: 1024, preferredBackend: PreferredBackend.cpu);
    _chat = await _model!.createChat(systemInstruction: _systemPrompt);
  }

  /// يبدأ محادثة جديدة (يُنسى السياق السابق داخل النموذج).
  Future<void> resetChat() async {
    try {
      await _chat?.session.close();
    } catch (_) {}
    _chat = null;
  }

  /// يولّد الرد تدريجيًا (كل عنصر في الـ Stream جزء جديد من النص).
  Stream<String> replyStream(String prompt) async* {
    try {
      await _ensureChat();
      await _chat!.addQueryChunk(Message.text(text: prompt, isUser: true));
      await for (final response in _chat!.generateChatResponseAsync()) {
        if (response is TextResponse) yield response.token;
      }
    } catch (e) {
      // سياق ممتلئ أو خطأ في المحرك: نبدأ جلسة جديدة في الرسالة التالية.
      await resetChat();
      rethrow;
    }
  }

  Future<void> _closeModel() async {
    await resetChat();
    try {
      await _model?.close();
    } catch (_) {}
    _model = null;
    _activated = false;
  }

  /// يحذف النموذج الحالي ويعيد المحادثة إلى حالة «غير محمّل».
  Future<void> deleteModel() async {
    await _closeModel();
    try {
      await FlutterGemma.clearActiveInferenceIdentity();
    } catch (_) {}
    if (modelPath.isNotEmpty) {
      try {
        final f = File(modelPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStatus, 'notLoaded');
    await prefs.remove(_kPath);
    await prefs.remove(_kTier);
    modelPath = '';
    tierId = '';
    status.value = BlousabAiStatus.notLoaded;
  }
}
