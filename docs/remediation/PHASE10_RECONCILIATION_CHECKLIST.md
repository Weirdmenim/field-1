# Phase 10 Inventory Reconciliation Checklist

The automated check is `scripts/phase10_reconcile.sh`. Human review supplements it.

- [ ] Deprecated `inventory_balances.reserved_base_qty` is zero everywhere.
- [ ] No policy-invalid negative balance exists; negative AVAILABLE is present only where explicitly allowed.
- [ ] Reservation fulfilled/released totals never exceed reserved quantity.
- [ ] Active reservation remainder never exceeds non-negative AVAILABLE physical stock for company/location/product.
- [ ] Transit received + lost never exceeds dispatched transit quantity.
- [ ] Sales posted <= captured and posted + backordered <= requested.
- [ ] Transfer received/shipped quantities do not exceed expected quantities.
- [ ] Every completed document command has a successful terminal result and completion timestamp.
- [ ] No document command remains PROCESSING beyond the operational threshold.
- [ ] Completed sales documents contain no unresolved requested quantity.
- [ ] Sample movement-to-document provenance for receipt, dispatch, count and reversal is traceable end-to-end.
- [ ] Compare pre/post migration aggregate physical stock by company/location/product/status and investigate every unexplained delta.
- [ ] Compare pre/post active reservation remainder and in-transit custody; investigate every unexplained delta.
- [ ] Capture reconciliation SQL output and reviewer sign-off with release evidence.
