import 'dart:async';

import 'package:flutter/material.dart';

/// Build with `--dart-define=FAST_TIMERS=true` ONLY while testing by hand.
/// A normal build (including `flutter build apk --release`) uses the
/// production values: hunger every 30 seconds, win after 3 minutes.
const bool kFastTimers = bool.fromEnvironment('FAST_TIMERS');
const Duration kHungerInterval =
    kFastTimers ? Duration(seconds: 5) : Duration(seconds: 30);
const Duration kWinDuration =
    kFastTimers ? Duration(seconds: 15) : Duration(minutes: 3);

void main() => runApp(const DigitalPetApp());

class DigitalPetApp extends StatelessWidget {
  const DigitalPetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Digital Pet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const WelcomeScreen(),
    );
  }
}

/// Simple entry screen. Lets us verify that leaving the pet screen
/// disposes its timers (no "setState() called after dispose()").
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Digital Pet')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/pet.png', width: 160, height: 160,
                  semanticLabel: 'Your digital pet'),
              const SizedBox(height: 16),
              Text('Keep your pet fed and happy!',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('start-button'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const PetScreen()),
                ),
                icon: const Icon(Icons.pets),
                label: const Text('Visit your pet'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Immutable configuration: the starting name, starting meters and timer
/// durations never change while the screen is shown. Everything that
/// changes lives in [_PetScreenState].
class PetScreen extends StatefulWidget {
  const PetScreen({
    super.key,
    this.initialName = 'Pip',
    this.initialHappiness = 50,
    this.initialHunger = 50,
    this.hungerInterval = kHungerInterval,
    this.winDuration = kWinDuration,
  });

  final String initialName;
  final int initialHappiness;
  final int initialHunger;
  final Duration hungerInterval;
  final Duration winDuration;

  @override
  State<PetScreen> createState() => _PetScreenState();
}

enum Mood { unhappy, neutral, happy }

class _PetScreenState extends State<PetScreen> {
  // ---- Mutable state (one source of truth) ----
  late String _petName;
  late int _happiness;
  late int _hunger;
  bool _gameOver = false;
  bool _hasWon = false;
  bool _isPaused = false;
  String _lastAction = 'Choose an action to care for your pet.';

  // Short-lived presentation state (Visual polish)
  bool _bouncing = false;
  String? _reaction;

  late final TextEditingController _nameController;
  Timer? _hungerTimer;
  Timer? _highMoodTimer;
  Timer? _bounceTimer;
  Timer? _reactionTimer;

  // ---- Helpers ----
  int _clampMeter(int value) => value.clamp(0, 100).toInt();

  bool get _careLocked => _gameOver || _hasWon || _isPaused;
  bool get _winTimerRunning => _highMoodTimer != null;

  Mood get _mood {
    if (_happiness > 70) return Mood.happy;
    if (_happiness >= 30) return Mood.neutral;
    return Mood.unhappy;
  }

  String get _moodLabel => switch (_mood) {
        Mood.happy => 'Happy',
        Mood.neutral => 'Neutral',
        Mood.unhappy => 'Unhappy',
      };

  IconData get _moodIcon => switch (_mood) {
        Mood.happy => Icons.sentiment_very_satisfied,
        Mood.neutral => Icons.sentiment_neutral,
        Mood.unhappy => Icons.sentiment_very_dissatisfied,
      };

  Color get _moodColor => switch (_mood) {
        Mood.happy => Colors.green,
        Mood.neutral => Colors.yellow,
        Mood.unhappy => Colors.red,
      };

  /// Mood tint & size: derived from the same happiness bands as the label.
  double get _petScale => switch (_mood) {
        Mood.happy => 1.06,
        Mood.neutral => 1.0,
        Mood.unhappy => 0.94,
      };

  /// Pet speech is derived, never stored, so it cannot drift out of sync.
  String get _petMessage {
    if (_gameOver) return 'I need a rest.';
    if (_hasWon) return 'Best day ever!';
    if (_isPaused) return 'Zzz... paused.';
    if (_hunger > 80) return "I'm starving!";
    if (_happiness <= 30) return 'Play with me?';
    return "Hi, I'm $_petName!";
  }

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  String _formatDuration(Duration d) {
    if (d.inMinutes >= 1 && d.inSeconds % 60 == 0) {
      return '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}';
    }
    return '${d.inSeconds} seconds';
  }

  // ---- Lifecycle ----
  @override
  void initState() {
    super.initState();
    _petName = widget.initialName;
    _happiness = _clampMeter(widget.initialHappiness);
    _hunger = _clampMeter(widget.initialHunger);
    _nameController = TextEditingController(text: _petName);
    _startHungerTimer();
    // Starting above 80 counts as the first crossing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateOutcome();
    });
  }

  @override
  void dispose() {
    _hungerTimer?.cancel();
    _highMoodTimer?.cancel();
    _bounceTimer?.cancel();
    _reactionTimer?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  // ---- Timers ----
  /// Guarantees exactly one hunger timer: always cancel before creating.
  void _startHungerTimer() {
    _hungerTimer?.cancel();
    _hungerTimer = Timer.periodic(widget.hungerInterval, _onHungerTick);
  }

  void _onHungerTick(Timer timer) {
    if (!mounted || _gameOver || _hasWon || _isPaused) {
      timer.cancel();
      return;
    }
    setState(() {
      if (_hunger + 5 > 100) {
        // Overflow: hunger stays clamped and happiness drops by 20.
        _hunger = 100;
        _happiness = _clampMeter(_happiness - 20);
      } else {
        _hunger += 5;
      }
    });
    _updateOutcome();
  }

  void _cancelWinTimer() {
    _highMoodTimer?.cancel();
    _highMoodTimer = null;
  }

  /// Re-evaluates loss and win after EVERY state transition.
  void _updateOutcome() {
    if (_gameOver || _hasWon) return;

    if (_hunger == 100 && _happiness <= 10) {
      _cancelWinTimer();
      _hungerTimer?.cancel();
      setState(() => _gameOver = true);
      return;
    }

    // "Above 80" means strictly > 80. Paused sessions do not count.
    if (_happiness <= 80 || _isPaused) {
      if (_winTimerRunning) setState(_cancelWinTimer);
      return;
    }

    if (!_winTimerRunning) {
      setState(() {
        _highMoodTimer = Timer(widget.winDuration, () {
          _highMoodTimer = null;
          if (!mounted || _gameOver || _isPaused || _happiness <= 80) return;
          _hungerTimer?.cancel();
          setState(() => _hasWon = true);
        });
      });
    }
  }

  // ---- User actions ----
  void _feedPet() {
    if (_careLocked) return;
    final beforeHunger = _hunger;
    final beforeHappiness = _happiness;
    final nextHunger = _clampMeter(_hunger - 10);
    final happinessChange = nextHunger < 30 ? -20 : 10;
    final nextHappiness = _clampMeter(_happiness + happinessChange);

    setState(() {
      _hunger = nextHunger;
      _happiness = nextHappiness;
      _lastAction = nextHunger < 30
          ? 'Overfed! Hunger $beforeHunger → $nextHunger, '
              'happiness $beforeHappiness → $nextHappiness.'
          : 'Fed $_petName. Hunger $beforeHunger → $nextHunger, '
              'happiness $beforeHappiness → $nextHappiness.';
    });
    _react('🍖');
    _updateOutcome();
  }

  void _playWithPet() {
    if (_careLocked) return;
    final beforeHunger = _hunger;
    final beforeHappiness = _happiness;
    final nextHappiness = _clampMeter(_happiness + 10);
    final nextHunger = _clampMeter(_hunger + 5);

    setState(() {
      _happiness = nextHappiness;
      _hunger = nextHunger;
      _lastAction = 'Played with $_petName. '
          'Happiness $beforeHappiness → $nextHappiness, '
          'hunger $beforeHunger → $nextHunger.'
          '${nextHappiness == 100 && beforeHappiness + 10 > 100 ? ' (Happiness is maxed at 100.)' : ''}';
    });
    _react('🎾');
    _updateOutcome();
  }

  /// Session controls: pause stops every timer, resume starts exactly one
  /// hunger timer again and starts a FRESH win timer if still above 80.
  void _togglePause() {
    if (_gameOver || _hasWon) return;
    if (!_isPaused) {
      _hungerTimer?.cancel();
      _hungerTimer = null;
      setState(() {
        _cancelWinTimer();
        _isPaused = true;
        _lastAction = 'Paused. Timers are stopped and care actions are off.';
      });
    } else {
      setState(() {
        _isPaused = false;
        _lastAction = 'Resumed. Hunger timer restarted.';
      });
      _startHungerTimer();
      _updateOutcome();
    }
  }

  void _resetPet() {
    _cancelWinTimer();
    _bounceTimer?.cancel();
    _reactionTimer?.cancel();
    setState(() {
      _happiness = _clampMeter(widget.initialHappiness);
      _hunger = _clampMeter(widget.initialHunger);
      _gameOver = false;
      _hasWon = false;
      _isPaused = false;
      _bouncing = false;
      _reaction = null;
      _lastAction = 'Restarted. Meters are back to their starting values.';
    });
    _startHungerTimer();
    _updateOutcome();
  }

  void _confirmName() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _lastAction = 'Please enter a name first.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _petName = name;
      _lastAction = 'Say hi to $name!';
    });
  }

  /// Action bounce + action reaction. Each new action replaces older
  /// pending callbacks so an old timer can never end a newer bounce.
  void _react(String emoji) {
    _bounceTimer?.cancel();
    _reactionTimer?.cancel();
    setState(() {
      _bouncing = !_reduceMotion;
      _reaction = emoji;
    });
    _bounceTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() => _bouncing = false);
    });
    _reactionTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _reaction = null);
    });
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final reduceMotion = _reduceMotion;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('$_petName the Digital Pet')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildNameRow(),
                  const SizedBox(height: 12),
                  _buildOutcomeBanner(theme),
                  _buildPet(reduceMotion),
                  const SizedBox(height: 8),
                  _buildMoodRow(theme),
                  const SizedBox(height: 8),
                  _buildSpeech(theme, reduceMotion),
                  const SizedBox(height: 16),
                  _buildMeter('Happiness', _happiness, Icons.favorite,
                      Colors.pink, reduceMotion),
                  const SizedBox(height: 12),
                  _buildMeter('Hunger', _hunger, Icons.restaurant,
                      Colors.orange, reduceMotion),
                  const SizedBox(height: 8),
                  Text(
                    _winTimerRunning
                        ? 'Win timer running: keep happiness above 80 for '
                            '${_formatDuration(widget.winDuration)}.'
                        : 'Goal: keep happiness above 80 for '
                            '${_formatDuration(widget.winDuration)}.',
                    key: const Key('win-status'),
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  _buildCareButtons(),
                  const SizedBox(height: 8),
                  _buildSessionButtons(),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(_lastAction,
                        key: const Key('last-action'),
                        textAlign: TextAlign.center),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNameRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('name-field'),
            controller: _nameController,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _confirmName(),
            decoration: const InputDecoration(
              labelText: 'Pet name',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const Key('confirm-name-button'),
          onPressed: _confirmName,
          child: const Text('Confirm'),
        ),
      ],
    );
  }

  Widget _buildOutcomeBanner(ThemeData theme) {
    String? text;
    Color? color;
    IconData? icon;
    if (_gameOver) {
      text = 'Game over! $_petName got too hungry and sad. Tap Restart.';
      color = Colors.red.shade100;
      icon = Icons.heart_broken;
    } else if (_hasWon) {
      text = 'You won! $_petName stayed happy for '
          '${_formatDuration(widget.winDuration)}.';
      color = Colors.green.shade100;
      icon = Icons.emoji_events;
    } else if (_isPaused) {
      text = 'Paused. Tap Resume to continue.';
      color = Colors.blueGrey.shade100;
      icon = Icons.pause_circle;
    }
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('outcome-banner'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Icon(icon, color: Colors.black87),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(text,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: Colors.black87))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPet(bool reduceMotion) {
    final scale = _petScale * (_bouncing ? 1.12 : 1.0);
    final duration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
    return SizedBox(
      height: 230,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedScale(
            key: const Key('pet-scale'),
            scale: scale,
            duration: duration,
            curve: Curves.easeOutBack,
            child: ColorFiltered(
              key: const Key('pet-tint'),
              colorFilter: ColorFilter.mode(_moodColor, BlendMode.modulate),
              child: Image.asset(
                'assets/pet.png',
                width: 200,
                height: 200,
                semanticLabel: '$_petName looks $_moodLabel',
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 40,
            child: AnimatedSlide(
              offset: _reaction == null || reduceMotion
                  ? Offset.zero
                  : const Offset(0, -0.4),
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 600),
              child: AnimatedOpacity(
                opacity: _reaction == null ? 0 : 1,
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 250),
                child: ExcludeSemantics(
                  child: Text(_reaction ?? '❤️',
                      key: const Key('reaction'),
                      style: const TextStyle(fontSize: 40)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMoodRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(_moodIcon, size: 28),
        const SizedBox(width: 8),
        Text('Mood: $_moodLabel',
            key: const Key('mood-label'), style: theme.textTheme.titleLarge),
      ],
    );
  }

  Widget _buildSpeech(ThemeData theme, bool reduceMotion) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: AnimatedSwitcher(
          duration:
              reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
          child: Text(
            _petMessage,
            key: ValueKey(_petMessage),
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
          ),
        ),
      ),
    );
  }

  Widget _buildMeter(String label, int value, IconData icon, Color color,
      bool reduceMotion) {
    final key = label.toLowerCase();
    return Semantics(
      label: '$label $value out of 100',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 6),
              Text(label),
              const Spacer(),
              Text('$value', key: Key('$key-value')),
              const Text(' / 100'),
            ],
          ),
          const SizedBox(height: 4),
          // Living meters: the bar glides, but its target comes from state.
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: value / 100),
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            builder: (context, v, _) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: v,
                minHeight: 12,
                color: color,
                backgroundColor: color.withValues(alpha: 0.2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCareButtons() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            key: const Key('feed-button'),
            onPressed: _careLocked ? null : _feedPet,
            icon: const Icon(Icons.restaurant),
            label: const Text('Feed'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            key: const Key('play-button'),
            onPressed: _careLocked ? null : _playWithPet,
            icon: const Icon(Icons.sports_baseball),
            label: const Text('Play'),
          ),
        ),
      ],
    );
  }

  Widget _buildSessionButtons() {
    final ended = _gameOver || _hasWon;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('pause-button'),
            onPressed: ended ? null : _togglePause,
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            label: Text(_isPaused ? 'Resume' : 'Pause'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('restart-button'),
            onPressed: _resetPet,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Restart'),
          ),
        ),
      ],
    );
  }
}
