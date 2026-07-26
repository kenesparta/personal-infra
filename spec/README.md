# Spec: `personal-infra`

Terraform + Ansible project provisioning a single-host, multi-project application server on AWS Lightsail, and
consolidating all `kenesparta.dev` AWS infrastructure into one state.

**Status:** Draft (rev 2 — migration) **Owner:** kenesparta **Target:** `kenesparta.dev` + up to 3 further Rust projects

One file per numbered section; the numbering is stable and is what code comments cite (`spec §5.3`). The spec is the
source of truth — see [§1](01-purpose.md): if implementation needs something not described here, amend the spec first.

## Sections

| §  | File                                       | Contents                                                       |
|----|--------------------------------------------|----------------------------------------------------------------|
| 1  | [Purpose](01-purpose.md)                   | What is being built, and what is being migrated in             |
| 2  | [Constraints](02-constraints.md)           | C1–C10 — fixed inputs, not preferences                          |
| 3  | [Architecture Decisions](03-decisions.md)  | AD-1–AD-10 — what was chosen *and what was rejected*            |
| 4  | [Scope Boundary](04-scope.md)              | Terraform-managed / Ansible-managed / neither                   |
| 5  | [Resource Specification](05-resources.md)  | Providers, backend, `projects.yml`, instance, firewall, DNS     |
| 6  | [Repository Layout](06-layout.md)          | File tree, and why it is flat                                   |
| 7  | [Variables](07-variables.md)               | Terraform inputs                                                 |
| 8  | [Outputs](08-outputs.md)                   | Terraform outputs — never secrets                                |
| 9  | [Ansible Specification](09-ansible.md)     | Inventory handoff, the seven roles, A1–A6 conventions            |
| 10 | [Migration Phases](10-phases.md)           | Phase 0–9, in order, each with its verification gate             |
| 11 | [Acceptance Criteria](11-acceptance.md)    | The 14 checks that define "done"                                 |
| 12 | [Gotchas](12-gotchas.md)                   | G1–G13 — failure modes not obvious from any single file          |
| 13 | [Out of Scope](13-out-of-scope.md)         | Deferred, with the trigger to reconsider each                    |
| 14 | [Cost Model](14-cost.md)                   | Current vs target monthly spend                                  |

## Stable IDs

Terraform and Ansible comments cite these rather than section numbers, so they survive re-ordering:

| Prefix     | Meaning              | Defined in                              |
|------------|----------------------|-----------------------------------------|
| `C<n>`     | Constraint           | [§2](02-constraints.md)                 |
| `AD-<n>`   | Architecture decision| [§3](03-decisions.md)                   |
| `A<n>`     | Ansible convention   | [§9.4](09-ansible.md#94-conventions)    |
| `G<n>`     | Gotcha               | [§12](12-gotchas.md)                    |
| `Phase <n>`| Migration phase      | [§10](10-phases.md)                     |
