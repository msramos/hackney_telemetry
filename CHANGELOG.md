# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2024-07-08
### Changed
- Change project ownership
- Update testing matrix with Erlang 26 and 27 on github CI
- Use telemetry `~> 1.0` instead of `~ 1.0.0`
- Drop `rebar3_steamroll` in favor of `erlfmt`
- Reformat whole project

## [0.1.2] - 2022-09-19
### Changed
- Update docs
- Build docs with ex_doc
- Update specs to successfully run Dialyzer
- Update GitHub action to use caching and run Dializer

## [0.1.1] - 2021-12-10

### Changed
Minor update.

### Fixed
- Fix histogram values shift for `in_use_count` and `free_count metrics`

## [0.1.0] - 2021-12-08

## Added
- First version!
- Metrics collector for hackney global and pool metrics
