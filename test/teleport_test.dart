import 'package:flutter/material.dart';
import 'package:flutter_list_view/flutter_list_view.dart';
import 'package:flutter_test/flutter_test.dart';

// Variable row heights the list does not know upfront (no onItemHeight).
// Average is ~120px, far from the 50px fallback, like chat rows.
double rowHeight(int i) => 40.0 + ((i * 37) % 160);

Widget buildChatLikeList(
  FlutterListViewController controller,
  int count, {
  double Function(int)? heights,
}) {
  final h = heights ?? rowHeight;
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        width: 400,
        child: FlutterListView(
          controller: controller,
          reverse: true,
          delegate: FlutterListViewDelegate(
            (context, i) => SizedBox(height: h(i), child: Text('row $i')),
            childCount: count,
            onItemKey: (i) => 'row-$i',
            keepPosition: true,
            keepPositionOffset: 0.5,
          ),
        ),
      ),
    ),
  );
}

Future<List<double>> pumpAndTrace(
  WidgetTester tester,
  FlutterListViewController controller,
  int frames,
) async {
  final trace = <double>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump();
    trace.add(controller.position.pixels);
  }
  return trace;
}

void main() {
  testWidgets('teleport to bottom lands in one frame, never out of range',
      (tester) async {
    const count = 300;
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildChatLikeList(controller, count));
    await tester.pumpAndSettle();

    // Park at the oldest rows (top), like a user scrolled all the way up.
    controller.sliverController.jumpToIndex(count - 1, offset: 0);
    await tester.pumpAndSettle();
    final topPixels = controller.position.pixels;
    expect(topPixels, greaterThan(10000));

    // Raw pixel jump to bottom, exactly what the app FAB does.
    controller.jumpTo(0);
    final trace = await pumpAndTrace(tester, controller, 10);

    for (final pixels in trace) {
      expect(pixels, greaterThanOrEqualTo(0),
          reason: 'overshot past the bottom: $trace');
      expect(pixels, lessThanOrEqualTo(controller.position.maxScrollExtent),
          reason: 'overshot past the top: $trace');
    }
    expect(trace.first, equals(0), reason: 'did not teleport: $trace');
    final visible = controller.sliverController.getVisibleIndexData()!;
    expect(visible[0], equals(0),
        reason: 'newest row must be visible after teleport');
  });

  testWidgets('tail eviction while parked at oldest snaps in one frame',
      (tester) async {
    var count = 300;
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildChatLikeList(controller, count));
    await tester.pumpAndSettle();

    controller.sliverController.jumpToIndex(count - 1, offset: 0);
    await tester.pumpAndSettle();

    // Pop the 50 oldest rows out from under the viewport (truncation).
    count -= 50;
    await tester.pumpWidget(buildChatLikeList(controller, count));
    await tester.pump();
    final firstFrame = controller.position.pixels;

    // Instant choppy snap, not a glide: the first frame already rests near
    // where it settles. (Exact max extent is estimate-bound by design, like
    // RecyclerView's scroll range, so positions must be consistent with the
    // extent, not with ground truth.)
    final settled = await pumpAndTrace(tester, controller, 5);
    expect((firstFrame - settled.last).abs(), lessThan(600),
        reason:
            'sprung instead of snapping: first=$firstFrame settled=$settled');
    final maxExtent = controller.position.maxScrollExtent;
    expect(settled.last, moreOrLessEquals(maxExtent, epsilon: 0.5),
        reason: 'not parked at the end: $settled vs max $maxExtent');
    // No gap: the new oldest row is actually painted.
    final visible = controller.sliverController.getVisibleIndexData()!;
    expect(visible[1], equals(count - 1),
        reason: 'oldest surviving row must be visible, no gap: $visible');

    // Settles: no drift afterwards, never out of range.
    for (final pixels in settled) {
      expect(pixels, greaterThanOrEqualTo(0), reason: 'went negative');
      expect(pixels, lessThanOrEqualTo(maxExtent + 0.5),
          reason: 'dangling past the end');
    }
    expect(settled.last, moreOrLessEquals(settled.first, epsilon: 0.5),
        reason: 'kept drifting after the snap: $settled');
  });

  testWidgets('height estimate follows a content regime shift', (tester) async {
    const count = 200;
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);
    // One-line-emote regime first.
    await tester.pumpWidget(buildChatLikeList(controller, count,
        heights: (i) => 36.0 + ((i * 7) % 8)));
    await tester.pumpAndSettle();
    controller.sliverController.jumpToIndex(count - 1, offset: 0);
    await tester.pumpAndSettle();
    expect(controller.position.maxScrollExtent,
        moreOrLessEquals(count * 40.0 - 600, epsilon: count * 10.0));

    // Sudden shift to long messages, same keys. After one frame only the
    // viewport rows are re-measured, so the total is estimate-driven: it
    // must already track the new regime (a fixed 50px fallback would sit
    // near 12000 here instead of ~39000).
    await tester.pumpWidget(buildChatLikeList(controller, count,
        heights: (i) => 180.0 + ((i * 13) % 40)));
    await tester.pump();
    const truth = count * 200.0 - 600;
    final estimated = controller.position.maxScrollExtent;
    expect((estimated - truth).abs() / truth, lessThan(0.4),
        reason: 'estimate did not track the shift: $estimated vs $truth');

    // Traversing measures every row it passes, so the total must heal
    // toward truth with the oldest row painted (no dead zone at the end).
    // Exact extent stays estimate-bound by design (RecyclerView also only
    // approximates scroll range); what must be exact is parking at the
    // extent with the oldest row painted.
    controller.sliverController.jumpToIndex(count ~/ 2, offset: 0);
    await tester.pumpAndSettle();
    controller.sliverController.jumpToIndex(count - 1, offset: 0);
    await tester.pumpAndSettle();
    final healedMax = controller.position.maxScrollExtent;
    expect((healedMax - truth).abs() / truth, lessThan(0.25),
        reason: 'total did not heal: $healedMax vs $truth');
    expect(
        controller.position.pixels, moreOrLessEquals(healedMax, epsilon: 0.5));
    final visible = controller.sliverController.getVisibleIndexData()!;
    expect(visible[1], equals(count - 1));
  });

  testWidgets('total refresh never moves a settled mid-list offset',
      (tester) async {
    const count = 300;
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildChatLikeList(controller, count));
    await tester.pumpAndSettle();
    controller.sliverController.jumpToIndex(count ~/ 2, offset: 0);
    await tester.pumpAndSettle();

    // Same rows, much taller: the viewport re-measures, the estimate jumps
    // and the total refreshes while parked mid-list.
    await tester.pumpWidget(
        buildChatLikeList(controller, count, heights: (i) => rowHeight(i) * 2));
    await tester.pumpAndSettle();

    final maxExtent = controller.position.maxScrollExtent;
    final pixels = controller.position.pixels;
    expect(pixels, greaterThanOrEqualTo(0));
    expect(pixels, lessThanOrEqualTo(maxExtent));
    // Still mid-list: no spurious snap to either end.
    expect(maxExtent - pixels, greaterThan(2000));
    expect(pixels, greaterThan(2000));
    final trace = await pumpAndTrace(tester, controller, 5);
    expect(trace.last, moreOrLessEquals(trace.first, epsilon: 1.0),
        reason: 'mid-list offset drifted: $trace');
  });

  testWidgets('explicit onItemHeight still wins over the estimate',
      (tester) async {
    const count = 100;
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          width: 400,
          child: FlutterListView(
            controller: controller,
            reverse: true,
            delegate: FlutterListViewDelegate(
              (context, i) =>
                  SizedBox(height: rowHeight(i), child: Text('row $i')),
              childCount: count,
              onItemKey: (i) => 'row-$i',
              onItemHeight: (i) => rowHeight(i),
              keepPosition: true,
              keepPositionOffset: 0.5,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final truth = List.generate(count, rowHeight).reduce((a, b) => a + b);
    expect(controller.position.maxScrollExtent,
        moreOrLessEquals(truth - 600, epsilon: 0.5));
  });
}
