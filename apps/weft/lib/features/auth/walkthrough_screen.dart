import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';
import '../../app/billing_providers.dart';
import '../../app/localisation.dart';
import '../../services/billing/entitlements.dart';

import '../bridges/bridges_screen.dart';
import '../settings/ai_screen.dart';
import '../settings/auto_reply_screen.dart';
import '../settings/models_screen.dart';
import '../settings/pro_screen.dart';
import '../todo/todo_screen.dart';
import 'matrix_server_sheet.dart';

/// The walkthrough after a first sign-in: what Sennit can do beyond showing
/// messages, one feature to a page, each with the way into setting it up.
///
/// [SetupScreen] before it asks for what a messenger cannot work without;
/// nothing here is needed, which is why every page can be passed and the
/// whole thing can be skipped from the first. The primary button opens the
/// feature's own settings screen on top of the walkthrough, so coming back
/// lands on the page that was left rather than in an inbox with the rest of
/// the tour gone.
///
/// A page for a Sennit Pro feature behaves as its settings row does: until Pro
/// is unlocked it carries the Pro mark, and its button leads to the Pro
/// screen instead of to settings that would do nothing.
class WalkthroughScreen extends ConsumerStatefulWidget {
  const WalkthroughScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<WalkthroughScreen> createState() => _WalkthroughScreenState();
}

class _WalkthroughScreenState extends ConsumerState<WalkthroughScreen> {
  int _step = 0;

  List<_WalkthroughStep> get _steps {
    final l10n = context.l10n;
    return [
      _WalkthroughStep(
        icon: Icons.waving_hand_outlined,
        title: l10n.tourWelcomeTitle,
        body: l10n.tourWelcomeBody,
        action: l10n.tourWelcomeAction,
      ),
      _WalkthroughStep(
        icon: Icons.hub_outlined,
        title: l10n.tourBridgesTitle,
        body: l10n.tourBridgesBody,
        action: l10n.tourBridgesAction,
        screen: (_) => const BridgesScreen(),
      ),
      _WalkthroughStep(
        icon: Icons.auto_awesome_outlined,
        title: l10n.tourAiTitle,
        body: l10n.tourAiBody,
        action: l10n.tourAiAction,
        feature: ProFeature.aiReplies,
        screen: (_) => const AiSettingsScreen(),
      ),
      _WalkthroughStep(
        icon: Icons.download_for_offline_outlined,
        title: l10n.tourModelsTitle,
        body: l10n.tourModelsBody,
        action: l10n.tourModelsAction,
        feature: ProFeature.semanticSearch,
        screen: (_) => const ModelsScreen(),
      ),
      _WalkthroughStep(
        icon: Icons.smart_toy_outlined,
        title: l10n.tourAutoReplyTitle,
        body: l10n.tourAutoReplyBody,
        action: l10n.tourAutoReplyAction,
        feature: ProFeature.aiReplies,
        screen: (_) => const AutoReplyScreen(),
      ),
      _WalkthroughStep(
        icon: Icons.checklist_rounded,
        title: l10n.tourTodoTitle,
        body: l10n.tourTodoBody,
        action: l10n.tourTodoAction,
        screen: (_) => const TodoScreen(),
      ),
    ];
  }

  void _next() {
    if (_step + 1 < _steps.length) {
      setState(() => _step += 1);
    } else {
      widget.onDone();
    }
  }

  void _open(WidgetBuilder screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: screen));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final steps = _steps;
    final step = steps[_step];
    final first = _step == 0;
    final last = _step == steps.length - 1;
    final pro = ref.watch(proControllerProvider);
    final locked = step.feature != null && !pro.unlocks(step.feature!);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(WeftSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The page's words scroll rather than the page: at the
                  // largest text sizes a body paragraph outgrows a phone, and
                  // the buttons under it have to stay where they are.
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: AnimatedSwitcher(
                          duration: WeftMotion.normal,
                          switchInCurve: WeftMotion.enter,
                          child: Column(
                            key: ValueKey(_step),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                step.icon,
                                size: 56,
                                color: context.colors.primary,
                              ),
                              const SizedBox(height: WeftSpace.xl),
                              if (locked) ...[
                                const ProBadge(),
                                const SizedBox(height: WeftSpace.sm),
                              ],
                              Text(
                                step.title,
                                textAlign: TextAlign.center,
                                style: context.text.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: WeftSpace.md),
                              Text(
                                step.body,
                                textAlign: TextAlign.center,
                                style: context.text.bodyMedium?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                  height: 1.4,
                                ),
                              ),
                              // The welcome page is where a first account has
                              // just been made on a server the user may not
                              // know the word for.
                              if (first) ...[
                                const SizedBox(height: WeftSpace.sm),
                                const MatrixServerInfoButton(),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: WeftSpace.lg),
                  // Dots say where in the flow this is; the label says it to
                  // someone who cannot see them.
                  Semantics(
                    label: l10n.tourProgress(_step + 1, steps.length),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < steps.length; i++)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _step
                                  ? context.colors.primary
                                  : context.colors.surfaceContainerHighest,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: WeftSpace.xl),
                  FilledButton(
                    onPressed: switch (step.screen) {
                      _ when locked => () => pushProScreen(context),
                      final screen? => () => _open(screen),
                      null => _next,
                    },
                    child: Text(step.action),
                  ),
                  const SizedBox(height: WeftSpace.sm),
                  TextButton(
                    onPressed: first ? widget.onDone : _next,
                    child: Text(
                      first
                          ? l10n.tourSkip
                          : last
                          ? l10n.commonDone
                          : l10n.tourNext,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WalkthroughStep {
  const _WalkthroughStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    this.feature,
    this.screen,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;

  /// The Sennit Pro feature this page is about, when it is one.
  final ProFeature? feature;

  /// The screen the primary button opens. Null on a page with nothing to set
  /// up, where the button moves on instead.
  final WidgetBuilder? screen;
}
