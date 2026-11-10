import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:blousab/services/community_store.dart';

void main() {
  test('decodes creator and community identity from BLS1 invitation', () {
    final payload = jsonEncode({
      'v': 1,
      'ownerId': 'owner-123',
      'communityId': 'community-456',
      'secret': 'ABCD2345',
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');

    expect(CommunityStore.decodeJoinCode('BLS1.$encoded'), {
      'ownerId': 'owner-123',
      'communityId': 'community-456',
      'secret': 'ABCD2345',
    });
  });

  test('rejects malformed BLS1 invitations', () {
    expect(CommunityStore.decodeJoinCode('BLS1.not-valid'), isNull);
    expect(CommunityStore.decodeJoinCode('ABCDEFGH'), isNull);
  });
}
