import 'package:digital_pet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(PetScreen screen, {bool disableAnimations = false}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: screen,
      ),
    ),
  );
}

/// Use a tall phone-sized surface so every control is on screen.
Future<void> _pump(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

int _happiness(WidgetTester t) => int.parse(_text(t, 'happiness-value'));
int _hunger(WidgetTester t) => int.parse(_text(t, 'hunger-value'));

bool _enabled(WidgetTester t, String key) =>
    t.widget<ButtonStyleButton>(find.byKey(Key(key))).onPressed != null;

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await t.pump();
}

void main() {
  testWidgets('initial state shows name, meters, and mood label',
      (tester) async {
    await _pump(tester, _host(const PetScreen()));
    expect(find.text('Pip the Digital Pet'), findsOneWidget);
    expect(_happiness(tester), 50);
    expect(_hunger(tester), 50);
    expect(_text(tester, 'mood-label'), 'Mood: Neutral');
    expect(find.byType(ColorFiltered), findsOneWidget);
  });

  testWidgets('user can enter and confirm a pet name', (tester) async {
    await _pump(tester, _host(const PetScreen()));
    await tester.enterText(find.byKey(const Key('name-field')), 'Mochi');
    await _tap(tester, 'confirm-name-button');
    expect(find.text('Mochi the Digital Pet'), findsOneWidget);
  });

  group('feed and play boundaries', () {
    testWidgets('feed at hunger 5 clamps to 0 and applies overfeed rule',
        (tester) async {
      await _pump(tester, _host(const PetScreen(initialHunger: 5)));
      await _tap(tester, 'feed-button');
      expect(_hunger(tester), 0);
      expect(_happiness(tester), 30); // resulting hunger < 30 => -20
    });

    testWidgets('feed at hunger 95 lowers hunger and adds happiness',
        (tester) async {
      await _pump(tester, _host(const PetScreen(initialHunger: 95)));
      await _tap(tester, 'feed-button');
      expect(_hunger(tester), 85);
      expect(_happiness(tester), 60);
    });

    testWidgets('play at happiness 95 clamps happiness to 100',
        (tester) async {
      await _pump(tester, _host(const PetScreen(initialHappiness: 95)));
      await _tap(tester, 'play-button');
      expect(_happiness(tester), 100);
      expect(_hunger(tester), 55);
      expect(_text(tester, 'last-action'), contains('maxed at 100'));
    });
  });

  group('mood thresholds 29 / 30 / 70 / 71', () {
    const cases = {
      29: ('Mood: Unhappy', Colors.red, 0.94),
      30: ('Mood: Neutral', Colors.yellow, 1.0),
      70: ('Mood: Neutral', Colors.yellow, 1.0),
      71: ('Mood: Happy', Colors.green, 1.06),
    };
    cases.forEach((happiness, expected) {
      testWidgets('happiness $happiness => ${expected.$1}', (tester) async {
        await _pump(tester, _host(PetScreen(initialHappiness: happiness)));
        expect(_text(tester, 'mood-label'), expected.$1);
        final tint = tester.widget<ColorFiltered>(
            find.byKey(const Key('pet-tint')));
        expect(tint.colorFilter,
            ColorFilter.mode(expected.$2, BlendMode.modulate));
        final scale =
            tester.widget<AnimatedScale>(find.byKey(const Key('pet-scale')));
        expect(scale.scale, expected.$3);
      });
    });
  });

  group('win timer', () {
    testWidgets('2:59 above 80 then drop to <= 80 cancels the win',
        (tester) async {
      await _pump(tester, _host(
          const PetScreen(initialHappiness: 85, initialHunger: 0)));
      await tester.pump(); // post-frame outcome check starts win timer
      expect(_text(tester, 'win-status'), startsWith('Win timer running'));

      await tester.pump(const Duration(minutes: 2, seconds: 59));
      expect(find.byKey(const Key('outcome-banner')), findsNothing);

      // Hunger is 25 now; feeding makes it 15 (< 30) so happiness -20 => 65.
      await _tap(tester, 'feed-button');
      expect(_happiness(tester), 65);
      expect(_text(tester, 'win-status'), startsWith('Goal'));

      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('You won'), findsNothing);
    });

    testWidgets('exactly 80 does not start the win timer', (tester) async {
      await _pump(tester, _host(const PetScreen(initialHappiness: 80)));
      await tester.pump();
      expect(_text(tester, 'win-status'), startsWith('Goal'));
    });

    testWidgets('three continuous minutes above 80 wins and stops hunger',
        (tester) async {
      await _pump(tester, _host(
          const PetScreen(initialHappiness: 85, initialHunger: 0)));
      await tester.pump();
      await tester.pump(const Duration(minutes: 3));
      await tester.pump();
      expect(find.textContaining('You won'), findsOneWidget);
      final hungerAtWin = _hunger(tester);
      expect(_enabled(tester, 'feed-button'), isFalse);
      expect(_enabled(tester, 'play-button'), isFalse);

      await tester.pump(const Duration(minutes: 1));
      expect(_hunger(tester), hungerAtWin); // hunger timer stopped
    });
  });

  group('hunger timer and loss', () {
    testWidgets('95 -> 100 has no penalty; next overflow tick costs 20',
        (tester) async {
      await _pump(tester, _host(const PetScreen(initialHunger: 95)));
      await tester.pump(const Duration(seconds: 30));
      expect(_hunger(tester), 100);
      expect(_happiness(tester), 50);
      await tester.pump(const Duration(seconds: 30));
      expect(_hunger(tester), 100);
      expect(_happiness(tester), 30);
    });

    testWidgets('hunger 100 and happiness 10 is game over and locks care',
        (tester) async {
      await _pump(tester, _host(
          const PetScreen(initialHunger: 100, initialHappiness: 30)));
      await tester.pump(const Duration(seconds: 30));
      expect(_happiness(tester), 10);
      expect(find.textContaining('Game over'), findsOneWidget);
      expect(_enabled(tester, 'feed-button'), isFalse);
      expect(_enabled(tester, 'play-button'), isFalse);
      expect(_enabled(tester, 'pause-button'), isFalse);

      await tester.pump(const Duration(minutes: 2));
      expect(_happiness(tester), 10); // state no longer changes
    });

    testWidgets('restart restores meters and a single hunger timer',
        (tester) async {
      await _pump(tester, _host(
          const PetScreen(initialHunger: 100, initialHappiness: 30)));
      await tester.pump(const Duration(seconds: 30));
      expect(find.textContaining('Game over'), findsOneWidget);

      await _tap(tester, 'restart-button');
      expect(find.textContaining('Game over'), findsNothing);
      expect(_hunger(tester), 100);
      expect(_happiness(tester), 30);
      expect(_enabled(tester, 'feed-button'), isTrue);

      await _tap(tester, 'feed-button'); // 90 / 40
      await tester.pump(const Duration(seconds: 30));
      // Exactly one timer => exactly +5 per interval.
      expect(_hunger(tester), 95);
    });
  });

  group('session controls (pause / resume)', () {
    testWidgets('pause stops hunger and locks care; resume restarts',
        (tester) async {
      await _pump(tester, _host(const PetScreen()));
      await _tap(tester, 'pause-button');
      expect(find.text('Resume'), findsOneWidget);
      expect(_enabled(tester, 'feed-button'), isFalse);

      await tester.pump(const Duration(minutes: 2));
      expect(_hunger(tester), 50);

      await _tap(tester, 'pause-button');
      expect(_enabled(tester, 'feed-button'), isTrue);
      await tester.pump(const Duration(seconds: 30));
      expect(_hunger(tester), 55);
    });

    testWidgets('pausing cancels the win streak; resume starts a fresh one',
        (tester) async {
      await _pump(tester, _host(
          const PetScreen(initialHappiness: 90, initialHunger: 0)));
      await tester.pump();
      await tester.pump(const Duration(minutes: 2));
      await _tap(tester, 'pause-button');
      expect(_text(tester, 'win-status'), startsWith('Goal'));
      await _tap(tester, 'pause-button');
      expect(_text(tester, 'win-status'), startsWith('Win timer running'));
      await tester.pump(const Duration(minutes: 2));
      expect(find.textContaining('You won'), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(find.textContaining('You won'), findsOneWidget);
    });
  });

  testWidgets('leaving the pet screen cancels timers (no post-dispose error)',
      (tester) async {
    await _pump(tester, const DigitalPetApp());
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pumpAndSettle();
    expect(find.byType(PetScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PetScreen), findsNothing);

    await tester.pump(const Duration(minutes: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion uses zero-duration animations', (tester) async {
    await _pump(
        tester, _host(const PetScreen(), disableAnimations: true));
    final scale =
        tester.widget<AnimatedScale>(find.byKey(const Key('pet-scale')));
    expect(scale.duration, Duration.zero);
    await _tap(tester, 'play-button');
    // No bounce when motion is reduced, but the reaction still shows.
    final after =
        tester.widget<AnimatedScale>(find.byKey(const Key('pet-scale')));
    expect(after.scale, 1.0);
    expect(find.text('🎾'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
