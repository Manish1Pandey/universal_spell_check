import 'worker.dart';

/// Creates the web worker: Dart on the web has no isolates, so the engine
/// runs on the main thread and yields to the event loop while it works.
Future<HunspellWorker> spawnHunspellWorker(
  String aff,
  String dic, {
  required bool useIsolate,
}) {
  return InlineHunspellWorker.create(aff, dic, cooperative: true);
}
