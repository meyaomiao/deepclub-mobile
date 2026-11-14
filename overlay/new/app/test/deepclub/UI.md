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

Scenes: signed out, waiting for browser authorization, extracting (45%), starting, syncing, completed, runtime failure, sync failure, revoked, authorization expired, cleanup blocked, account ready, account refreshing, account offline, and zero balance.

The completed capture starts with the actual sync stage, waits 300 ms, publishes `engineReady`, and captures the real completed stage card before the minimum interval ends. It is not an image of the homepage. Homepage/emulator/device evidence is the lead's integration responsibility.

Matrix: light/dark × Chinese/English × 360×800 @1.0/1.3/2.0 and 840×800 @1.0 × 15 scenes = 240 captures. Files are under `goldens/<operating-system>/`.

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

## Validation status

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

The icon test now selects `goldens/${Platform.operatingSystem}/glyph_sheet_<mode>.png`. The original shared upstream images are retained. The macOS pair is final and verified. **The Linux pair currently contains temporary copies of the old shared upstream baselines, as requested by the lead, so Ubuntu CI can produce its actual diff PNGs. These are not approved Linux baselines.** The lead must replace them with genuine Ubuntu output, review both images, and rerun the unfiltered AppIcons test and CI. No test or guard is skipped.

A simultaneous Flutter test/capture launch initially collided in `build/native_assets/macos/objective_c.dylib`; all final Flutter commands were run sequentially. Keep commands in the same checkout serialized. Earlier local test-only issues (unsupported matcher, semantics-handle cleanup, and exact floating-point comparison) were corrected before final regression runs.

These are desktop widget and synthetic service checks. Browser callbacks, native runtime, actual device revocation, emulator screenshots, physical-device/ROM behavior, APK acceptance, and Linux CI remain the lead's integration work. This task did not capture an adaptation overlay, commit, push, create a PR, or modify another workspace.
