# HIR origin type-presence ABI fix

## Problem

`Vizg_HirRecord.type_id` used zero for an absent origin type. Because zero is a
legal `TypeId`, an API consumer could not distinguish absence from `TypeId(0)`.

## Change

HIR record API v2 now sets origin-record `flags` bit 0 exactly when `type_id`
is present. The existing field contains the identity in that case and remains
zero when the flag is clear.

## Compatibility

The change uses an existing record field and does not alter the official ABI v1
layout. Requests for HIR record API v1 retain the prior zero flag behavior.

## Validation

The ABI lifecycle regression checks v2 presence reporting and preserved v1
behavior. The repository test, validation, header, formatting, and diff checks
must pass before this fix is considered complete.
