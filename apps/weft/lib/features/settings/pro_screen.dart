import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/billing_providers.dart';
import '../../app/localisation.dart';
import '../../services/billing/billing_store.dart';
import '../../services/billing/entitlements.dart';
import '../../services/billing/license_client.dart';

/// Opens [ProScreen].
void pushProScreen(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const ProScreen()));
}

/// The small "Pro" mark a locked settings row carries instead of its chevron.
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.sm,
        vertical: WeftSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(WeftSpace.sm),
      ),
      child: Text(
        context.l10n.proBadge,
        style: context.text.labelSmall?.copyWith(
          color: colors.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// What Sennit Pro unlocks, what it costs, and the buttons to buy or restore.
///
/// Prices come from the store, already in the user's currency; nothing here
/// knows an amount. A build that does not charge never links here, but the
/// screen still reads sensibly if it is opened anyway: it says Pro is on.
class ProScreen extends ConsumerStatefulWidget {
  const ProScreen({super.key});

  @override
  ConsumerState<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends ConsumerState<ProScreen> {
  late Future<List<StoreOffer>> _offers = _load();

  /// Set from the tap until the store answers, so a second tap cannot open a
  /// second purchase sheet before the first one has reported anything.
  bool _opening = false;

  Future<List<StoreOffer>> _load() async {
    try {
      return await ref.read(proControllerProvider.notifier).offers();
    } on Object catch (error) {
      debugPrint('weft: billing: could not load offers: $error');
      return const [];
    }
  }

  Future<void> _buy(StoreOffer offer) async {
    if (_opening) return;
    setState(() => _opening = true);
    var opened = false;
    try {
      opened = await ref
          .read(proControllerProvider.notifier)
          .buy(offer.productId);
    } on Object catch (error) {
      // StoreKit refuses a second purchase while one is in flight, and Play
      // an item already owned; both arrive as exceptions, not as events.
      debugPrint('weft: billing: buy failed: $error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    if (!opened && mounted) {
      showWeftMessage(context, context.l10n.proStoreUnavailable);
    }
  }

  Future<void> _restore() async {
    try {
      await ref.read(proControllerProvider.notifier).restore();
    } on Object catch (error) {
      debugPrint('weft: billing: restore failed: $error');
      if (mounted) showWeftMessage(context, context.l10n.proStoreUnavailable);
      return;
    }
    if (mounted) showWeftMessage(context, context.l10n.proRestoreRequested);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(proControllerProvider);
    final checkout = ref.watch(proCheckoutProvider);
    final ownership = status.owned() ? status.ownership : null;

    return Scaffold(
      appBar: WeftAppBar(title: Text(l10n.proTitle)),
      body: WeftReadingPane(
        child: ListView(
          padding: const EdgeInsets.all(WeftSpace.lg),
          children: [
            Text(l10n.proIntro, style: context.text.bodyLarge),
            const SizedBox(height: WeftSpace.md),
            for (final (icon, label) in [
              (Icons.smart_toy_outlined, l10n.proFeatureAi),
              (Icons.manage_search_rounded, l10n.proFeatureSearch),
              (Icons.graphic_eq_rounded, l10n.proFeatureTranscription),
              (Icons.terminal_rounded, l10n.proFeatureMcp),
              (Icons.home_outlined, l10n.proFeatureIntegrations),
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon),
                title: Text(label),
              ),
            const SizedBox(height: WeftSpace.lg),
            if (ownership != null)
              _Owned(ownership)
            else if (!status.charges)
              Text(l10n.proIncluded, style: context.text.titleMedium)
            else if (status.sellsByLicense)
              const _LicenseForm()
            else
              FutureBuilder<List<StoreOffer>>(
                future: _offers,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final offers = snapshot.data ?? const [];
                  if (offers.isEmpty) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.proStoreUnavailable),
                        TextButton(
                          onPressed: () => setState(() => _offers = _load()),
                          child: Text(l10n.proTryAgain),
                        ),
                      ],
                    );
                  }
                  final busy =
                      _opening || checkout.phase == CheckoutPhase.pending;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final offer in offers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: WeftSpace.sm),
                          child: _OfferButton(
                            offer: offer,
                            onPressed: busy ? null : () => _buy(offer),
                          ),
                        ),
                      if (offers.any(
                        (o) =>
                            ProProduct.byId(o.productId)?.kind ==
                            ProProductKind.subscription,
                      ))
                        Text(
                          l10n.proSubscriptionNote,
                          style: context.text.bodySmall,
                        ),
                    ],
                  );
                },
              ),
            if (checkout.phase == CheckoutPhase.pending) ...[
              const SizedBox(height: WeftSpace.md),
              Text(l10n.proPending),
            ],
            if (checkout.phase == CheckoutPhase.failed) ...[
              const SizedBox(height: WeftSpace.md),
              Text(
                l10n.proFailed(checkout.error ?? ''),
                style: TextStyle(color: context.colors.error),
              ),
            ],
            if (status.sellsInStore) ...[
              const SizedBox(height: WeftSpace.lg),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _restore,
                  child: Text(l10n.proRestore),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// How a direct build sells Pro: a button to the checkout page, and a field
/// for the licence key that arrives by email afterwards.
class _LicenseForm extends ConsumerStatefulWidget {
  const _LicenseForm();

  @override
  ConsumerState<_LicenseForm> createState() => _LicenseFormState();
}

class _LicenseFormState extends ConsumerState<_LicenseForm> {
  final _key = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _buy(Uri checkout) async {
    var opened = false;
    try {
      opened = await launchUrl(checkout, mode: LaunchMode.externalApplication);
    } on Object catch (error) {
      debugPrint('weft: billing: could not open the checkout: $error');
    }
    if (!opened && mounted) {
      showWeftMessage(context, context.l10n.proStoreUnavailable);
    }
  }

  Future<void> _activate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final verdict = await ref
        .read(proControllerProvider.notifier)
        .activateLicense(_key.text);
    if (!mounted) return;
    final l10n = context.l10n;
    setState(() {
      _checking = false;
      _error = switch (verdict) {
        LicenseVerdict.valid => null,
        LicenseVerdict.invalid => l10n.proLicenseInvalid,
        LicenseVerdict.unreachable => l10n.proLicenseUnreachable,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final checkout = ref.watch(licenseCheckoutProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (checkout != null) ...[
          FilledButton(
            onPressed: () => _buy(checkout),
            child: Text(l10n.proBuyDirect),
          ),
          const SizedBox(height: WeftSpace.sm),
          Text(l10n.proLicenseNote, style: context.text.bodySmall),
          const SizedBox(height: WeftSpace.lg),
        ],
        TextField(
          controller: _key,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: l10n.proLicenseLabel,
            // l10n-ignore: the shape of a licence key, not prose.
            hintText: 'BRAID-XXXXX-XXXXX-XXXXX-XXXXX',
            errorText: _error,
          ),
          onSubmitted: (_) => _activate(),
        ),
        const SizedBox(height: WeftSpace.sm),
        OutlinedButton(
          onPressed: _checking ? null : _activate,
          child: Text(l10n.proLicenseActivate),
        ),
      ],
    );
  }
}

class _OfferButton extends StatelessWidget {
  const _OfferButton({required this.offer, required this.onPressed});

  final StoreOffer offer;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final kind = ProProduct.byId(offer.productId)?.kind;
    final label = switch (kind) {
      ProProductKind.subscription => l10n.proBuyMonthly(offer.price),
      _ => l10n.proBuyLifetime(offer.price),
    };
    return kind == ProProductKind.lifetime
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label));
  }
}

class _Owned extends StatelessWidget {
  const _Owned(this.ownership);

  final ProOwnership ownership;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Text(
      ownership.product?.kind == ProProductKind.subscription
          ? l10n.proOwnedMonthly
          : l10n.proOwnedLifetime,
      style: context.text.titleMedium,
    );
  }
}
