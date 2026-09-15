import 'package:cubechat/core/theme/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

List<BackdropFilterLayer> _filters(Layer? layer, [List<BackdropFilterLayer>? into]) {
  final found = into ?? <BackdropFilterLayer>[];
  for (var node = layer; node != null; node = node.nextSibling) {
    if (node is BackdropFilterLayer) found.add(node);
    if (node is ContainerLayer) _filters(node.firstChild, found);
  }
  return found;
}

/// [AppBlur.groupedPanes]: the chat's islands share one backdrop key, and
/// nothing about them changes when they do not.
void main() {
  tearDown(() {
    AppBlur.groupedPanes = false;
    AppBlur.panes = true;
  });

  Future<List<BackdropFilterLayer>> pumpIslands(WidgetTester tester) async {
    final key = BackdropKey();
    await tester.pumpWidget(
      MaterialApp(
        home: BackdropGroup(
          backdropKey: key,
          child: const Column(
            children: [
              // Separate boundaries, as the header and composer each are.
              RepaintBoundary(
                child: SizedBox(height: 60, child: GlassBlur(child: Text('h'))),
              ),
              Spacer(),
              RepaintBoundary(
                child: SizedBox(height: 60, child: GlassBlur(child: Text('c'))),
              ),
            ],
          ),
        ),
      ),
    );
    return _filters(tester.binding.renderViews.first.debugLayer);
  }

  testWidgets('grouped, both islands carry the group key', (tester) async {
    AppBlur.groupedPanes = true;
    final filters = await pumpIslands(tester);
    expect(filters, hasLength(2));
    expect(filters.map((f) => f.backdropKey).toSet(), hasLength(1));
    expect(filters.first.backdropKey, isNotNull);
  });

  testWidgets('not grouped, each filters on its own', (tester) async {
    final filters = await pumpIslands(tester);
    expect(filters, hasLength(2));
    expect(filters.every((f) => f.backdropKey == null), isTrue);
  });

  testWidgets('flipping the experiment does not remount a pane',
      (tester) async {
    await pumpIslands(tester);
    final before = tester.element(find.text('h'));
    AppBlur.groupedPanes = true;
    // A new build of the same tree, as the next chat opened would get.
    tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
    await tester.pump();
    expect(identical(tester.element(find.text('h')), before), isTrue);
    expect(
      _filters(tester.binding.renderViews.first.debugLayer)
          .every((f) => f.backdropKey != null),
      isTrue,
    );
  });

  testWidgets('outside a group the grouped constructor filters alone',
      (tester) async {
    AppBlur.groupedPanes = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(height: 60, child: GlassBlur(child: Text('toast'))),
      ),
    );
    final filters = _filters(tester.binding.renderViews.first.debugLayer);
    expect(filters, hasLength(1));
    expect(filters.single.backdropKey, isNull);
  });
}
