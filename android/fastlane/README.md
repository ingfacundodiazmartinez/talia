fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android validate

```sh
[bundle exec] fastlane android validate
```

Verify the service account has publishing permissions

### android internal

```sh
[bundle exec] fastlane android internal
```

Upload AAB to internal testing track

### android production_draft

```sh
[bundle exec] fastlane android production_draft
```

Upload AAB to production track as draft (review the release in Play Console before rollout)

### android production_submit

```sh
[bundle exec] fastlane android production_submit
```

Upload AAB to production and immediately submit for review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
