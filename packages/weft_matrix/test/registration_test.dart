import 'package:flutter_test/flutter_test.dart';
import 'package:weft_matrix/weft_matrix.dart';

void main() {
  const dummy = RegistrationStage.dummy;
  const token = RegistrationStage.token;

  group('registrationOfferFor', () {
    test('a dummy-only flow is open registration', () {
      expect(
        registrationOfferFor([
          [dummy],
        ]),
        RegistrationOffer.open,
      );
    });

    test('a token flow asks for the token', () {
      expect(
        registrationOfferFor([
          [token],
        ]),
        RegistrationOffer.needsToken,
      );
    });

    test('a token is optional when a flow without one exists', () {
      expect(
        registrationOfferFor([
          [token, dummy],
          [dummy],
        ]),
        RegistrationOffer.open,
      );
    });

    test('a captcha or an emailed link is not something this client does', () {
      expect(
        registrationOfferFor([
          ['m.login.recaptcha', dummy],
          ['m.login.email.identity'],
        ]),
        RegistrationOffer.unsupported,
      );
    });

    test('an unsupported flow does not hide a supported one', () {
      expect(
        registrationOfferFor([
          ['m.login.recaptcha'],
          [token],
        ]),
        RegistrationOffer.needsToken,
      );
    });
  });

  group('nextRegistrationStage', () {
    test('walks the flow in order, skipping what is completed', () {
      const flows = [
        [token, dummy],
      ];
      expect(nextRegistrationStage(flows), token);
      expect(nextRegistrationStage(flows, completed: [token]), dummy);
    });

    test('answers dummy when the server asks again with nothing left', () {
      expect(
        nextRegistrationStage(
          [
            [token],
          ],
          completed: [token],
        ),
        dummy,
      );
    });

    test('is null when no flow can be completed', () {
      expect(
        nextRegistrationStage([
          ['m.login.terms'],
        ]),
        isNull,
      );
    });
  });
}
