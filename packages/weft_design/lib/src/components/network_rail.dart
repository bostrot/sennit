import 'package:flutter/material.dart';
import 'package:weft_domain/weft_domain.dart';

import '../focus.dart';
import '../theme.dart';
import '../tokens.dart';
import 'network_glyph.dart';

/// The left rail: which networks' conversations the inbox shows.
///
/// The rail itself is selection-model agnostic — it renders [selected] and
/// reports taps. Whether a tap replaces the selection (single, the default) or
/// toggles membership (multi) is the caller's policy, switched in settings.
/// "All" is a distinct entry that clears the filter, so returning to the
/// unfiltered inbox is always one tap.
class NetworkRail extends StatelessWidget {
  const NetworkRail({
    super.key,
    required this.networks,
    required this.selected,
    required this.onToggle,
    required this.onShowAll,
    this.unreadByNetwork = const {},
    this.width = 76,
  });

  /// Networks the user actually has bridges for, in display order.
  final List<ChatNetwork> networks;

  /// Empty means "no filter" — the All entry is active.
  final Set<ChatNetwork> selected;

  final ValueChanged<ChatNetwork> onToggle;
  final VoidCallback onShowAll;
  final Map<ChatNetwork, int> unreadByNetwork;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final rtl = Directionality.of(context) == TextDirection.rtl;

    return Container(
      width: width,
      color: palette.railBackground,
      // The rail hugs the window's *starting* edge, so the inset it must honour
      // is the physical left one in an LTR window and the physical right one in
      // an RTL one — while the edge it shares with the inbox never needs an
      // inset at all. `SafeArea` takes physical edges only, so this is the one
      // place the direction has to be read rather than expressed.
      child: SafeArea(
        left: !rtl,
        right: rtl,
        child: Column(
          children: [
            const SizedBox(height: WeftSpace.md),
            _AllEntry(
              active: selected.isEmpty,
              total: unreadByNetwork.values.fold(0, (a, b) => a + b),
              onTap: onShowAll,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.lg,
                vertical: WeftSpace.sm,
              ),
              child: Divider(color: palette.divider, height: 1),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: WeftSpace.xs),
                itemCount: networks.length,
                itemBuilder: (context, i) {
                  final network = networks[i];
                  return _RailEntry(
                    network: network,
                    selected: selected.contains(network),
                    unread: unreadByNetwork[network] ?? 0,
                    onTap: () => onToggle(network),
                    // Stagger entry so the rail assembles rather than snapping.
                    delay: context.motion.stagger * i,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllEntry extends StatelessWidget {
  const _AllEntry({
    required this.active,
    required this.total,
    required this.onTap,
  });

  final bool active;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return _RailButton(
      selected: active,
      onTap: onTap,
      tooltip: 'All conversations',
      badge: total,
      child: AnimatedContainer(
        duration: context.motion.fast,
        curve: context.motion.standard,
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: WeftRadius.allMd,
          gradient: LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: [colors.primary, colors.tertiary],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.all_inbox_rounded, size: 20, color: colors.onPrimary),
      ),
    );
  }
}

class _RailEntry extends StatefulWidget {
  const _RailEntry({
    required this.network,
    required this.selected,
    required this.unread,
    required this.onTap,
    required this.delay,
  });

  final ChatNetwork network;
  final bool selected;
  final int unread;
  final VoidCallback onTap;
  final Duration delay;

  @override
  State<_RailEntry> createState() => _RailEntryState();
}

class _RailEntryState extends State<_RailEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: WeftMotion.normal,
  );

  @override
  void initState() {
    super.initState();
    // Staggered reveal on first build. Guarded on `mounted` because the rail
    // can be rebuilt with fewer networks while these timers are pending.
    Future<void>.delayed(widget.delay, () {
      if (mounted) _entry.forward();
    });
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motion = context.motion;
    // Assigned here rather than at construction because the reduce-motion
    // answer lives in the theme, which a field initialiser cannot reach. A
    // zero duration makes the pending `forward()` land instantly, so a rail
    // built under reduced motion appears rather than marching in.
    _entry.duration = motion.normal;

    return FadeTransition(
      opacity: CurvedAnimation(parent: _entry, curve: motion.enter),
      child: SlideTransition(
        // The entries march in from the window's edge, which is the right-hand
        // one in an RTL window. `SlideTransition` mirrors its own offset when
        // told the direction — the alternative is negating the tween by hand,
        // which is the same bug written twice.
        textDirection: Directionality.of(context),
        position: Tween<Offset>(
          begin: const Offset(-0.35, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _entry, curve: motion.enter)),
        child: _RailButton(
          selected: widget.selected,
          onTap: widget.onTap,
          tooltip: widget.network.label,
          badge: widget.unread,
          child: NetworkGlyph(
            network: widget.network,
            size: 36,
            selected: widget.selected,
          ),
        ),
      ),
    );
  }
}

/// Shared chrome for a rail item: the selection pill, the left accent bar, the
/// press-scale and the unread badge.
class _RailButton extends StatefulWidget {
  const _RailButton({
    required this.selected,
    required this.onTap,
    required this.tooltip,
    required this.child,
    this.badge = 0,
  });

  final bool selected;
  final VoidCallback onTap;
  final String tooltip;
  final Widget child;
  final int badge;

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colors = context.colors;
    final motion = context.motion;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WeftSpace.sm,
        vertical: WeftSpace.xs,
      ),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 500),
        // A `Tooltip` contributes its message to the semantics tree as well as
        // to the screen, so the rail announced every item twice — once from the
        // tooltip and once from the node below, which already says the same
        // thing and more.
        excludeFromSemantics: true,
        // Excluding the subtree stops the glyph's own label and the unread
        // badge's digits being announced under the item, which is the same
        // doubling the tooltip caused. `WeftFocusable` also puts the item in
        // the traversal order — a `GestureDetector` is not focusable, so Tab
        // never reached the network filter at all.
        child: WeftFocusable(
          selected: widget.selected,
          onTap: widget.onTap,
          label: widget.badge > 0
              ? '${widget.tooltip}, ${widget.badge} unread'
              : widget.tooltip,
          borderRadius: WeftRadius.allMd,
          child: Listener(
            // A `Listener` rather than a second `GestureDetector`: the
            // focusable already owns the tap, and two recognisers competing in
            // the same arena is how a press state gets stuck down. This only
            // watches the pointer to drive the scale.
            onPointerDown: (_) => setState(() => _pressed = true),
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: AnimatedScale(
              scale: _pressed ? 0.92 : 1,
              duration: motion.instant,
              curve: motion.standard,
              child: SizedBox(
                height: 52,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    // Selection pill sized to the glyph. A full-width bar left
                    // awkward slabs of colour above and below the icon on
                    // narrow rails; a fitted squircle reads as "this icon".
                    AnimatedContainer(
                      duration: motion.normal,
                      curve: motion.spring,
                      width: widget.selected ? 48 : 44,
                      height: widget.selected ? 48 : 44,
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? palette.railSelected
                            : Colors.transparent,
                        borderRadius: WeftRadius.allMd,
                      ),
                    ),
                    // Accent bar slides out from the rail's outer edge on
                    // selection — the screen's edge, not the physical left, so
                    // in an RTL window it comes in from the right and the rail
                    // still reads as attached to the side of the window it is
                    // on rather than pointing into the inbox.
                    AnimatedPositionedDirectional(
                      duration: motion.normal,
                      curve: motion.spring,
                      start: widget.selected ? -WeftSpace.sm : -WeftSpace.lg,
                      top: 12,
                      bottom: 12,
                      child: AnimatedOpacity(
                        duration: motion.fast,
                        opacity: widget.selected ? 1 : 0,
                        child: Container(
                          width: 3,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: WeftRadius.pill,
                          ),
                        ),
                      ),
                    ),
                    widget.child,
                    if (widget.badge > 0)
                      PositionedDirectional(
                        end: 6,
                        top: 4,
                        child: _UnreadBadge(count: widget.badge),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedSwitcher(
      duration: context.motion.fast,
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Container(
        key: ValueKey(count),
        constraints: const BoxConstraints(minWidth: 18),
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: colors.error,
          borderRadius: WeftRadius.pill,
          border: Border.all(color: context.palette.railBackground, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          count > 99 ? '99+' : '$count',
          style: TextStyle(
            color: colors.onError,
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
