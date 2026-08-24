# Contributing to Braid

Thanks for wanting to help. Braid is a Flutter app in a Dart pub workspace —
most logic lives in pure-Dart packages under `packages/`, and most of the
test suite runs without any device.

## Setting up

```bash
git clone https://github.com/bostrot/braid.git
cd braid
flutter pub get
flutter test
```

You need a recent Flutter stable (3.44+ / Dart 3.12+). Platform folders for
Android, iOS, macOS, Linux and Windows live under `apps/weft/`.

For manual testing you need a Matrix homeserver; a Docker Compose stack with
Synapse and a mock bridge lives in `tooling/docker/` — no real accounts or
bridges required.

## Making changes

1. **Find the right layer.** Business rules go in `packages/weft_domain`,
   Matrix specifics in `packages/weft_matrix`, merge logic in
   `packages/weft_merge`, and so on. UI goes in `apps/weft/lib/features/`.
   Pure-Dart packages must not import Flutter.
2. **Write the test with the change.** Merge scoring, timeline ordering and
   notification policy are all pinned by unit tests; screens are pinned by
   golden tests (`apps/weft/test/goldens/`). If a golden legitimately
   changes, regenerate with `flutter test --update-goldens` and include the
   new image.
3. **Keep the suite green.**

   ```bash
   flutter analyze
   flutter test
   ```

4. **Small, focused pull requests** with a description of the user-visible
   behaviour they change. Commit messages are sentences that explain the
   change, not labels.

## What's welcome

- Bug fixes with a reproducing test.
- Bridge compatibility work (new mautrix bridges, provisioning quirks).
- Translations and accessibility improvements.
- Performance work backed by measurements.

For large features, open an issue first so we can agree on the shape before
you invest the time.

## License

By contributing you agree that your contributions are licensed under the
[AGPL-3.0](LICENSE), like the rest of the project.
