import 'dart:async';
import 'dart:isolate';

import '../models.dart';
import 'dictionary.dart';
import 'hunspell.dart';
import 'text_checker.dart';
import 'worker.dart';

/// Creates a worker on native platforms: a long-lived background isolate
/// when [useIsolate] is true, otherwise an inline worker.
Future<HunspellWorker> spawnHunspellWorker(
  String aff,
  String dic, {
  required bool useIsolate,
}) {
  if (!useIsolate) {
    return InlineHunspellWorker.create(aff, dic, cooperative: false);
  }
  return _IsolateHunspellWorker.spawn(aff, dic);
}

enum _Op { checkText, checkWord, suggest }

class _IsolateHunspellWorker implements HunspellWorker {
  _IsolateHunspellWorker._(
    this._isolate,
    this._fromIsolate,
    this._toIsolate,
    this._errorPort,
    this._exitPort,
    this.wordChars,
  );

  static Future<_IsolateHunspellWorker> spawn(String aff, String dic) async {
    final ReceivePort fromIsolate = ReceivePort();
    final ReceivePort errorPort = ReceivePort();
    final ReceivePort exitPort = ReceivePort();
    final Isolate isolate = await Isolate.spawn<(SendPort, String, String)>(
      _isolateMain,
      (fromIsolate.sendPort, aff, dic),
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
      debugName: 'universal_spell_check.hunspell',
    );
    final Completer<(SendPort, String)> ready = Completer<(SendPort, String)>();
    _IsolateHunspellWorker? worker;
    bool started = false;
    fromIsolate.listen((Object? message) {
      if (!started) {
        started = true;
        if (message is (SendPort, String)) {
          ready.complete(message);
        } else {
          ready.completeError(
            HunspellFormatException('Dictionary failed to load: $message'),
          );
        }
        return;
      }
      worker?._onResponse(message);
    });
    void fail(Object error) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Hunspell isolate failed: $error'));
      } else {
        worker?._failAll(StateError('Hunspell isolate failed: $error'));
      }
    }

    errorPort.listen((Object? e) => fail(e is List ? e.first as Object : e!));
    exitPort.listen((Object? _) => fail('isolate exited'));
    try {
      final (SendPort toIsolate, String wordChars) = await ready.future;
      final _IsolateHunspellWorker created = _IsolateHunspellWorker._(
        isolate,
        fromIsolate,
        toIsolate,
        errorPort,
        exitPort,
        wordChars,
      );
      worker = created;
      return created;
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      fromIsolate.close();
      errorPort.close();
      exitPort.close();
      rethrow;
    }
  }

  final Isolate _isolate;
  final ReceivePort _fromIsolate;
  final SendPort _toIsolate;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool _disposed = false;

  @override
  final String wordChars;

  void _onResponse(Object? message) {
    if (message is! (int, bool, Object?)) return;
    final (int id, bool ok, Object? payload) = message;
    final Completer<Object?>? c = _pending.remove(id);
    if (c == null) return;
    if (ok) {
      c.complete(payload);
    } else {
      c.completeError(StateError('Hunspell worker error: $payload'));
    }
  }

  void _failAll(Object error) {
    final List<Completer<Object?>> all = _pending.values.toList();
    _pending.clear();
    for (final Completer<Object?> c in all) {
      c.completeError(error);
    }
  }

  Future<Object?> _send(_Op op, Object? args) {
    if (_disposed) {
      return Future<Object?>.error(StateError('HunspellWorker was disposed'));
    }
    final int id = _nextId++;
    final Completer<Object?> c = Completer<Object?>();
    _pending[id] = c;
    _toIsolate.send((id, op.index, args));
    return c.future;
  }

  @override
  Future<List<SpellCheckRange>> checkText(
    String text,
    int maxSuggestions,
  ) async {
    final Object? r = await _send(_Op.checkText, (text, maxSuggestions));
    return (r! as List<Object?>).cast<SpellCheckRange>();
  }

  @override
  Future<bool> checkWord(String word) async {
    return (await _send(_Op.checkWord, word))! as bool;
  }

  @override
  Future<List<String>> suggest(String word, int max) async {
    final Object? r = await _send(_Op.suggest, (word, max));
    return (r! as List<Object?>).cast<String>();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failAll(StateError('HunspellWorker was disposed'));
    _isolate.kill(priority: Isolate.immediate);
    _fromIsolate.close();
    _errorPort.close();
    _exitPort.close();
  }
}

void _isolateMain((SendPort, String, String) args) {
  final (SendPort reply, String aff, String dic) = args;
  final HunspellTextChecker checker;
  try {
    checker = HunspellTextChecker(Hunspell(HunspellDictionary.parse(aff, dic)));
  } catch (e) {
    reply.send('$e');
    return;
  }
  final ReceivePort requests = ReceivePort();
  reply.send((requests.sendPort, checker.dictionary.wordChars));
  requests.listen((Object? message) {
    if (message is! (int, int, Object?)) return;
    final (int id, int op, Object? a) = message;
    try {
      final Object result = switch (_Op.values[op]) {
        _Op.checkText => () {
          final (String text, int max) = a! as (String, int);
          return checker.checkText(text, maxSuggestions: max);
        }(),
        _Op.checkWord => checker.hunspell.check(a! as String),
        _Op.suggest => () {
          final (String word, int max) = a! as (String, int);
          return checker.suggest(word, max);
        }(),
      };
      reply.send((id, true, result));
    } catch (e) {
      reply.send((id, false, '$e'));
    }
  });
}
