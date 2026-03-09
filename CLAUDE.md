# Project Instructions for Claude

## Context Rules
- `.autopilot/` is an internal pipeline for auto-generating the `justfile`. Do NOT read or modify files in this directory.
- `.github/workflows/` contains CI automation. Do NOT modify unless explicitly asked.
- The `justfile` at the project root defines all available dev commands. Always reference it to understand how to run, build, test, and deploy this project.

## Using the Justfile
Run `just --list` to see all available commands. Common ones:
- `just dev` — Start development servers
- `just build` — Build the project
- `just test` — Run tests
- `just clean` — Clean build artifacts
- `just check-env` — Verify environment variables
