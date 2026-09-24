import 'package:cubechat/features/moderation/data/terms_controller.dart';

/// Skips the real Hive read and reports the rules as already agreed to.
///
/// The terms gate this task adds sits in front of the whole app and, before
/// its own accepted-version read off disk resolves, shows a blank screen — so
/// every widget test that pumps `CubechatApp` whole and expects to find its
/// own screen immediately needs `termsControllerProvider` overridden with
/// this, or it finds nothing but blank at `pumpWidget` and a "the app is
/// gated" surprise on every pump after. `terms_gate_test.dart` covers the
/// gate itself; these tests are not testing it and should not have to know it
/// exists.
class AcceptedTermsController extends TermsController {
  @override
  int build() => currentTermsVersion;
}

final acceptedTermsOverride =
    termsControllerProvider.overrideWith(AcceptedTermsController.new);
