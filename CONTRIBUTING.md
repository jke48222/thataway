# Contributing to Thataway

Thanks for taking the time. Thataway is a small project with one maintainer, so this page says
what helps most and how to get a change merged.

## What helps most

- **Bug reports** with the steps, the app that was in front, and what the bar said.
- **Fixes** for bugs that have an issue.
- **Measurements from apps other than Chrome.** The accuracy evidence today is one Chrome window
  with 12 targets. A run of `thataway-bench axplan` or `--selftest` on another app, with the
  snapshot and the plan, is the most useful thing you can send.
- **Exclusion rule suggestions** for apps that show private content in their accessibility tree.

Please open an issue before a large change or a new feature, so we can agree on it before you
spend the time. Changes that move the real cursor or click on your behalf will not be merged:
Thataway only draws a pointer.

## Set up

You need macOS 14 or newer on Apple silicon and Xcode. There are no third-party Swift packages.

```bash
git clone https://github.com/jke48222/thataway.git
cd thataway
swift build -c release
swift test
```

`swift test` runs 233 tests headless, with no permissions. The Python tests need Pillow in a
virtual environment:

```bash
python3 -m venv /tmp/thataway-venv
/tmp/thataway-venv/bin/python -m pip install pillow
/tmp/thataway-venv/bin/python -B Tools/tests/test_holo_server.py
/tmp/thataway-venv/bin/python -B Tools/tests/test_make_app.py
```

To run the app, build the bundle with `bash Tools/make-app.sh` and `open build/Thataway.app`.
An Apple Development certificate from Xcode keeps the Accessibility grant across rebuilds; with ad
hoc signing, macOS asks again after every build.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the layout, and
[docs/BENCHMARKS.md](docs/BENCHMARKS.md) has the bench commands.

## Rules for a change

- **Keep `ThatawayCore` pure.** It imports Foundation, CoreGraphics and Darwin only, which is why
  its tests run headless. Code that needs AppKit, accessibility or capture goes in `ThatawayKit`.
- **Add a test** for anything that can be tested without a display or a permission.
- **Every number needs a source.** A performance claim in code, docs or a pull request names the
  command, the machine and the file that holds the result. Commit benchmark JSON to `bench-data/`
  only when a doc cites it.
- **Never commit screenshots of a real desktop.** They carry names, accounts and bookmarks.
  `bench-data/*.png` is ignored for that reason. Use fictional content for any image.
- **Do not weaken the privacy gate.** The exclusion check runs before the first accessibility call.
  A change that reads an excluded app, or sends screen content off the Mac, will not be merged.
- **Commit messages:** imperative, sentence case, no prefix, no trailing period, 72 characters at
  most. For example: `Skip the heartbeat walk while the bar is closed`.
- **CI must pass:** the release build, `swift test`, the Python tests, `thataway-bench doctor` and
  the `axplan` check.

## Pull requests

1. Fork the repository and branch from `main`.
2. Make the change, with tests.
3. Run `swift test` and the Python tests.
4. Open a pull request that says what changed, why, and how you checked it.

## License

Thataway is MIT licensed. By contributing, you agree that your contribution is licensed under the
same terms. See [LICENSE](LICENSE).

## Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Report security problems
privately as [SECURITY.md](SECURITY.md) describes, not in a public issue.
