# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Current state on `ryok90/guaranate`

`wontfix` already exists. The other four do not yet exist and must be created on
first use:

```bash
gh label create needs-triage    --description "Maintainer needs to evaluate this issue"  --color d4c5f9
gh label create needs-info      --description "Waiting on reporter for more information" --color fef2c0
gh label create ready-for-agent --description "Fully specified, ready for an AFK agent"  --color 0e8a16
gh label create ready-for-human --description "Requires human implementation"            --color 1d76db
```

These are separate from the repo's existing workflow labels (`bug`,
`enhancement`, `documentation`, `question`, `help wanted`, `good first issue`,
`accessibility`, `dependencies`, `skip-changelog`), which classify *what* an issue
is rather than *where it sits in triage*. Both can apply to one issue.
