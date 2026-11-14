# P0 DeepClub Android UI evidence

This fixture renders the production Flutter widgets with synthetic account/runtime provider inputs. It does not reproduce the screens as static mock UI. There are no real credentials, accounts, devices, or network services in the captures.

## Implementation

- [deepclub_gate.dart](../../lib/ui/onboarding/deepclub_gate.dart): account/runtime/settings/host listeners request preparation. `build` only renders. Runtime extraction continues alongside login; the login footer contains text/percentage only. Signed-in preparation uses one ordered stage card with at most one progress indicator and one failure retry. The account action is in the overflow menu; the old remote-settings action is absent from preparation.
- [deepclub_loading.dart](../../lib/ui/onboarding/deepclub_loading.dart): a 300 ms delay and 500 ms minimum visible interval. A completed preparation shows the real static completed stage list for the remaining interval, then hands off to the home widget. Reduced motion replaces indeterminate animation with a static status. Timers only control presentation and never request work.
- [deepclub_account_page.dart](../../lib/ui/settings/deepclub_account_page.dart): production account page/login panel/settings overview using `AppPage`, `OverviewCard`, `SheetGroup`, `SettingsTile`, `AppIcons` and `AppSpace`. Refresh reserves its spinner slot and keeps unrelated web navigation enabled. A quick account read shows no skeleton; a slower read holds its skeleton for the minimum interval.
- [account_page.dart](../../lib/deepclub/account_page.dart) now contains only the localized error mapping. UI implementation moved into `ui/settings/` to preserve the existing import-direction rule; callers received import-only changes. No architecture allowlist entries were added.
- Existing account service, local-engine affinity, model selection, thinking-depth and configuration synchronization code is unchanged. Native credential cleanup is owned by the integrating lead.
- Paired `lib/l10n/parts/deepclub_*.arb` inputs use the app name **DeepClub**. Preparation asks the user to keep the app open; it does not promise an unimplemented completion notification.

## Real-component fixture and captures

[ui_fixture.dart](ui_fixture.dart) supplies synthetic provider state to the production `DeepClubGateView`, `DeepClubLoginPanel`, `DeepClubPreparationSteps`, and `DeepClubAccountPage`. [ui_capture.dart](ui_capture.dart) is an explicit Flutter test entrypoint rather than a default `_test.dart` suite, because pixel baselines are platform specific. The normal behavior and geometry tests run in the default `test/deepclub` suite.

Scenes: signed out, waiting for browser authorization, extracting (45%), starting, syncing, completed, runtime failure, sync failure, revoked, authorization expired, cleanup failed, cleanup in progress (`clearing`), account ready, account refreshing, account offline, and zero balance.

The completed capture starts with the actual sync stage, waits 300 ms, publishes `engineReady`, and captures the real completed stage card before the minimum interval ends. It is not an image of the homepage. Homepage/emulator/device evidence is the lead's integration responsibility.

Matrix: light/dark × Chinese/English × 360×800 @1.0/1.3/2.0 and 840×800 @1.0 × 16 scenes = 256 captures. Task-8 adds only the 16 `clearing` captures; the original 240 PNGs are unchanged. Files are under `goldens/<operating-system>/`.

Use Flutter 3.47.7 / Dart 3.13.5 and real Noto CJK Light, Regular and Bold TTC files. The local font directory for this execution is `app/build/deepclub-test-fonts` (not a source deliverable). Font source: [Noto Sans CJK 2.004](https://github.com/notofonts/noto-cjk/tree/Sans2.004/Sans/OTC). SHA-256:

- Light: `872def437cf8b9c41bf1736da891e34a8c25b764c0c4a51418d3745570660f42`
- Regular: `b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a`
- Bold: `faa5f3656a78b2e2d450d27fe8382c778bc2b6bb5ea29c986664a6a435056ceb`

From `app/`, with `FLUTTER_ROOT` pointing to the SDK and `DSH_TEST_FONT_DIR` to those fonts:

```bash
flutter pub get --enforce-lockfile
flutter test --no-pub --concurrency=2 test/deepclub test/icons/app_icons_test.dart test/arch/import_direction_test.dart --reporter expanded
flutter test --no-pub --update-goldens --dart-define=DEEPCLUB_FULL_MATRIX=true test/deepclub/ui_capture.dart --reporter expanded
flutter test --no-pub --dart-define=DEEPCLUB_FULL_MATRIX=true test/deepclub/ui_capture.dart --reporter expanded
python3 tool/l10n_merge.py --check
```

For the smaller Chinese 360×800 @1.0 light/dark set, omit `DEEPCLUB_FULL_MATRIX`. Reuse `DeepClubUiFixture(scene).app(...)` to inspect a particular state, theme, locale or text scale.

## Initial task-1 validation

Executed on macOS with Flutter 3.47.7 / Dart 3.13.5 and the font inputs above:

| Check | Actual result |
|---|---|
| `flutter pub get --enforce-lockfile` | Passed, exit 0 |
| `FLUTTER=<SDK>/bin/flutter python3 app/tool/l10n_merge.py` from source root | Passed: 72 parts / 7384 keys; generated l10n output |
| `python3 tool/l10n_merge.py --check` from app | Passed: 72 parts / 7384 keys |
| `dart format --output=none --set-exit-if-changed` on the 10 changed UI/fixture/icon files | Passed: 10 files, 0 changed |
| `dart analyze` on the changed UI, fixture and icon-test files | Passed: No issues found |
| `flutter test --no-pub --concurrency=2 test/deepclub test/deepclub_surface test/icons/app_icons_test.dart test/arch/import_direction_test.dart --reporter expanded` | 91 passed / 1 failed. The only failure was an existing hard-coded Chinese copy assertion using 账户; updated that word to the required 账号, then reran its complete file as below. All 71 deepclub tests, 4 AppIcons tests, 3 architecture tests, and the other surface checks passed. |
| `flutter test --no-pub test/deepclub_surface/surface_entries_test.dart --reporter expanded` after the copy correction | Passed: 11/11, including model preservation and account-route checks |
| Explicit full capture with `--update-goldens --dart-define=DEEPCLUB_FULL_MATRIX=true` | Passed: 240/240; after visual cleanup, updated only the 32 cleanup/accountOffline captures |
| Explicit full capture without `--update-goldens`, with `--dart-define=DEEPCLUB_FULL_MATRIX=true` | Passed: 240/240 normal pixel comparisons against the final macOS baselines |
| Complete AppIcons generation then normal comparison | Passed: all 4 tests, including both glyph sheets, not a filtered subset |
| Scoped `git diff --check` | Passed; downloaded fonts and failure PNGs are ignored build/test artifacts |

Behavior evidence includes the exact 299/300 ms and 499/500 ms boundaries, a 100 ms account read with no skeleton flash, completion handoff, static reduced-motion states, percentage semantics, single-progress/single-retry limits, no retry during normal preparation, parallel login/install, no build-driven duplicate installation/start/sync, preservation of start settings, keyboard reachability, and fixed card/row geometry. The existing service tests also verify unchanged-revision behavior, user model/thinking choices, custom routes, and local-engine affinity.

Visual inspection covered final light/dark extraction, sync, completion and account-refresh views; English @1.3 login/browser; @2.0 runtime failure; 840-wide completion; and the final cleanup/accountOffline variants. The two macOS glyph sheets were also opened and compared to the old sheets: roles and layout are intact, with the intentional neutral DeepClub theme and platform rasterization differences. The first review caught duplicate cleanup text and an account-error color incorrectly applied to a ready engine; both were corrected and the affected captures regenerated before the full comparison.

### Integration handoff

The icon test selects `goldens/${Platform.operatingSystem}/glyph_sheet_<mode>.png`. The original shared upstream images are retained. The macOS pair is final and verified. The Linux pair comes from genuine Ubuntu 24.04 / Flutter 3.47.7 output in [CI run 43571309408](https://github.com/meyaomiao/deepclub-mobile/actions/runs/43571309408): its only two failures were the expected legacy-color glyph baselines. The lead opened both actual images, checked all glyphs and layout against the old sheets, and adopted the neutral DeepClub theme without editing pixels. Light SHA-256: `e2abd6a260b20edc5e1497a3bc262ad57f1853d35684957bb8177b39d7baf7df`; dark: `d79ed074d203e5ced67c521772c752d188261c6ef8b4dc75ebfb84aa5eb3c179`. The subsequent normal CI comparison is recorded on mobile#5 / PR #6; no test or guard is skipped.

A simultaneous Flutter test/capture launch initially collided in `build/native_assets/macos/objective_c.dylib`; all final Flutter commands were run sequentially. Keep commands in the same checkout serialized. Earlier local test-only issues (unsupported matcher, semantics-handle cleanup, and exact floating-point comparison) were corrected before final regression runs.

These are desktop widget and synthetic service checks. Browser callbacks, native runtime, actual device revocation, emulator screenshots, physical-device/ROM behavior, APK acceptance, and Linux CI remain the lead's integration work. This task did not capture an adaptation overlay, commit, push, create a PR, or modify another workspace.

## Task-8: normal sign-out cleanup

The lead's actual emulator sign-out exposed a missing UI state: `cleanupBlocked=true, busy=true, error=null` was shown as a cleanup failure with a disabled Retry button, even though the account service was still clearing local sign-in data normally. The production change is limited to [DeepClubLoginPanel](../../lib/ui/settings/deepclub_account_page.dart):

- Clearing displays the neutral paired string `deepClubClearing` (正在清除本机登录信息 / Clearing sign-in data on this phone), with one reserved icon slot. The quiet spinner appears after 300 ms; reduced motion uses a static status. There is no failure copy or Retry button while clearing.
- A successful cleanup holds an already-visible clearing presentation for its remaining 500 ms minimum, then restores the sign-in controls. A completion within 300 ms never flashes a spinner.
- Only `cleanupBlocked && !busy && error != null` exposes failure copy and an enabled Retry. A genuine failure takes over immediately; starting another cleanup resets the delay, including when an old error is still present in a busy state.
- Account service, account controller and model-configuration implementation were byte-compared with the previously captured overlay and are unchanged. Icon tests and baselines were not modified in task-8.

[ui_fixture.dart](ui_fixture.dart) adds the exact in-flight cleanup state as `clearing`, rendering the real account page. It contributes 16 new macOS captures. The previous 240 PNGs were byte-compared to the captured overlay and are unchanged. Final light/dark images were opened, including English at 2.0 text scale and the 840-wide layout; all show neutral status without failure/retry controls.

Focused macOS verification (Flutter 3.47.7 / Dart 3.13.5, fonts/environment above):

| Command / check | Actual result |
|---|---|
| `flutter test --no-pub --concurrency=2 test/deepclub/ui_behavior_test.dart test/deepclub/ui_geometry_test.dart --reporter expanded` | 50/50 passed; account and gate cleanup transitions, exact delay/minimum thresholds, fast success, failed/restarted cleanup and reduced motion included |
| `flutter test --no-pub --update-goldens --dart-define=DEEPCLUB_FULL_MATRIX=true test/deepclub/ui_capture.dart --name '^clearing ' --reporter expanded` | 16/16 passed; only the new scene was generated |
| `flutter test --no-pub --dart-define=DEEPCLUB_FULL_MATRIX=true test/deepclub/ui_capture.dart --name '^(clearing\|cleanup) ' --reporter expanded` | 32/32 normal comparisons passed, including the unchanged failure scene |
| `dart analyze lib/ui/settings/deepclub_account_page.dart test/deepclub/ui_fixture.dart test/deepclub/ui_behavior_test.dart` | No issues found |
| l10n merge/generation and `python3 tool/l10n_merge.py --check` | 72 parts / 7385 keys; passed |
| Targeted format check | 3 UI/fixture files, 0 changes |

The same emulator acceptance also found that the old synthetic provider fixture used the unsupported `supportsToolChoice` option. Per the lead's packaged-runtime contract check, [support.dart](support.dart) now uses the canonical `compat` object `{'forceAdaptiveThinking': true, 'supportsStrictTools': true}`. [agent_config_test.dart](agent_config_test.dart) continues to assert that both supplied compatibility fields survive provider merging. This changes test data only; product configuration logic and screenshot inputs are unaffected. The focused `flutter test --no-pub test/deepclub/agent_config_test.dart --reporter expanded` passed **6/6**. No unrelated full suites or icon baselines were regenerated.

The lead must capture the updated overlay, rebuild, and verify this new UI on the emulator before final integration delivery.
