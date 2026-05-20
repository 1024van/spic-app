import 'package:flutter/material.dart';
import 'package:trusttunnel/data/model/vpn_state.dart';

class VpnConnectButton extends StatefulWidget {
  const VpnConnectButton({
    required this.state,
    required this.onPressed,
    super.key,
  });

  final VpnState state;
  final VoidCallback? onPressed;

  @override
  State<VpnConnectButton> createState() => _VpnConnectButtonState();
}

class _VpnConnectButtonState extends State<VpnConnectButton>
    with SingleTickerProviderStateMixin {
  static const Set<VpnState> _connectingStates = {
    VpnState.connecting,
    VpnState.waitingForRecovery,
    VpnState.recovering,
    VpnState.waitingForNetwork,
  };

  late final AnimationController _controller;
  late final Animation<double> _pulse;
  late final Animation<double> _scale;

  bool get _isConnected => widget.state == VpnState.connected;
  bool get _isConnecting => _connectingStates.contains(widget.state);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 1.04,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.04,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 50,
      ),
    ]).animate(_controller);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant VpnConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (_isConnected || _isConnecting) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = _paletteForState(scheme);
    final buttonLabel = _isConnected ? 'DISCONNECT' : 'CONNECT';

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulseValue = _pulse.value;
        final auraOpacity = _isConnected
            ? (0.28 - (pulseValue * 0.20)).clamp(0.0, 1.0)
            : 0.0;
        final pulseOpacity = _isConnecting
            ? (0.18 - (pulseValue * 0.12)).clamp(0.0, 1.0)
            : 0.0;
        final outerScale = _isConnected
            ? 1.15 + (pulseValue * 0.35)
            : 1.0 + (pulseValue * 0.28);

        return Transform.scale(
          scale: (_isConnected || _isConnecting) ? _scale.value : 1,
          child: SizedBox(
            width: 172,
            height: 172,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_isConnected)
                  _AnimatedRing(
                    color: palette.glowColor.withValues(alpha: auraOpacity),
                    scale: outerScale,
                  ),
                if (_isConnecting)
                  _AnimatedRing(
                    color: palette.ringColor.withValues(alpha: pulseOpacity),
                    scale: outerScale,
                  ),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.onPressed,
                    customBorder: const CircleBorder(),
                    child: Ink(
                      width: 148,
                      height: 148,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [palette.centerColor, palette.baseColor],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: palette.shadowColor,
                            blurRadius: _isConnected ? 18 : 10,
                            spreadRadius: _isConnected ? 1 : 0,
                          ),
                        ],
                        border: Border.all(
                          color: palette.borderColor,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _isConnected
                                ? Icons.shield
                                : Icons.power_settings_new_rounded,
                            color: palette.foregroundColor,
                            size: 38,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            buttonLabel,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: palette.foregroundColor,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _statusText,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: palette.foregroundColor.withValues(
                                    alpha: 0.8,
                                  ),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  _ButtonPalette _paletteForState(ColorScheme scheme) {
    if (_isConnected) {
      return _ButtonPalette(
        baseColor: const Color(0xFF1F9D55),
        centerColor: const Color(0xFF42C777),
        ringColor: const Color(0xFF9BE7BE),
        glowColor: const Color(0xFF8BE6B0),
        borderColor: Colors.white.withValues(alpha: 0.24),
        foregroundColor: Colors.white,
        shadowColor: const Color(0x661F9D55),
      );
    }

    if (_isConnecting) {
      return _ButtonPalette(
        baseColor: scheme.primary,
        centerColor: Color.lerp(scheme.primary, Colors.white, 0.18)!,
        ringColor: scheme.primary,
        glowColor: scheme.primary,
        borderColor: Colors.white.withValues(alpha: 0.2),
        foregroundColor: Colors.white,
        shadowColor: scheme.primary.withValues(alpha: 0.28),
      );
    }

    return _ButtonPalette(
      baseColor: const Color(0xFF516173),
      centerColor: const Color(0xFF6E8296),
      ringColor: scheme.primary,
      glowColor: scheme.primary,
      borderColor: Colors.white.withValues(alpha: 0.16),
      foregroundColor: Colors.white,
      shadowColor: const Color(0x33516173),
    );
  }

  String get _statusText {
    switch (widget.state) {
      case VpnState.connected:
        return 'Connected';
      case VpnState.connecting:
        return 'Connecting';
      case VpnState.disconnected:
        return 'Tap to connect';
      case VpnState.waitingForRecovery:
        return 'Waiting for recovery';
      case VpnState.recovering:
        return 'Recovering';
      case VpnState.waitingForNetwork:
        return 'Waiting for network';
    }
  }
}

class _AnimatedRing extends StatelessWidget {
  const _AnimatedRing({required this.color, required this.scale});

  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: IgnorePointer(
        child: Container(
          width: 148,
          height: 148,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 10),
          ),
        ),
      ),
    );
  }
}

class _ButtonPalette {
  const _ButtonPalette({
    required this.baseColor,
    required this.centerColor,
    required this.ringColor,
    required this.glowColor,
    required this.borderColor,
    required this.foregroundColor,
    required this.shadowColor,
  });

  final Color baseColor;
  final Color centerColor;
  final Color ringColor;
  final Color glowColor;
  final Color borderColor;
  final Color foregroundColor;
  final Color shadowColor;
}
