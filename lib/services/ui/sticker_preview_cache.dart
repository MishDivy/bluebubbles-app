import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:bluebubbles/services/network/api/attachment_api.dart';
import 'package:dio/dio.dart';

class StickerPreviewLease {
  final Future<Uint8List> future;
  final void Function() _release;
  bool _released = false;
  StickerPreviewLease(this.future, this._release);
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _PreviewJob {
  final token = CancelToken();
  late Future<Uint8List> future;
  int consumers = 0;
  final ready = Completer<void>();
  bool started = false;
}

/// A bounded display cache. Failures require an explicit retry.
class StickerPreviewCache {
  final _images = <String, Uint8List>{};
  final _failures = <String, (Object, DateTime)>{};
  final _jobs = <String, _PreviewJob>{};
  final _pending = Queue<_PreviewJob>();
  int _active = 0;
  int _bytes = 0;
  final DateTime Function() _now;
  StickerPreviewCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  StickerPreviewLease acquire(String origin, String guid, AttachmentApi api, {bool retry = false}) {
    final key = 'native-sticker-preview-v1:$origin:$guid';
    if (retry) {
      _failures.remove(key);
      final old = _images.remove(key);
      if (old != null) _bytes -= old.length;
    }
    final cached = _images.remove(key);
    if (cached != null) {
      _images[key] = cached;
      return StickerPreviewLease(Future.value(cached), () {});
    }
    final failure = _failures[key];
    if (failure != null) {
      if (_now().difference(failure.$2) < const Duration(minutes: 5)) {
        return StickerPreviewLease(Future.error(failure.$1), () {});
      }
      _failures.remove(key);
    }
    var job = _jobs[key];
    if (job?.token.isCancelled == true) {
      return StickerPreviewLease(
        Future.error(StateError('The previous preview is closing. Retry in a moment.')),
        () {},
      );
    }
    if (job == null) {
      if (_jobs.length >= 12) {
        return StickerPreviewLease(Future.error(StateError('Sticker previews are busy. Retry in a moment.')), () {});
      }
      job = _PreviewJob();
      _jobs[key] = job;
      final current = job;
      job.future = () async {
        try {
          await current.ready.future;
          if (current.token.isCancelled) throw StateError('Sticker preview was canceled.');
          final response = await api.stickerPreview(guid, cancelToken: current.token, expectedOrigin: origin);
          final data = response.data as Uint8List;
          if (current.token.isCancelled) throw StateError('Sticker preview was canceled.');
          while (_images.isNotEmpty && (_bytes + data.length > 32 * 1024 * 1024 || _images.length >= 16)) {
            _bytes -= _images.remove(_images.keys.first)!.length;
          }
          _images[key] = data;
          _bytes += data.length;
          return data;
        } catch (error) {
          if (current.consumers > 0) {
            while (_failures.length >= 64) {
              _failures.remove(_failures.keys.first);
            }
            _failures[key] = (error, _now());
          }
          rethrow;
        } finally {
          if (identical(_jobs[key], current)) _jobs.remove(key);
          if (current.started) _active--;
          _pump();
        }
      }();
      _pending.add(job);
      _pump();
    }
    job.consumers++;
    final current = job;
    return StickerPreviewLease(job.future, () {
      current.consumers--;
      if (current.consumers == 0 && identical(_jobs[key], current)) {
        current.token.cancel('Sticker preview is no longer visible');
        if (!current.started) {
          _pending.remove(current);
          current.ready.complete();
        }
      }
    });
  }

  void _pump() {
    while (_active < 2 && _pending.isNotEmpty) {
      final job = _pending.removeFirst();
      job.started = true;
      _active++;
      job.ready.complete();
    }
  }
}
