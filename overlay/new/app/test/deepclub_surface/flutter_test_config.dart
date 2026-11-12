import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart' show tipStart;
import 'package:dsh_app/ui_config/ui_config_state.dart';

import '../support/quiet_performance.dart';

// These are routing, request-boundary and local-export behavior tests. They do
// not compare goldens or measure glyph geometry, so they need no OS font files.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The bundled Latin face avoids Ahem's full-em ASCII overflowing brand text.
  // This is a behavioral fixture, not an assertion about system typography.
  final latin = ByteData.sublistView(File('assets/fonts/JetBrainsMono-Regular.ttf').readAsBytesSync());
  for (final family in ['Roboto', 'JetBrainsMono']) {
    final loader = FontLoader(family)..addFont(Future.value(latin));
    await loader.load();
  }
  PetSheets.enabled = false;
  tipStart = (_) => 0;
  PerformanceChannel.create = QuietPerformanceChannel.new;
  defaultUiConfigSourceBuilder = (_, _) => null;
  AppLanguageController.initial = AppLanguage.zh;
  AppLocale.use(AppLocale.zhCN);
  await testMain();
}
