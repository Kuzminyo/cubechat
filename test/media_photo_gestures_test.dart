import 'package:cubechat/features/chat/presentation/widgets/media_photo_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('repeated vertical swipes close and horizontal swipes page',
      (tester) async {
    var dismissEnds = 0;
    var pageEnds = 0;
    var vertical = 0.0;
    var horizontal = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaPhotoSurface(
            onDismissUpdate: (dy) => vertical += dy,
            onDismissEnd: (_) => dismissEnds++,
            onDismissCancel: () => vertical = 0,
            onPageUpdate: (dx) => horizontal += dx,
            onPageEnd: (_) => pageEnds++,
            child: const SizedBox.expand(child: ColoredBox(color: Colors.blue)),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(MediaPhotoSurface), const Offset(5, 180));
      await tester.pumpAndSettle();
    }
    expect(dismissEnds, 4);
    expect(vertical, greaterThan(400));
    expect(pageEnds, 0);
    await tester.drag(find.byType(MediaPhotoSurface), const Offset(-200, 5));
    await tester.pumpAndSettle();
    expect(pageEnds, 1);
    expect(horizontal, lessThan(-100));
    expect(dismissEnds, 4);
  });

  testWidgets('pinch and panning a zoomed image never dismiss or page',
      (tester) async {
    var navigation = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaPhotoSurface(
            onDismissUpdate: (_) => navigation++,
            onDismissEnd: (_) => navigation++,
            onDismissCancel: () {},
            onPageUpdate: (_) => navigation++,
            onPageEnd: (_) => navigation++,
            child: const SizedBox.expand(child: ColoredBox(color: Colors.blue)),
          ),
        ),
      ),
    );
    final one = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final two = await tester.startGesture(const Offset(400, 300), pointer: 2);
    await one.moveTo(const Offset(220, 300));
    await two.moveTo(const Offset(480, 300));
    await tester.pump();
    await one.up();
    await two.moveTo(const Offset(480, 480));
    await two.up();
    await tester.pumpAndSettle();
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1.1),
    );
    await tester.drag(find.byType(MediaPhotoSurface), const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(navigation, 0);
  });

  testWidgets('adding a second finger cancels a pending pull', (tester) async {
    var ended = 0;
    var cancelled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaPhotoSurface(
            onDismissUpdate: (_) {},
            onDismissEnd: (_) => ended++,
            onDismissCancel: () => cancelled++,
            onPageUpdate: (_) {},
            onPageEnd: (_) {},
            child: const SizedBox.expand(child: ColoredBox(color: Colors.blue)),
          ),
        ),
      ),
    );
    final one = await tester.startGesture(const Offset(300, 200), pointer: 1);
    await one.moveTo(const Offset(300, 240));
    await tester.pump();
    await one.moveTo(const Offset(300, 410));
    await tester.pump();
    final two = await tester.startGesture(const Offset(430, 410), pointer: 2);
    await tester.pump();
    await one.up();
    await two.moveTo(const Offset(430, 490));
    await two.up();
    await tester.pumpAndSettle();
    expect(ended, 0);
    expect(cancelled, 1);
  });

  testWidgets('pointer cancellation resets a pull without dismissing',
      (tester) async {
    var ended = 0;
    var cancelled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaPhotoSurface(
            onDismissUpdate: (_) {},
            onDismissEnd: (_) => ended++,
            onDismissCancel: () => cancelled++,
            onPageUpdate: (_) {},
            onPageEnd: (_) {},
            child: const SizedBox.expand(child: ColoredBox(color: Colors.blue)),
          ),
        ),
      ),
    );
    final finger = await tester.startGesture(const Offset(300, 200));
    await finger.moveTo(const Offset(300, 240));
    await tester.pump();
    await finger.moveTo(const Offset(300, 410));
    await tester.pump();
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(cancelled, 1);
    expect(ended, 0);
  });
}
