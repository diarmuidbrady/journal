# Private Journal App

The full build brief is in `SPEC.md`. Read it before starting any work, and re-read the relevant section before each build phase.

## Hard rules

- Privacy requirements in SPEC.md are constraints, not suggestions. All journal processing (transcription, AI, import parsing) happens on the phone.
- No analytics, crash reporting, telemetry or third-party SDKs. No network calls beyond those SPEC.md names. Ask before adding any dependency.
- Never commit real journal data, exports or recordings. Test fixtures must be invented sample entries. Keep `samples/` and any `*.zip` in `.gitignore`.
- No API keys or secrets in the repo.

## How to work

- Before phase 1, ask me about every item under "Open decisions" in SPEC.md that is still unanswered.
- Build one phase at a time, in the order in SPEC.md. Each phase should end with something I can install and use on my phone.
- When SPEC.md names a library or model, check it is current and suggest a better option if one exists.
- If something in SPEC.md is unclear or conflicts with reality, ask rather than guess, and update SPEC.md once we agree.
