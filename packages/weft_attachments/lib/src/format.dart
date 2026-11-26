/// A byte count as a person would say it.
///
/// Binary units under decimal names, which is the lie every file manager tells
/// and therefore the number the user will see elsewhere for the same file. One
/// decimal place below 10 units so a 1.4 MB photo does not read as "1 MB", none
/// above it where the digit adds nothing.
///
/// Lives here rather than beside the bubble that first needed it because a size
/// is now said in three places that cannot afford to disagree — the preview
/// sheet, the file bubble, and the sentence a share intent gets when its video
/// is too large to stage. The last of those is decided below the UI layer
/// entirely, which is what pulled the formatter down here with it.
///
/// [decimalSeparator] is the reader's decimal mark: German, French, Spanish
/// and Portuguese write "2,4 MB". This package has no locale to ask, so the
/// app passes the mark in (`AppL10n.fileSize`); the point is the default.
String formatAttachmentSize(int bytes, {String decimalSeparator = '.'}) {
  if (bytes < 1024) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value < 10 ? 1 : 0;
  final number = value
      .toStringAsFixed(digits)
      .replaceFirst('.', decimalSeparator);
  return '$number ${units[unit]}';
}
