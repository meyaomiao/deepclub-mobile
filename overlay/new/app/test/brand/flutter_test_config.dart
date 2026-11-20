// These contract tests parse site metadata and do not render text or widgets.
// Keep them independent of the upstream Linux-only golden font fixture.
import 'dart:async';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
