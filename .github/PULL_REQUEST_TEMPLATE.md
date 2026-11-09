<!-- Thanks for contributing to Galleria! 🎉 -->

## What

<!-- What does this PR change? One or two sentences. Fix #<issue number> if relevant. -->

## Why

<!-- What problem does it solve, or what does it improve? Screenshots welcome. -->

## How tested

- [ ] `./Scripts/build.sh` succeeds (Command Line Tools, no Xcode needed)
- [ ] I ran the change in `open dist/Galleria.app` and checked the affected flow
- [ ] No new console warnings, no crash reports

## Notes for reviewers

- Galleria keeps **originals untouched** — verify your change doesn't write to library folders.
- Keep `Sources/` dependency-free (Swift + Apple frameworks only).
