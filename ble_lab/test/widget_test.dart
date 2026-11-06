import 'package:ble_lab/ble_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hex32 formats signed node ids as unsigned 8-digit hex', () {
    expect(hex32(1), '00000001');
    expect(hex32(-1), 'ffffffff');
  });
}
