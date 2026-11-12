# DeepClub Mobile adaptation

This is the DeepClub-owned adaptation repository, not ccch1mneyyy/dsh-Go. Follow meyaomiao/deepclub#444 and this repository's execution issues. Work on one `codex/issue-N-*` branch and deliver a Draft PR with actual test evidence; do not merge, deploy, publish releases or contact upstream without the user's authorization. Do not change the user's model or reasoning selection.

The pinned upstream source is reconstructed by `scripts/prepare.py`; changes live in the text patch, `overlay/new/`, and `overlay/replace/` with generated input/output digests. Make changes in an isolated prepared checkout, then use `scripts/capture-overlay.py` to refresh the adaptation. Never patch an unpinned upstream silently. Preserve upstream licenses and required notices; excluded upstream brand/art and Phase-derived phone-control code must not appear in an APK.

Read upstream AGENTS.md, CONTRIBUTING.md and docs/architecture.md for source conventions. Upstream external-PR policy applies to submissions to upstream, not this owner's repository. The authorized DeepClub account design stores session credentials in Android secure storage and the model key in the local DSH credential store; never log, commit or export credentials. Keep native cleanup and Dart logout behavior aligned.

Use Flutter 3.47.7 / Dart 3.13.5 and the pinned lockfile. UI copy goes in paired ARB source files, then run upstream l10n_merge.py; never hand edit generated files. Keep write scopes disjoint when using teammates. Run relevant Dart/Flutter/Node/Kotlin tests, formatting and analysis, and distinguish simulated, emulator and real-device evidence. Building an APK does not mean it has passed production acceptance.
