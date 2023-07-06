# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.2] - 2023-07-05

### Added

- Add support for FreeBSD as a target.

### Changed

- Remove `:crypto` from the extra applications list, because `:ssl` already includes it.

- Update the guide to mention the new way to select a NIF version in Rustler >= 0.29.

## [0.6.1] - 2023-02-16

### Changed

- Depend on `:ssl` instead of `:public_key` application. Since `:public_key` is started
  with `:ssl`, this shouldn't break. This change is needed in order to support the upcoming
  Elixir 1.15.

## [0.6.0] - 2023-01-27

### Added

- Add support for configuring the NIF versions that the project supports.
  This can be done with the `:nif_versions` config.

- Add support for `castore` version `~> 1.0`.

### Changed

- Add `aarch64-unknown-linux-musl` and `riscv64gc-unknown-linux-gnu` as default targets.
  The first one is common for people running Linux containers that were built with Musl on Apple computers.
  The second one is becoming popular for tiny computers, normally running Nerves.

  The adoption of these targets can increase a little bit the compilation time, but
  can affect a great number of users.

  For package maintainers: please remember to add these targets to your CI workflow.
  See an example workflow at: https://github.com/philss/rustler_precompilation_example/blob/main/.github/workflows/release.yml

- Change the depth of SSL peer verification to "3". This should be more compatible with servers.

- Remove version "2.14" from the default NIF versions. Like the change of default targets,
  this should only have effect in the moment of release of a new package version.
  Remember to update your workflow file.

## [0.5.5] - 2022-12-10

### Fixed

- Add support for Suse Linux targets. This is a fix to the plataform resolution. Thanks [@fabriziosestito](https://github.com/fabriziosestito).
- Fix validation of HTTP proxy. This makes the validation similar to the HTTPS proxy. Thanks [@w0rd-driven](https://github.com/w0rd-driven).
- Map `riscv64` to `riscv64gc` to match Rust naming. Thanks [@fhunleth](https://github.com/fhunleth).

## [0.5.4] - 2022-11-05

### Fixed

- Fix building metadata when "force build" is enabled and the target is not available.

## [0.5.3] - 2022-10-19

### Fixed

- Always write the metadata file in compilation time, so mix tasks can work smoothly.

## [0.5.2] - 2022-10-03

### Fixed

- Fix the `target/0` function to use default targets a default argument. This makes the example
  in the docs work again. Thanks [@jackalcooper](https://github.com/jackalcooper).
- Only use proxy if it is valid. Thanks [@josevalim](https://github.com/josevalim).
- Fix the support for PCs running RedHat Linux. Thanks [@Benjamin-Philip](https://github.com/Benjamin-Philip).
- Improve some points in the docs. Thanks [@whatyouhide](https://github.com/whatyouhide) and [@fabriziosestito](https://github.com/fabriziosestito).

## [0.5.1] - 2022-05-24

### Fixed

- Fix available targets naming to include the NIF version in the name. It was removed accidentally.
  Thanks [@adriankumpf](https://github.com/adriankumpf).

## [0.5.0] - 2022-05-24

### Added

- Now it's possible to configure the targets list, based in the [Rust's Plataform Support](https://doc.rust-lang.org/stable/rustc/platform-support.html)
  list. You can run `rustc --print target-list` to get the full list.
  Thanks [@adriankumpf](https://github.com/adriankumpf).

### Changed

- The precompilation guide was improved with instructions and suggestions for the `files` key at
  the project config.
  Thanks [@nbw](https://github.com/nbw).
- Now we raise with a different error if the NIF artifact cannot be written when downloading to create
  the checksum file.

## [0.4.1] - 2022-04-28

### Fixed

- Fix `__using__` macro for when Rustler is not loaded.

## [0.4.0] - 2022-04-28

### Changed

- Make Rustler an optional dependency. This makes installation faster for most of the users.

## [0.3.0] - 2022-03-26

### Added

- Add the possibility to skip the download of unavailable NIFs when generating the
  checksum file - thanks [@fahchen](https://github.com/fahchen)

## [0.2.0] - 2022-02-18

### Fixed

- Fix validation of URL in order to be compatible with Elixir ~> 1.11.
  The previous implementation was restricted to Elixir ~> 1.13.

### Added

- Add `:force_build` option that fallback to `Rustler`. It passes all options
  except the ones used by `RustlerPrecompiled` down to `Rustler`.
  This option will be by default `false`, but if the project is using a pre-release,
  then it will always be set to `true`.
  With this change the project starts depending on Rustler.

### Changed

- Relax dependencies to the minor versions.

## [0.1.0] - 2022-02-16

### Added

- Add basic features to download and use the precompiled NIFs in a safe way.

[Unreleased]: https://github.com/philss/rustler_precompiled/compare/v0.6.2...HEAD
[0.6.2]: https://github.com/philss/rustler_precompiled/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/philss/rustler_precompiled/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/philss/rustler_precompiled/compare/v0.5.5...v0.6.0
[0.5.5]: https://github.com/philss/rustler_precompiled/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/philss/rustler_precompiled/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/philss/rustler_precompiled/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/philss/rustler_precompiled/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/philss/rustler_precompiled/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/philss/rustler_precompiled/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/philss/rustler_precompiled/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/philss/rustler_precompiled/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/philss/rustler_precompiled/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/philss/rustler_precompiled/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/philss/rustler_precompiled/releases/tag/v0.1.0
