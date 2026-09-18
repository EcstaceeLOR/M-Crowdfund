# Milestone Crowdfunding

A Foundry implementation of an ERC-20 crowdfunding platform that releases successful campaign funds in ordered, approved milestones.

## Requirements covered

- Create campaigns with a target, deadline, accepted ERC-20 token, milestones, and milestone amounts.
- Track each contributor and reject contributions at/after the deadline.
- Require the funding target before milestone approval/release.
- Enforce milestone ordering.
- Release exactly the amount assigned to an approved milestone.
- Allow refunds when:
  - the deadline is reached without meeting the target,
  - the creator cancels before any release, or
  - the platform owner activates the exceptional refund condition.
- Prevent duplicate refunds while keeping original contribution accounting intact.
- Emit events for campaign creation, contributions, approvals, releases, cancellation, refund activation, and refunds.
- Guard token-moving functions against reentrancy and reject fee-on-transfer behavior on contribution.

## Design notes

The campaign `target` also acts as the funding cap. Milestone amounts must be non-zero and sum exactly to the target, so every accepted contribution is accounted for as either escrowed, released, or refunded.

The contract owner acts as the milestone approver. Campaign creators can release only the currently approved milestone and can cancel only before any funds have been released. The owner can enable the exceptional refund condition only before a release has occurred.

## Run tests

```bash
forge test -vvv
```

The test suite proves target success/failure, duplicate-refund prevention, milestone ordering, partial milestone release, unauthorized approval rejection, cancellation refunds, explicit refund conditions, deadline enforcement, and contribution conservation.
