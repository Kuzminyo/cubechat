import 'dart:typed_data';

import 'package:cubechat/core/crypto/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// A row from the official BIP-340 test-vectors.csv. [sk] is null for
/// verify-only vectors.
class _Vec {
  const _Vec({this.sk, required this.pk, this.aux, required this.msg, required this.sig, required this.ok});
  final String? sk;
  final String pk;
  final String? aux;
  final String msg;
  final String sig;
  final bool ok;
}

// https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv
const _vectors = <_Vec>[
  _Vec(
    sk: '0000000000000000000000000000000000000000000000000000000000000003',
    pk: 'F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9',
    aux: '0000000000000000000000000000000000000000000000000000000000000000',
    msg: '0000000000000000000000000000000000000000000000000000000000000000',
    sig: 'E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215'
        '25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0',
    ok: true,
  ),
  _Vec(
    sk: 'B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF',
    pk: 'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
    aux: '0000000000000000000000000000000000000000000000000000000000000001',
    msg: '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
    sig: '6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341'
        '8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A',
    ok: true,
  ),
  _Vec(
    sk: 'C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9',
    pk: 'DD308AFEC5777E13121FA72B9CC1B7CC0139715309B086C960E18FD969774EB8',
    aux: 'C87AA53824B4D7AE2EB035A2B5BBBCCC080E76CDC6D1692C4B0B62D798E6D906',
    msg: '7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C',
    sig: '5831AAEED7B44BB74E5EAB94BA9D4294C49BCF2A60728D8B4C200F50DD313C1BA'
        'B745879A5AD954A72C45A91C3A51D3C7ADEA98D82F8481E0E1E03674A6F3FB7',
    ok: true,
  ),
  _Vec(
    sk: '0B432B2677937381AEF05BB02A66ECD012773062CF3FA2549E44F58ED2401710',
    pk: '25D1DFF95105F5253C4022F628A996AD3A0D95FBF21D468A1B33F8C160D8F517',
    aux: 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
    msg: 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
    sig: '7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC'
        '97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3',
    ok: true,
  ),
  // Verify-only, valid: public key where signature's s is small.
  _Vec(
    pk: 'D69C3509BB99E412E68B0FE8544E72837DFA30746D8BE2AA65975F29D22DC7B9',
    msg: '4DF3C3F68FCC83B27E9D42C90431A72499F17875C81A599B566C9889B9696703',
    sig: '00000000000000000000003B78CE563F89A0ED9414F5AA28AD0D96D6795F9C637'
        '6AFB1548AF603B3EB45C9F8207DEE1060CB71C04E80F593060B07D28308D7F4',
    ok: true,
  ),
  // Verify FALSE: public key is not a valid X coordinate (lift_x fails).
  _Vec(
    pk: 'EEFDEA4CDB677750A420FEE807EACF21EB9898AE79B9768766E4FAA04A2D4A34',
    msg: '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
    sig: '6CFF5C3BA86C69EA4B7376F31A9BCB4F74C1976089B2D9963DA2E5543E177769'
        '69E89B4C5564D00349106B8497785DD7D1D713A8AE82B32FA79D5F7FC407D39B',
    ok: false,
  ),
  // Verify FALSE: has_even_y(R) is false.
  _Vec(
    pk: 'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
    msg: '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
    sig: 'FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A1460297556'
        '3CC27944640AC607CD107AE10923D9EF7A73C643E166BE5EBEAFA34B1AC553E2',
    ok: false,
  ),
];

void main() {
  group('BIP-340 official test vectors', () {
    for (var i = 0; i < _vectors.length; i++) {
      final v = _vectors[i];

      if (v.sk != null) {
        test('vector $i — pubkey(sk) matches', () {
          expect(_hexOf(Secp256k1.xonlyPubkey(_hex(v.sk!))), v.pk);
        });

        test('vector $i — sign produces the expected signature', () async {
          final sig = await Secp256k1.sign(
            secretKey: _hex(v.sk!),
            message: _hex(v.msg),
            auxRand: _hex(v.aux!),
          );
          expect(_hexOf(sig), v.sig);
        });
      }

      test('vector $i — verify returns ${v.ok}', () async {
        final result = await Secp256k1.verify(
          publicKey: _hex(v.pk),
          message: _hex(v.msg),
          signature: _hex(v.sig),
        );
        expect(result, v.ok);
      });
    }
  });

  group('BIP-340 self-consistency', () {
    test('sign then verify round-trips for an arbitrary key/message', () async {
      final sk = _hex(
        '00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF',
      );
      final msg = _hex(
        'DEADBEEF00000000000000000000000000000000000000000000000000000001',
      );
      final aux = Uint8List(32);
      final pk = Secp256k1.xonlyPubkey(sk);
      final sig = await Secp256k1.sign(secretKey: sk, message: msg, auxRand: aux);
      expect(
        await Secp256k1.verify(publicKey: pk, message: msg, signature: sig),
        isTrue,
      );
    });

    test('a tampered message fails verification', () async {
      final sk = _hex(
        '00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF',
      );
      final msg = _hex(
        'DEADBEEF00000000000000000000000000000000000000000000000000000001',
      );
      final pk = Secp256k1.xonlyPubkey(sk);
      final sig =
          await Secp256k1.sign(secretKey: sk, message: msg, auxRand: Uint8List(32));
      final tampered = Uint8List.fromList(msg)..[0] ^= 0xFF;
      expect(
        await Secp256k1.verify(publicKey: pk, message: tampered, signature: sig),
        isFalse,
      );
    });
  });
}
