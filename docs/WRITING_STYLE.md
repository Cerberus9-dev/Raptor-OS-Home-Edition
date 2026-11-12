# Writing for Raptor OS

Raptor OS documentation should sound like it was written by the people who build and use the project: clear, direct and specific. It does not need to sound like a product launch or a generated report.

## Use everyday language

- Explain what a feature does and where to find it.
- Prefer short, natural sentences over strings of abstract nouns.
- Use the names shown in the app and settings.
- Explain technical terms when readers need them; do not hide important details behind jargon.
- Use contractions when they make the sentence sound natural.

## Be accurate

- Separate what is implemented from what is planned.
- Say which hardware, provider, file format or workflow was actually tested.
- Describe limitations plainly. Do not imply that a workaround is a universal fix.
- Do not claim a build, test, release or hardware check passed until its result is confirmed.
- Keep security, privacy and compatibility claims narrow enough to be true.

## Keep PRs readable

A pull request should tell reviewers what changed, why it changed, and how it was checked. Use a few focused paragraphs or bullets where they help. Avoid padded summaries, repeated conclusions, generic praise, marketing language, and walls of bullets that simply rephrase the diff.

## Keep technical detail where it belongs

README files should help people install, use and troubleshoot Raptor OS. App READMEs should explain the app's actual behavior and current limitations. The changelog should record user-visible changes in concise, concrete language. Put implementation details and test commands near the relevant developer instructions rather than repeating them in every overview.

This applies to new and revised documentation and project-authored pull request descriptions. Historical PRs should be updated when they are revisited; do not rewrite third-party or automated Dependabot descriptions.