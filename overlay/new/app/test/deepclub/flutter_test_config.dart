import 'dart:async';

// Protocol and secure-storage tests do not need font setup. The UI behavior,
// geometry and explicit capture entrypoints load the shared real-font fixture
// themselves (DSH_TEST_FONT_DIR on macOS, distro Noto CJK on Linux).
Future<void> testExecutable(FutureOr<void> Function() testMain) async => testMain();
