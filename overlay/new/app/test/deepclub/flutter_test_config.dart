import 'dart:async';

// These tests exercise protocol, secure-storage and provider wiring. The binding
// test does not render text; none measures font geometry or compares goldens.
// Keep them runnable on macOS without the upstream Linux-only font fixture.
Future<void> testExecutable(FutureOr<void> Function() testMain) async => testMain();
