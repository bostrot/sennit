/// Why the browser could not reach its phone, for the connect screen.
enum PhoneConnectionProblem {
  /// This browser was never paired: open the QR code on the phone.
  notPaired,

  /// The phone did not answer: Sennit Web is off there, or the phone is
  /// asleep or on another network.
  unreachable,

  /// The phone's app and this page are different versions.
  versionMismatch,
}

class PhoneConnectionException implements Exception {
  const PhoneConnectionException(this.problem);
  final PhoneConnectionProblem problem;

  @override
  String toString() => 'PhoneConnectionException(${problem.name})';
}
