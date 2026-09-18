import 'package:flutter/material.dart';
import 'package:flutter_list_view/flutter_list_view.dart';
import 'package:flutter_list_view/src/flutter_list_view_element.dart';
import 'package:flutter_test/flutter_test.dart';

// Row heights the list does not know upfront, like chat rows.
double rowHeight(int i) => 40.0 + ((i * 37) % 160);

Widget buildKeyedList(
  FlutterListViewController controller,
  int count,
  int keyBase, {
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
            (context, i) =>
                SizedBox(height: h(keyBase + i), child: Text('row $i')),
            childCount: count,
            onItemKey: (i) => 'row-${keyBase + i}',
            keepPosition: true,
            keepPositionOffset: 0.5,
          ),
        ),
      ),
    ),
  );
}

FlutterListViewElement listElement(WidgetTester tester) =>
    tester.element(find.byType(FlutterSliverList)) as FlutterListViewElement;

void main() {
  testWidgets('height map drops evicted keys once over budget',
      (tester) async {
    const count = 300;
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);

    // Simulate kernel truncation churn: same count, fresh key window each
    // rebuild. Every window measures new rows into the height map.
    var measured = 0;
    for (var round = 0; round < 120; round++) {
      await tester.pumpWidget(buildKeyedList(controller, count, round * 50));
      await tester.pump();
      measured = listElement(tester).debugItemHeightCount;
    }

    // 120 windows of ~9 measured rows would hold ~1000 entries unbounded.
    // The prune keeps it near the live buffer plus slack.
    expect(measured, lessThan(600));
  });

  testWidgets('reuse cache stays capped when the buffer shrinks',
      (tester) async {
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);

    // Tiny rows so the rendered window holds ~100 rows, then shrink to 10:
    // the dump parks ~100 subtrees in the reuse cache at once.
    await tester.pumpWidget(buildKeyedList(
      controller,
      2000,
      0,
      heights: (_) => 10.0,
    ));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildKeyedList(
      controller,
      10,
      0,
      heights: (_) => 10.0,
    ));
    await tester.pumpAndSettle();

    final element = listElement(tester);
    expect(element.debugCachedElementCount, lessThanOrEqualTo(64));
    // Shrunk rows keep exact heights: no estimate fallback for live keys.
    expect(
      controller.sliverController.getVisibleIndexData()![1],
      lessThanOrEqualTo(9),
    );
  });

  testWidgets('unmount releases cached rows and heights', (tester) async {
    final controller = FlutterListViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildKeyedList(controller, 300, 0));
    await tester.pumpAndSettle();

    final element = listElement(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(element.debugItemHeightCount, equals(0));
    expect(element.debugCachedElementCount, equals(0));
  });
}
