# Contributing

Start with the [development guide](docs/development.md). Open an issue describing the problem or proposed behavior, or submit a focused pull request against `main`.

For fixes, include a short reproduction, the resulting behavior, and the checks you ran. Add a regression test when it proves meaningful behavior such as EPUB compatibility, queue state, request formatting, or cancellation. Use synthetic EPUBs and mocked speech responses; tests should not need personal credentials, copyrighted books, live story websites, or paid API calls.

Run `./Scripts/swift.sh test` and the Python suite before submitting code changes. When modifying packaging or the helper protocol, build the bundle and exercise the offline helper; when changing local audio behavior, also run the packaged smoke test. Document any environment-dependent checks you could not perform.

Keep licensing and attribution notices intact. The `Vendor/fanficfare_gui` modules originate in FanFicFare Desktop; describe modifications to those files and preserve their upstream notices.

Do not commit `.venv`, `.build`, `dist`, generated app bundles, private screenshots, `personal.ini`, other credential files, EPUBs, or audio. Review the actual diff for secrets and personal paths before pushing. Use [private vulnerability reporting](SECURITY.md) for security-sensitive findings.
