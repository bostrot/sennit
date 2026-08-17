/// The deep link that opens [chatId] in Weft.
///
/// Percent-encoded because chat ids are full of characters a URI reserves: a
/// room id is `!abc:example.org` and a merged id is `merged:contact_17…`. The
/// receiving end is `WeftLink.parse`, whose `Uri.pathSegments` decodes the
/// segment once — so this must encode, and must encode the *whole* id as one
/// segment, or a merged id's colon reads as a second path segment and the link
/// resolves to nothing. (`Uri.encodeComponent` leaves `!` alone, which is
/// correct: it is a legal path character. The colon is the one that matters.)
///
/// It lives in `weft_domain` rather than beside its first caller because three
/// layers now have to produce the identical string for the identical chat and
/// cannot afford to disagree: a notification's tap target, a launcher shortcut's
/// intent, and an iOS share-extension slot. Two of those are written by code
/// that never sees the third, and a link that differs by one escape opens
/// nothing at all.
String chatDeepLink(String chatId) =>
    'weft://chat/${Uri.encodeComponent(chatId)}';
