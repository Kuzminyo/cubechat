import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('proximity mode reports every decibel, normal mode only real moves',
      () {
    expect(BleConstants.rssiMoveThreshold(proximity: true), 1);
    expect(BleConstants.rssiMoveThreshold(proximity: false), 4);
  });

  test('proximity scanning barely pauses', () {
    expect(BleConstants.proximityGap, lessThan(const Duration(seconds: 1)));
    expect(
      BleConstants.proximityWindow,
      greaterThan(BleConstants.proximityGap),
    );
  });
}
