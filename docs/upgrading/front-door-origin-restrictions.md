# Front Door origin access restrictions

The composition now passes the Front Door profile's `resource_guid` into the app-service module. One resource
owns each origin access-restriction list: the production app and its staging slot both include the same Front
Door ID check. The profile can be created before the app; only the origin needs the app's hostname.

## Existing deployments

No manual state step is needed. The composition still declares the `azapi` provider, so a state written by an
earlier release plans the removal of `azapi_update_resource.app_service_front_door_restriction[0]`. Deleting an
`azapi_update_resource` performs no operation on the target resource
([provider documentation](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/update_resource)),
so that removal changes nothing in Azure.

1. Update the module source, run `terraform init`, and plan through the normal deployment process.
2. Expect, for an otherwise unchanged deployment:
   - one destroy of the old `azapi_update_resource` (no remote change);
   - in-place restriction changes on the app and any existing staging slot. The production list keeps the
     profile GUID and restores the health-probe allow rule if the old patch had removed it. The slot gains the
     same profile GUID. Both keep default action `Deny`;
   - no other resource created, replaced or destroyed.
3. Apply, then plan again. With unchanged inputs and no remote changes, the restriction lists should not change.
   Confirm that `AllowFrontDoor` on the app and any slot carries the profile's `resource_guid`, and that
   `AllowAzureHealthProbe` is present.

The app's in-place update and the removal of the old update resource happen in the same apply, and the app's
new list already carries the Front Door ID check, so there is no window without it. This change renames no
resources and changes no replacement-triggering arguments. A plan against real state needs deployment
credentials; offline mock plans cannot show provider-side replacement behaviour.

## Configuration requirements

`cdn_provider = "azure_front_door"` requires `front_door.enabled = true`. The previously accepted disabled-profile
combination now fails the app's precondition before it changes either list. A standalone app-service caller
must supply a non-empty `front_door_id`, using the profile's `resource_guid`, including when using the legacy
`front_door_enabled` input. A newly created profile may have an unknown GUID during planning; it is resolved
before the app is created, and no empty header list is written.

The app and the staging slot both carry this precondition. With a new profile the GUID is unknown at plan time,
so a missing GUID can fail at apply rather than at plan. If the Front Door profile is ever replaced, its
`resource_guid` changes: the app and slot lists then update in place to the new GUID, and the origin and route
are recreated with the profile.

Cloudflare and direct mode retain their existing rules and defaults.
