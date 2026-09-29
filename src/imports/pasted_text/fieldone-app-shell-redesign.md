Fix the FieldOne app shell first — P0. The current navigation is conceptually confused: the screen is called Inventory Home but Home is active, Customers routes to Sync Center, and Work routes straight to Cycle Count. Decide clearly that FieldOne has a shared shell and Inventory is one module inside it. When the user is inside Inventory, Inventory should visibly be the active module. Navigation should also be permission/role-aware; an inventory officer does not need Customers occupying prime navigation just to prove FieldOne has a Customers module.
Redesign Inventory Home around work, not statistics — P0. Remove the four generic action tiles and the 96 Total stock / 24 Low stock / 4 Exceptions dashboard. “Total stock” is especially misleading because units cannot simply be added together. The V2 hierarchy should be current location, online/offline state, one prominent Scan action, Assigned Work, Exceptions requiring attention, then perhaps recent activity. The first question answered should be “What do I need to do?”, not “How much inventory exists?”
Design a real Work / Tasks screen — P0. FieldOne is execution-oriented, so assigned work deserves its own experience. Show Today, Upcoming and Requires Attention. A task row should include task type, document reference, location, due time, priority, progress and status. Examples would be Receive TR-00291 · 18/24 lines · Due 11:30, Dispatch SO-18420 · High priority, and Cycle Count CC-0093 · Zone B · 5/8 counted. This becomes a shared FieldOne pattern later for sales visits, collections and other field work.
Design a universal Scan experience — P0. Scan should be a genuine system action, not only a barcode illustration inside Receive. It should support product/SKU scanning and, where appropriate, document/location scanning. Show camera state, torch, manual entry, permission denied, invalid code, unknown item, duplicate/repeated scan protection, success feedback and the resulting action. Context matters: scanning during Receive should mean “receive this line”; scanning during Dispatch should mean “pick this line.”
Redesign Receive Transfer around the actual transfer document — P0. V1 shows one warehouse and a scanner. V2 should establish the operation first: TR-00291, Main Depot → Ikeja Central Warehouse, status, assignment, 18/24 lines received, progress and remaining lines. The worker must always know what document they are executing, where stock is coming from and where it is going.
Design the Receive execution state — P0. Once scanning begins, show the current transfer line: item name, SKU/UOM, expected quantity, received quantity, variance, destination bin/location if relevant and scan confirmation. Do not make “items received” just a generic successful list. Every received quantity should clearly belong to a line in the document.
Design Receive exceptions properly — P0. V2 needs actual operational exception states: shortage, overage, damaged, wrong item, extra/unexpected item and possibly wrong location. Each should show what happened, what FieldOne expects the user to do next, reason selection, optional notes/evidence, and whether approval is required. Unknown barcodes must never silently become new stock.
Add Review & Complete before a receipt is posted — P0. V1 jumps from scanning to Complete Receive. V2 should have a final review showing matched lines, shortages, overages, damaged items and unresolved issues. The button should communicate the actual action—such as Post Receipt or Complete Receipt—and FieldOne should distinguish “saved offline” from “confirmed by server.” This is a key trust screen.
Redesign Dispatch as a picking workflow — P0. Establish SO-18420, source location, destination/customer/site, due information and progress. Then focus on the current pick line: item, SKU/UOM, aisle/bin, requested, picked and available. The primary action becomes Scan to Pick. Completed and remaining lines should be visible without overwhelming the screen.
Design Dispatch shortage and fulfilment exceptions — P0. The current prototype simply shows progress. V2 needs situations such as requested 10 / available 4, reserved stock unavailable, wrong item scanned, damaged unit found, partial fulfilment and picking from an alternative bin. The UI should provide an explicit resolution path rather than merely turning something red.
Completely redesign Cycle Count — P0. This is currently the weakest core screen because the prototype already knows both “expected” and “counted.” In V2, the user must actually perform the count. Prefer a blind-count experience where policy requires it: show item and location, let the worker scan/count, then reveal the variance after submission. The core control should be Counted Quantity, not a prefilled variance card.
Design discrepancy, recount and approval states — P0. If expected is 10 and counted is 8, then show 2 short and require an appropriate reason. If expected equals counted, do not show a shortage selector at all. Include Shortage, Overage, Damaged, Misplaced, Recount Required and similar reasons. Support recount requested, supervisor review if needed, and resolved states.
Create proper Inventory Browse/Search — P1. “Find Item” should stop opening the first hard-coded item. Design search by name, SKU or barcode, useful filters, stock/location status and search results. Provide zero-result, offline-search and barcode-search states. This is the actual entry point into inventory visibility.
Upgrade Item Detail into an inventory truth screen — P1. Keep the current visual structure, but show meaningful stock states: On Hand, Available, Reserved, In Transit, Damaged and Blocked. Then Stock by Location and Recent Movements. Do not fabricate Available = total - 6; the UI should be designed around values coming from authoritative inventory state. UOM also needs to be explicit wherever quantity is shown.
Design Location Detail and stock drill-down — P1. From Stock by Location, the user should be able to open a warehouse/site/bin and understand this item's state there: on-hand, reserved, available, damaged/blocked, recent movements and pending operations. This becomes especially important when FieldOne supports depots, branches, project sites, vehicles and other field locations.
Design Transfer Detail as a lifecycle screen — P1. A transfer should have a home of its own, not exist only while scanning. Show source, destination, assignment, status, created/due dates, line progress, discrepancies and history. Design states such as Draft/Assigned, In Transit, Receiving, Partially Received, Completed, Cancelled and Exception. Only actions valid for the current lifecycle should be visible.
Make Sync Center operation-based instead of module-based — P0. The current Inventory synced 2 min ago / Customers synced 5 min ago approach is too generic. The thing a field worker cares about is their work. Show operations like Receipt TR-00291 — Saved locally, Cycle Count CC-0093 — Queued, Dispatch SO-18420 — Awaiting confirmation. Clearly distinguish Local, Queued, Syncing, Confirmed, Failed and Conflict.
Design Conflict Resolution properly — P0. This is one of FieldOne's differentiators and deserves a real UI. Show exactly what conflicts: item/document, local version, server version, timestamps/revisions and what resolution options are allowed. Do not silently choose one. The UI should reassure the user that offline work has not been lost while also making it clear when server confirmation is still pending.
Design Transaction History / Audit Trail — P1. V2 needs more than Recent Movements. Create a proper history screen with Receipts, Dispatches, Transfers, Counts and Adjustments. Every row should establish type, reference, location movement where applicable, user, time and sync/confirmation status. Opening an entry should show the underlying transaction, not merely another item card.
Design inventory adjustments and damaged/blocked stock — P1. Because Item Detail will expose Damaged and Blocked quantities, users need a coherent path for how stock enters those states. Design controlled adjustment/quarantine flows with quantity, location, reason, note/evidence, authorization and resulting status. Do not make arbitrary +/- quantity editing a normal inventory feature.
Add explicit success and completion screens/states — P1. A snackbar is not enough for important stock movements. For Receive, Dispatch and Count, show a concise completion state containing document number, result, exceptions, whether it is saved locally or server-confirmed, and the logical next action. “Saved offline” and “Completed on server” must never look identical.
Design offline behavior across every core screen — P0. Do not treat offline as something users only see inside Sync Center. Home, Receive, Dispatch and Count need restrained indicators such as Offline · Work will be saved on this device, 3 operations pending, or Last synced 08:14. Offline is supported behavior, not an error. A failed write or conflict, however, is an error and should look different.
Design all non-happy states — P1. V1 mostly shows ideal data. V2 needs loading/skeleton, empty assignment list, no search result, no camera permission, camera unavailable, invalid barcode, unknown barcode, duplicate scan, no connectivity, pending upload, sync failure, conflict, stale document, insufficient stock, unauthorized operation, completed/read-only document and cancelled document. These states are where enterprise software either feels trustworthy or falls apart.
Standardize the V2 component system — P1. Create reusable Figma components for FieldOne app header, module context, location selector, sync indicator, task row, document header, item row, scanner, quantity control, progress indicator, exception panel, status chip, reason selector, sticky action bar, movement row and confirmation panel. Define their variants before making dozens of screen copies. This will also help Field Sales, Orders and other FieldOne modules later.
Tighten typography and touch accessibility — P1. Several current labels are around 10.5–11.5px. Increase essential field text. Use roughly 14–16px for operational content, reserve 12–13px for metadata, and keep strong contrast. Touch targets should remain around 44px minimum. The design should work while standing, moving, in bright light and potentially using one hand.
Reduce decorative card nesting — P2. The visual language is already restrained, but V2 can become even more premium by using fewer rounded containers. Use page structure, dividers and whitespace for ordinary information; reserve cards/panels for document context, important grouped information and exceptions. Normal information should feel quiet so exceptions become obvious.
Make fixtures internally consistent before presenting V2 — P1. The current prototype has different stock figures and generic movement/location arrays regardless of item. V2's prototype data should tell one coherent story across Home, Receive, Dispatch, Count, Item Detail and Sync Center. If TR-00291 receives 12 bulbs, Item Detail and history should reflect the same transaction. This matters even in Figma because inconsistent numbers make the product logic look unreliable.
Design with the real domain model in mind without exposing its complexity — P0. The interface does not need to show ledger revisions, reservations, authoritative stock calculations or idempotency keys, but it must respect them. For example, Available should differ from On Hand when stock is reserved; In Transit should remain separate until receipt; a pending offline operation should not be shown as server-confirmed; and a count discrepancy should not silently mutate stock. The UI can remain simple while the model underneath is serious.
Core screens I expect in the V2 Figma file

You do not need 40 unique screens. Several can be component variants.

Area	Key designs
FieldOne shell	Shared app navigation, role/location context
Inventory Home	Assigned work + Scan + Exceptions
Work	Today / Upcoming / Requires Attention
Scan	Ready / Success / Error / Manual
Receive	Overview / Execute / Exception / Review / Complete
Dispatch	Overview / Pick / Shortage / Review / Complete
Cycle Count	Assignment / Count / Variance / Recount / Complete
Inventory	Search/Browse / Results
Item	Item Detail / Stock by Location
Transfers	Transfer Detail + lifecycle variants
Sync	Queue / Offline / Syncing / Failed
Conflict	Local vs server resolution
History	Transaction list / Transaction detail
Adjustments	Damage / Block / Adjustment
System states	Empty / Loading / Permission / Error

That is the real V2 scope.

State language to standardize

This deserves special attention because V1 currently mixes concepts.

Type	Recommended states
Connectivity	Online / Offline
Local operation	Draft / Saved locally
Sync	Queued / Syncing / Confirmed / Failed / Conflict
Task	Assigned / In progress / Completed / Overdue / Cancelled
Transfer	Assigned / In transit / Receiving / Partial / Completed / Exception
Count	Assigned / Counting / Variance / Recount / Submitted / Approved
Stock	Available / Reserved / In transit / Damaged / Blocked

Do not use “Completed”, “Saved locally” and “Synced” interchangeably. They mean different things.

What I would remove from V1
V1 element	V2 treatment
96 Total stock	Remove
4 equal Home action tiles	Replace with Scan + assigned work
Recent items on main Home	Lower priority or move to Inventory
Generic per-module sync list	Replace with operation queue
Prefilled Cycle Count values	Replace with actual count entry
Variance reason when variance = 0	Never show
Customers tab opening Sync	Remove fake navigation
Work tab opening Cycle Count	Build real Work screen
Find Item opening first item	Build search
Receive only showing destination	Show source → destination
Complete Receive immediately returning Home	Add review + result
Same location/history data for every item	Use coherent fixtures