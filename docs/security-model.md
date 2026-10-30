# Security model

This page explains what the `wordpress-site` module protects, where its trust boundaries
are, and what you must protect yourself. Read it before you deploy a site to production.

To report a vulnerability, see [SECURITY.md](../SECURITY.md). For the components, the request
flows and the network layout, see [Architecture](architecture.md). To deploy, start with
[Getting started](getting-started.md) and the [Deployment guide](deployment-guide.md).

> **Version.** This page describes v4.3.0. Every `file:line` reference points to commit
> [`b592e13`](https://github.com/agenticcodingops/azure-wordpress/tree/b592e13ad09938075b0e8f7a1dd51cfbe007320b).
> Line numbers can move in later releases. Where this page could not confirm a fact
> from the code or from vendor documentation, it says **UNKNOWN**.

## Contents

- [At a glance](#at-a-glance)
- [Trust boundaries](#trust-boundaries)
- [What the module enforces](#what-the-module-enforces)
- [What the module does not cover](#what-the-module-does-not-cover)
- [Terraform state holds generated secrets](#terraform-state-holds-generated-secrets)
- [Unknowns](#unknowns)
- [References](#references)

## At a glance

| Control | Default | You must act? |
| --- | --- | --- |
| Origin admits only the CDN's network | Off: `cdn_provider` defaults to `"direct"`, which admits everyone | Yes. Set `cdn_provider` |
| Key Vault data plane denies public access | On | Allow-list the deploying principal |
| Storage data plane denies public access | On | Yes, if media is served from the blob endpoint: set `storage_network_rules_default_action = "Allow"`, which is necessary but not sufficient, because the account disallows anonymous reads. Before go-live, load an uploaded media URL in a signed-out browser; unsigned URLs fail. See [Unknown 8](#unknowns) and [Storage](#key-vault-and-storage-deny-public-access-by-default) |
| SCM (Kudu) restricted to an allow-list | Off: default action `Allow` | Yes. Set the SCM variables |
| FTP | Off at the transport layer | No |
| Basic-auth publishing credentials | On | Turn off if you can |
| Key Vault references resolved by managed identity | On | No |
| MySQL has no public endpoint | On | No |
| TLS required on MySQL connections | Off | Optional: `mysql_require_secure_transport = true`. See [Not covered](#mysql-connections-do-not-require-tls) |
| WordPress logs in to MySQL with a password, as the administrator | On | Optional: the staged passwordless path, `mysql_entra_stage_*`. See [WordPress connects as the server administrator](#wordpress-connects-as-the-server-administrator) |
| Storage account key written to Key Vault (`storage-key`) | On | Optional: `storage_key_secret_enabled = false`, once the `MICROSOFT_AZURE_*` settings are off |
| Backup container SAS | None: `app_service_backup_enabled` is off | Optional. When on, the module signs and rotates it; it is never an output |
| Certificate for the custom domain on App Service | Not managed by the module | Yes, with `cdn_provider = "direct"` and a `custom_domain` of your own (not `*.azurewebsites.net`, for which the module creates no binding, `modules/wordpress-site/main.tf:1128`). See [TLS settings](#tls-settings) |
| Terraform state protected | Not managed by the module | Yes. See [Terraform state](#terraform-state-holds-generated-secrets) |

## Trust boundaries

The module draws five boundaries. Each one has its own guard, and a guard on one does not
protect another.

```mermaid
flowchart LR
    visitor(["Visitor browser"])
    other(["Another tenant of the same CDN"])
    operator(["Operator or CI runner"])

    subgraph edge["Edge"]
        cdn["Cloudflare zone or Front Door profile<br/>TLS to visitors, optional WAF"]
    end

    subgraph origin["Origin: App Service public endpoint"]
        rules{"Access restrictions"}
        app["Web app and staging slot<br/>WordPress container"]
    end

    subgraph scm["SCM plane"]
        kudu["Kudu for the app and the slot<br/>own rules, default Allow"]
    end

    subgraph data["Data plane"]
        kv[("Key Vault<br/>firewall default Deny")]
        st[("Storage account<br/>firewall default Deny")]
        db[("MySQL Flexible Server<br/>delegated subnet, no public endpoint")]
    end

    subgraph tfstate["Terraform state"]
        tfs[("State file in your backend<br/>holds secrets in plain text")]
    end

    arm["Azure Resource Manager<br/>control plane"]

    visitor -->|"HTTPS"| cdn
    cdn -->|"forwarded request"| rules
    visitor -.->|"when cdn_provider = direct, the default"| rules
    other -.->|"shares the CDN's egress addresses"| rules
    rules -->|"allowed"| app
    operator -->|"HTTPS and credentials"| kudu
    kudu -.->|"shell and file access"| app
    app -->|"VNet integration and service endpoint"| kv
    app -->|"VNet integration and service endpoint"| st
    app -->|"TCP 3306 inside the VNet"| db
    visitor -.->|"media URLs, only if storage allows"| st
    operator -->|"terraform apply"| arm
    operator -->|"secret writes need an allow-list entry"| kv
    operator <-->|"read and write"| tfs
```

| Boundary | What crosses it | What guards it |
| --- | --- | --- |
| Edge | Visitor requests | The CDN you choose. The module can add WAF rules on Front Door, and on Cloudflare when `enable_waf = true`. See [Edge](#edge). |
| Origin | Requests from the CDN to `app-<project_name>-<site_name>-<np\|prod>.azurewebsites.net` | App Service access restrictions on the app and the slot. See [Origin restricted to the CDN](#origin-restricted-to-the-cdn). |
| SCM plane | Kudu, deployment and SSH console traffic | A separate rule list, and authentication. See [SCM plane](#scm-plane). |
| Data plane | Secret reads, media reads and writes, database queries | Key Vault and Storage firewalls, the delegated MySQL subnet, and Key Vault access policies. See [Key Vault and Storage](#key-vault-and-storage-deny-public-access-by-default) and [Database network](#database-network). |
| Terraform state | Every attribute Terraform manages, secrets included | Your backend. The module does not manage it. See [Terraform state](#terraform-state-holds-generated-secrets). |

Azure Resource Manager (the control plane) sits outside all five. Key Vault and Storage
firewalls apply only to their data planes. Microsoft states that Key Vault control-plane
operations "are not affected by firewalls and virtual network rules"
([Key Vault service endpoints](https://learn.microsoft.com/en-us/azure/key-vault/general/overview-vnet-service-endpoints)).
The storage module notes the same for container management (`modules/storage/main.tf:34-37`).
Control-plane access is governed by Azure RBAC on the subscription, which you manage.

## What the module enforces

### Origin restricted to the CDN

The origin is restricted only when you choose a CDN. `cdn_provider` defaults to
`"direct"` (`modules/wordpress-site/variables.tf:532-541`). With `"direct"`, the
unmatched-rule action is `Allow`, so anyone can reach the app
(`modules/app-service/main.tf:320`).

**With `cdn_provider = "cloudflare"`**, the app and its staging slot each get:

- an allow rule for the Azure health probe address `168.63.129.16/32` at priority 10
  (`modules/app-service/main.tf:262-267`, slot `:503-508`);
- an allow rule for every Cloudflare IPv4 range (`modules/app-service/main.tf:270-285`, slot
  `:510-525`) and every IPv6 range (`:288-303`, slot `:527-542`);
- `Deny` for everything else (`modules/app-service/main.tf:320`, slot `:563`).

The ranges are read on every run from Cloudflare's published list
(`modules/wordpress-site/main.tf:52-54` and `:655-656`). A built-in list is the fallback
when the module is used on its own (`modules/app-service/main.tf:37-65`). These rules
depend only on `cdn_provider`. They apply even when `cloudflare.enabled` is `false` and the
module manages no Cloudflare resources (`modules/wordpress-site/main.tf:197`). Cloudflare's
ranges are shared by every Cloudflare account; see
[Binding the origin to one CDN account](#binding-the-origin-to-one-cdn-account).

When `app_service.cdn_origin_header_name` is set, every Cloudflare IPv4 and IPv6 rule on the app and slot also
requires one of the sensitive `cdn_origin_header_values`. The health-probe and SCM rules are unchanged. The name,
not the sensitive values, controls whether the header block exists. The default is `null`, preserving IP-only
rules and existing plans.

**With `cdn_provider = "azure_front_door"`**:

- The app and the slot allow the health probe address above and the
  `AzureFrontDoor.Backend` service tag, and deny the rest
  (`modules/app-service/main.tf:306-320`, slot `:550-563`).
- The service tag covers every Front Door instance, not only yours. A second step pins the
  main app to your instance: after Front Door exists, `azapi_update_resource` replaces the
  app's rule list with one rule that also requires your profile's GUID in the `X-Azure-FDID`
  header, followed by a deny-all rule (`modules/wordpress-site/main.tf:1017-1055`). This
  replacement list carries no health-probe rule.
- The staging slot does not get that header check. Any Front Door instance can reach it
  (`modules/app-service/main.tf:544-549`).
- Until the update resource has run, the main app's Front Door rule carries an empty
  header list (`modules/app-service/main.tf:314`, with `front_door_id` never passed in,
  `modules/wordpress-site/main.tf:645-648`). In that window it admits any Front Door
  instance, as the comment at `modules/wordpress-site/main.tf:1015` warns.
- The web app resource manages the whole rule list and does not ignore changes to it
  (`modules/app-service/main.tf:397-454`, `ignore_changes` `:450-453`). Whether a later apply removes the header check
  again is **UNKNOWN**; see [Unknowns](#unknowns).
- The origin rules follow `cdn_provider` alone (`modules/wordpress-site/main.tf:647`).
  Front Door itself, and the header update, also need `front_door.enabled`, which defaults
  to `true` (`modules/wordpress-site/main.tf:185`, `:960`, `:1018`). With
  `cdn_provider = "azure_front_door"` and `front_door.enabled = false`, the app admits every
  Front Door instance and never gets the header check.

Microsoft documents the service-tag-plus-header pattern in
[Access restrictions](https://learn.microsoft.com/en-us/azure/app-service/overview-access-restrictions#restrict-access-to-a-specific-azure-front-door-instance).

Access restriction rules belong to the site, not to a host name. The rules above therefore
also govern requests to the default `*.azurewebsites.net` host name.

**The app-subnet network security group does not filter visitors.** The networking module
attaches an NSG with inbound rules to the App Service integration subnet
(`modules/networking/main.tf:86-134`, `:173-177`). Those inbound rules have no effect on
traffic to the app. Microsoft:

> "Routes don't apply to replies from inbound app requests and inbound rules in an NSG
> don't apply to your app. Virtual network integration affects only outbound traffic from
> your app. To control inbound traffic to your app, use the access restrictions feature or
> private endpoints."
> ([Virtual network integration](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration#network-routing))

The NSG declares no outbound rules, so Azure's default outbound rules apply: allow to the
virtual network, allow to the internet
([NSG default rules](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview#default-security-rules)).

### SCM plane

Kudu (the SCM site) is a separate gate from the rules above. The app and the slot each
have their own Kudu endpoint. Microsoft:
"The advanced tools site, which is also known as scm or kudu, has an individual rules
collection that you can configure"
([Access restrictions](https://learn.microsoft.com/en-us/azure/app-service/overview-access-restrictions#restrict-access-to-the-advanced-tools-site)).

What the module sets:

- **FTP is off at the transport layer.** `ftps_state = "Disabled"` on the app and the slot
  (`modules/app-service/main.tf:236`, `:493`).
- **The SCM rule list is yours to set, and it is empty by default.**
  `app_service_scm_ip_restrictions` defaults to `[]` and
  `app_service_scm_ip_restriction_default_action` to `"Allow"`
  (`modules/wordpress-site/variables.tf:319-355`). Both apply to the app and the slot
  (`modules/app-service/main.tf:332-345`, slot `:568-581`). With the defaults, Kudu is
  reachable from the internet and protected only by authentication.
- **Basic-auth publishing credentials are on by default.**
  `app_service_ftp_publish_basic_authentication_enabled` and
  `app_service_webdeploy_publish_basic_authentication_enabled` both default to `true`
  (`modules/wordpress-site/variables.tf:357-367`). Both apply to the app and the slot
  (`modules/app-service/main.tf:211-212`, `:471-472`).
- **SCM never inherits the main site's rules.** The module leaves
  `scm_use_main_ip_restriction` at its provider default, `false`
  (`modules/app-service/main.tf:325-328`). With a CDN set, inheriting would lock operators
  out of Kudu.

Hardening SCM is therefore opt-in. The
[app-service README](../modules/app-service/README.md#scmkudu-network-posture) and the v3-to-v4
upgrade guide's [Hardening the SCM/Kudu endpoint](upgrading/v3-to-v4.md#hardening-the-scmkudu-endpoint)
explain how to restrict it without losing the SSH console, and
[Publishing Credentials](../modules/app-service/README.md#publishing-credentials) explains
what breaks when you turn basic auth off.

### Key Vault and Storage deny public access by default

**Key Vault.**

- The vault firewall denies by default. `network_acls.default_action` is `Deny` unless you
  set `key_vault_public_network_access_enabled = true`
  (`modules/key-vault/main.tf:54-59`; `modules/wordpress-site/variables.tf:231-235`).
- The site's App Service subnet is always allow-listed
  (`modules/wordpress-site/main.tf:555-558`). That subnet carries the `Microsoft.KeyVault`
  service endpoint (`modules/networking/main.tf:49-51`).
- `bypass = "AzureServices"` is set (`modules/key-vault/main.tf:55`). This does **not**
  admit App Service Key Vault references. Microsoft lists App Service as trusted "only for
  Deploying Azure Web App Certificate through Key Vault"
  ([trusted services](https://learn.microsoft.com/en-us/azure/key-vault/general/overview-vnet-service-endpoints#trusted-services)).
  References reach the vault through the allow-listed subnet instead. The code comment at
  `modules/key-vault/main.tf:50-51` says otherwise; the Microsoft table is the authority.
- Terraform is not a trusted service. Its secret writes need an entry in
  `key_vault_network_acls_ip_rules`, a runner subnet that carries the `Microsoft.KeyVault` service endpoint, listed in
  `key_vault_network_acls_virtual_network_subnet_ids`, or public access turned on
  (`modules/wordpress-site/variables.tf:231-247`).
- The vault uses access policies, not Azure RBAC (`modules/key-vault/main.tf:45`).
- Purge protection is on in production and off in nonprod, unless you set it
  (`modules/wordpress-site/main.tf:152-155`).

**Storage.**

- The storage firewall denies by default.
  `storage_network_rules_default_action` defaults to `"Deny"`
  (`modules/wordpress-site/variables.tf:273-282`; `modules/storage/main.tf:38-43`).
- The App Service subnet is always allow-listed (`modules/wordpress-site/main.tf:492-495`).
  It carries the `Microsoft.Storage` service endpoint (`modules/networking/main.tf:45-47`).
- With `cdn_provider = "cloudflare"`, Cloudflare's IPv4 ranges are allow-listed too
  (`modules/wordpress-site/main.tf:488-491`).
- Anonymous public access to blobs is off for the whole account:
  `allow_nested_items_to_be_public = false` (`modules/storage/main.tf:28`). The uploads container is private
  (`modules/storage/main.tf:91`).
- Shared-key access stays on (`modules/storage/main.tf:29`), because the module-generated SAS of the
  scheduled App Service backup and the optional `MICROSOFT_AZURE_ACCOUNT_KEY` app
  setting both use the account key. `storage_key_secret_enabled = false` stops
  writing that key to Key Vault; it needs `app_service_storage_plugin_app_settings_enabled = false`
  first. See [Retiring the `storage-key` secret](../README.md#retiring-the-storage-key-secret).
- Infrastructure (double) encryption is on (`modules/storage/main.tf:32`).
- The SAS expiry policy is 7 days with action `Log` (`modules/storage/main.tf:46-49`).
  With `Log`, "requests made with out-of-policy SAS are allowed"; they are only logged, and
  only if blob logs go to Azure Monitor
  ([SAS expiration policy](https://learn.microsoft.com/en-us/azure/storage/common/sas-expiration-policy#define-the-sas-expiration-action)).
  The policy does not limit the account key itself, which the backup SAS is signed with and which
  the optional `MICROSOFT_AZURE_ACCOUNT_KEY` setting carries (`modules/app-service/main.tf:128`).

By default no browser reads the blob endpoint: media stays on the web app's `/home` storage, the
module installs no plugin, and the backup uses the VNet path, so `Deny` is viable. Only a Blob
offload plugin you install points media URLs at the blob endpoint, and then the firewall is one of
two gates on media that browsers fetch from it. `Deny` refuses those browsers, so that design needs `Allow`. `Allow` is not enough on its
own: the account disallows anonymous blob access (`modules/storage/main.tf:28`) and the
uploads container is private (`modules/storage/main.tf:91`). Microsoft states that once
anonymous access is disallowed for the account, "any future anonymous requests to that
account fail"
([anonymous read access](https://learn.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-configure#allow-or-disallow-anonymous-read-access-for-a-storage-account)).
Neither setting is an input, so no configuration of this module lets an anonymous browser
read a blob. A browser can read media from the blob endpoint only with a SAS token in the
URL. The Microsoft Azure Storage for WordPress plugin (4.5.2) writes unsigned URLs, so media
does not load with it. Whether another plugin serves SAS-signed media URLs is **UNKNOWN**;
see [Architecture: Media](architecture.md#media).

### Database network

- MySQL Flexible Server runs with private access (VNet integration) in a subnet delegated
  to it (`modules/database/main.tf:64-66`; `modules/networking/main.tf:54-72`). Microsoft:
  a server "deployed to a virtual network can't have a public endpoint"
  ([MySQL private access](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/concepts-networking-vnet#unsupported-virtual-network-scenarios)).
- Name resolution uses the private DNS zone `privatelink.mysql.database.azure.com`, linked to
  the site's virtual network (`modules/dns-zones/main.tf:7-27`).
- The database-subnet NSG allows TCP 3306 from the App Service subnet's address range and
  denies all other inbound traffic (`modules/networking/main.tf:137-171`, `:180-183`).
- This is **not** a private endpoint. The networking module creates a private-endpoint
  subnet (`modules/networking/main.tf:74-84`), but no module creates a private endpoint in
  it.
- The admin password is a 32-character random value (`modules/wordpress-site/main.tf:320-324`).

[Architecture: Network](architecture.md#network) has the full subnet and DNS layout.

### Managed identities resolve Key Vault references

The module stores up to three secrets of its own in the site's vault: `db-password`,
`appinsights-connection` and, unless `storage_key_secret_enabled = false`, `storage-key`
(`modules/wordpress-site/main.tf:511-517`). Consumer secrets from `extra_secrets` are stored
beside them and cannot overwrite a module-owned name (`modules/wordpress-site/main.tf:563`).
With the opt-out, `storage-key` is no longer module-owned, so a consumer
`extra_secrets["storage-key"]` is written as given, and the vault then holds two module
secrets. See [Retiring the `storage-key` secret](../README.md#retiring-the-storage-key-secret).

By default, Terraform does not write these values into the app's settings. It writes Key
Vault references, which App Service resolves at run time:

- `DATABASE_PASSWORD` (`modules/app-service/main.tf:75`), removed from the production app at stage 3 of the
  passwordless path (`mysql_entra_stage_drop_password_enabled`) while the `db-password` secret is still written;
- `APPLICATIONINSIGHTS_CONNECTION_STRING` (`modules/app-service/main.tf:82`);
- `MICROSOFT_AZURE_ACCOUNT_KEY`, unless `app_service_storage_plugin_app_settings_enabled`
  is `false` (`modules/app-service/main.tf:124-130`);
- each entry of `extra_secret_app_settings` (`modules/wordpress-site/main.tf:579-582`).

These are defaults, not guarantees. `app_service.extra_app_settings`
(`modules/wordpress-site/variables.tf:414`) is merged after the module's own settings, so
an entry with the same name replaces a reference (`modules/app-service/main.tf:349`). On the
staging slot, `app_service.staging_app_settings_override` is merged last of all
(`modules/app-service/main.tf:585-589`). A literal secret passed through either input sits
in the app's configuration and in Terraform state. Use `extra_secrets` with
`extra_secret_app_settings` instead.

The app and the slot each have a system-assigned managed identity
(`modules/app-service/main.tf:226-229`, `:484-486`). Each identity gets `Get` and `List` on
secrets, and nothing else (`modules/wordpress-site/main.tf:689-703`, `:706-745`). The
deploying principal gets `Get`, `List`, `Set`, `Delete`, `Purge` and `Recover` on secrets
(`modules/key-vault/main.tf:87-101`).

From stage 1 of the passwordless database path (`mysql_entra_stage_identity_enabled`), the production
app also carries the user-assigned `mysql_entra_app_identity` and becomes `SystemAssigned, UserAssigned`;
Key Vault references still resolve with the system-assigned identity, because
`key_vault_reference_identity_id` stays unset. The slot is never given the app identity. See
[The stages](../modules/wordpress-site/README.md#the-stages).

```mermaid
sequenceDiagram
    autonumber
    participant TF as Terraform
    participant KV as Key Vault
    participant AS as App Service platform
    participant ID as Microsoft Entra ID
    participant WP as WordPress container
    participant DB as MySQL

    TF->>KV: Write secret db-password (needs an allow-list entry)
    TF->>AS: Create the app with DATABASE_PASSWORD set to a Key Vault reference
    TF->>KV: Grant the app identity Get and List on secrets
    Note over TF,AS: The app exists, and can start, before this grant
    Note over AS,KV: Resolved at start, after a configuration change,<br/>and at least every 24 hours
    AS->>ID: Request a token for the app identity
    ID-->>AS: Access token
    AS->>KV: Get secret over the public route
    KV-->>AS: 403 Forbidden, the public IP is not allow-listed
    AS->>KV: Get secret through VNet integration
    KV-->>AS: Secret value (subnet allow-listed, policy allows Get)
    AS->>WP: Start the container with DATABASE_PASSWORD set
    WP->>DB: Connect as wpadmin inside the VNet
```

[Architecture: Secrets](architecture.md#secrets) shows the same flow from Terraform's side,
including how the database password is created. The sequence follows Microsoft's
[Key Vault references](https://learn.microsoft.com/en-us/azure/app-service/app-service-key-vault-references)
and [virtual network integration](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration#app-settings-using-key-vault-references)
pages:

- References use the app's system-assigned identity by default.
- "App settings using Key Vault references attempt to get secrets over the public route.
  If the Key Vault is blocking public traffic and the app is using virtual network
  integration, an attempt is made to get the secrets through the virtual network
  integration." This is why the vault's audit log can show a 403 from the app's public IP
  followed by a success from its private IP; Microsoft calls this "by design".
- App Service "caches the values of the Key Vault references and refetches them every 24
  hours". A configuration change restarts the app and refetches at once.
- If a reference cannot be resolved, the app sees the literal `@Microsoft.KeyVault(...)`
  string instead of the secret.

The module grants the app's access only after the app exists: both access policies depend
on the app-service module (`modules/wordpress-site/main.tf:699-702`, `:722-725`), and the
key-vault module's own app policy is never created, because it receives a placeholder ID
(`modules/wordpress-site/main.tf:539`; `modules/key-vault/main.tf:73`). How soon the app
resolves its references after the grant is **UNKNOWN**; see [Unknowns](#unknowns).

### TLS settings

| Where | Setting | Code |
| --- | --- | --- |
| App Service, app and slot | HTTPS only | `modules/app-service/main.tf:204`, `:467` |
| App Service, app and slot | Minimum TLS 1.2 | `modules/app-service/main.tf:234`, `:491` |
| App Service, app and slot | FTP disabled | `modules/app-service/main.tf:236`, `:493` |
| Storage account | Minimum TLS 1.2, HTTPS only | `modules/storage/main.tf:26-27` |
| Front Door custom domain | Managed certificate, minimum TLS 1.2 | `modules/front-door/main.tf:78-81` |
| Front Door route | HTTPS to the origin, HTTP redirected to HTTPS | `modules/front-door/main.tf:93`, `:95` |
| Front Door origin | Certificate name check on | `modules/front-door/main.tf:69` |
| Cloudflare zone | `ssl = strict`, minimum TLS 1.2, Always Use HTTPS, **only when `cloudflare.enable_zone_setting_overrides = true`** | `modules/cloudflare/main.tf:134-158`; defaults `modules/cloudflare/variables.tf:68-72`, `:79-82`; off by default `modules/wordpress-site/variables.tf:555` |
| Cloudflare page rules | `ssl = strict` on `/wp-admin/*`, `/wp-login.php*` and `/wp-content/*`, **on by default** whenever `cdn_provider = "cloudflare"` and `cloudflare.enabled = true` (`cloudflare.enable_page_rules` defaults to `true`) | `modules/cloudflare/page-rules.tf:17-86`; default `modules/wordpress-site/variables.tf:553`; module gate `modules/wordpress-site/main.tf:197`, `:1063` |
| MySQL | TLS **not** required by default: `require_secure_transport = OFF` unless `mysql_require_secure_transport = true` | `modules/database/main.tf:111-116` |
| App Service custom domain | Host name bound **without a certificate** | `modules/wordpress-site/main.tf:1126-1153` |

The module binds the custom host name on App Service but no certificate
(`modules/wordpress-site/main.tf:1126-1153`). What that means depends on `cdn_provider`:

- **`direct` (the default), with a `custom_domain` of your own:** the module creates no
  binding for an `*.azurewebsites.net` name (`modules/wordpress-site/main.tf:1128`), so
  there is nothing to certify there. Browsers connect to the web app on the custom domain. Microsoft:
  "Unless you configure a certificate binding for your custom domain, any HTTPS request from
  a browser to the domain receives an error or warning, depending on the browser"
  ([custom domains](https://learn.microsoft.com/en-us/azure/app-service/app-service-web-tutorial-custom-domain#validate-domain-ownership-and-complete-the-mapping)).
  The web app forces HTTPS (`modules/app-service/main.tf:204`) and sets `WP_HOME` to the
  custom domain (`modules/app-service/main.tf:78-79`). Bind a certificate yourself, outside
  this module, before you send visitors to the site. Use an App Service managed or imported
  certificate
  ([Secure a custom DNS name with a TLS/SSL binding](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-bindings)).
  The module's binding ignores `ssl_state` and `thumbprint`
  (`modules/wordpress-site/main.tf:1148`), so Terraform does not undo it. See
  [Architecture: Request flow: direct](architecture.md#request-flow-direct).
- **`azure_front_door`:** Front Door presents its managed certificate for the custom domain
  (`modules/front-door/main.tf:78-81`), and reaches the origin on the default host name
  (`modules/front-door/main.tf:62-65`).
- **`cloudflare`:** Cloudflare presents the certificate to visitors. Whether Full (strict)
  works end to end with the unbound origin is **UNKNOWN**; see [Unknowns](#unknowns). With
  the default page rules, that question applies to the admin, login and content paths
  whatever the zone setting is.

### Edge

- **Front Door** (`cdn_provider = "azure_front_door"`): a WAF policy runs Microsoft's
  Default Rule Set 2.1 and Bot Manager 1.1 (`modules/front-door/main.tf:114-179`). It is in
  Prevention mode in production and Detection mode in nonprod, unless you set it
  (`modules/wordpress-site/main.tf:187`). Rules 942230 and 941320 are set to log only, and
  WordPress cookies are excluded, to avoid blocking the editor
  (`modules/front-door/main.tf:127-166`). The default SKU is Premium
  (`modules/wordpress-site/main.tf:186`).
- **Cloudflare** (`cdn_provider = "cloudflare"` and `cloudflare.enabled = true`): the
  module manages the site's DNS records and proxies the site's CNAME records
  (`modules/wordpress-site/main.tf:197`; `modules/wordpress-site/variables.tf:551`;
  `modules/cloudflare/main.tf:48-126`). Do not set `cloudflare.proxied = false` with this
  `cdn_provider`. The records become DNS-only (`modules/cloudflare/main.tf:55`), so visitors
  connect straight to the web app, and the origin rules, which follow `cdn_provider` alone
  (`modules/app-service/main.tf:270-320`), admit only Cloudflare's ranges and refuse them. See
  [Architecture: Request flow: Cloudflare](architecture.md#request-flow-cloudflare). Page
  rules, on by default, bypass the cache and set `security_level = "high"` and
  `ssl = "strict"` on `/wp-admin/*` and `/wp-login.php*` (`modules/cloudflare/page-rules.tf:17-64`;
  `modules/wordpress-site/variables.tf:553`). With `cloudflare.enable_waf = true` (default `false`,
  `modules/wordpress-site/variables.tf:552`), the module adds custom block and challenge
  rules (`modules/cloudflare/waf.tf:131-181`) and rate limits on `/wp-login.php` and
  `/xmlrpc.php` (`modules/cloudflare/waf.tf:82-124`; configured, but the rules omit Cloudflare's mandatory
  `cf.colo.id` characteristic, see
  [WAF rules beyond what the CDN plan provides](#waf-rules-beyond-what-the-cdn-plan-provides)). It also adds skip rules in the
  managed-rules phase for admin paths and WordPress cookies
  (`modules/cloudflare/waf.tf:19-75`). It does not deploy any Cloudflare managed ruleset:
  no rule in `modules/cloudflare` uses the `execute` action.

## What the module does not cover

### Binding the origin to one CDN account

With Cloudflare, IP-only origin rules identify the shared network, not your zone. To bind them to your zone, make
a Request Header Transform Rule overwrite `X-Azure-FDID`, set `app_service.cdn_origin_header_name` to
`"x_azure_fdid"`, and provide one to eight UUIDs in `cdn_origin_header_values`. Treat each value as a bearer
secret: it is stored in state, App Service configuration, and the edge rule. Verify that the application ignores
the header. Enable the edge rule before the origin filter and remove the origin filter first on rollback. For
rotation without downtime, accept old and new values, switch the edge, then drop the old value. The alternative
`x_forwarded_host` carrier accepts free-form strings but can affect generated URLs in reverse-proxy setups.

With Front Door, the main app is bound to your profile by the `X-Azure-FDID` check. The
staging slot is not (see [Origin restricted to the CDN](#origin-restricted-to-the-cdn)).

### Protecting `/wp-admin`

The module puts no identity or access gate in front of `/wp-admin` or `/wp-login.php`.
WordPress's own login is the only authentication. The edge features that do touch those
paths are general, not an access control:

- the Front Door WAF policy covers every path (`modules/front-door/main.tf:186-198`);
- the Cloudflare page rules set `security_level = "high"` on both paths
  (`modules/cloudflare/page-rules.tf:29`, `:56`);
- with `enable_waf = true`, the Cloudflare rules rate-limit login POSTs
  (`modules/cloudflare/waf.tf:93-107`; configured, but the rule omits Cloudflare's mandatory `cf.colo.id`
  characteristic, see [WAF rules beyond what the CDN plan provides](#waf-rules-beyond-what-the-cdn-plan-provides)) and add skip rules for admin paths in the
  managed-rules phase (`modules/cloudflare/waf.tf:30-44`).

A pattern for adding an identity-aware proxy at the edge and a token check at the origin, as one
consumer rolled it out with Cloudflare Access, is described in
[Protecting wp-admin with an edge identity proxy and an origin token check](patterns/wp-admin-protection.md)
(issue [#76](https://github.com/agenticcodingops/azure-wordpress/issues/76)). The module itself is unchanged by it.

### WAF rules beyond what the CDN plan provides

The module configures the WAF features listed under [Edge](#edge) and nothing more. Managed
rule sets, bot management and rate limiting depend on your CDN plan:

- On Cloudflare, the rate-limit rules that `enable_waf` adds need a Business plan or higher.
  Business is necessary but not sufficient. Both rate-limit rules set
  `characteristics = ["ip.src"]` (`modules/cloudflare/waf.tf:96`, `:113`). Cloudflare lists
  `cf.colo.id` as a mandatory characteristic and requires rules created through the API to
  include it explicitly
  ([parameters](https://developers.cloudflare.com/waf/rate-limiting-rules/parameters/),
  [request rate](https://developers.cloudflare.com/waf/rate-limiting-rules/request-rate/)).
  The dashboard adds it for you; Terraform does not. Until the module sets
  `["cf.colo.id", "ip.src"]`, do not rely on `enable_waf` on any plan. The API's exact
  response has not been reproduced here. The login rule matches on the request method (`modules/cloudflare/waf.tf:101-104`), and
  Cloudflare's availability table lists the Method field in rate-limiting expressions from
  the Business plan upward
  ([rate limiting rules](https://developers.cloudflare.com/waf/rate-limiting-rules/)). The
  ruleset's two rules and 60-second periods (`modules/cloudflare/waf.tf:91-123`) fit within
  Pro's limits, but the Method field does not.
- The module deploys no Cloudflare managed ruleset. If you deploy one yourself, check how
  it interacts with the skip rules above, which match on a cookie name that any client can
  send (`modules/cloudflare/waf.tf:51-55`).
- On Front Door, the WAF policy takes the profile's SKU (`modules/front-door/main.tf:117`).
  Microsoft's managed rule set and bot protection are available on the Premium tier, not
  on Standard
  ([tier comparison](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-cdn-comparison#service-comparison)).
  Premium is the module's default (`modules/wordpress-site/main.tf:186`).

### SCM is open by default

See [SCM plane](#scm-plane). Until you set the SCM variables, Kudu for the app and the slot
is reachable from the internet and guarded by authentication alone.

### The default `cdn_provider` admits everyone

`cdn_provider = "direct"` is the default, and it sets no origin restriction. See
[Origin restricted to the CDN](#origin-restricted-to-the-cdn).

### MySQL connections do not require TLS

The module sets `require_secure_transport = OFF` unless `mysql_require_secure_transport = true`,
which sets `ON` (`modules/database/main.tf:111-116`). The code comment gives two reasons for the
default: the traffic is "already confined to the VNet with a delegated subnet", and the Microsoft
WordPress container does not verify the server certificate (`modules/database/main.tf:106-110`).
The site module README adds that PHP connects with TLS by default (`DB_SSL_CONNECTION` defaults to
true) but does not verify the certificate, so `ON` closes the plain-text path without adding
verification, and that with `OFF` the server also accepts a token login without TLS
([TLS](../modules/wordpress-site/README.md#tls)). Turning it on refuses any client that does not
use TLS at once, so check the app and any other client first. Whether the traffic is encrypted at
the network layer is **UNKNOWN**; see [Unknowns](#unknowns).

### WordPress connects as the server administrator

The MySQL administrator login is `wpadmin` (`modules/wordpress-site/main.tf:437-438`), and
WordPress connects with the same login (`modules/wordpress-site/main.tf:610`). The module
creates no lower-privilege database user.

That is the default. The staged passwordless path replaces it: stage 1 attaches a user-assigned
identity to the production app and makes `mysql_entra_admin` the server's Microsoft Entra
administrator; stage 2 switches the app to a token login as `mysql_entra_app_database_user`, which
can be a non-administrator MySQL user you create (Layout A) or the app's own identity as the
administrator (Layout B); stage 3 removes `DATABASE_PASSWORD` from the production app; stage 4 sets
`aad_auth_only = ON`, so password logins stop for everyone, `wpadmin` included. The module still
creates no MySQL user, the image's token cache must stay off (`CACHE_MYSQL_ACCESS_TOKEN`), and the
staging slot keeps its password login, so stage 4 needs `app_service.staging_slot_enabled = false`.
See [Two layouts](../modules/wordpress-site/README.md#two-layouts),
[The stages](../modules/wordpress-site/README.md#the-stages) and
[The token cache must stay off](../modules/wordpress-site/README.md#the-token-cache-must-stay-off).

### Storage CORS admits any origin

The blob service allows `GET`, `HEAD`, `PUT` and `OPTIONS` from any origin
(`modules/storage/main.tf:67-73`). The code comment says "Restricted by WAF", but direct
requests to the blob endpoint do not pass through a CDN WAF. Writes still need
authorization: the account key, a SAS token or a Microsoft Entra ID token.

### A certificate for the custom domain

The module binds the custom host name on App Service without a certificate
(`modules/wordpress-site/main.tf:1126-1153`). With `cdn_provider = "direct"` and a `custom_domain` of your own
(not `*.azurewebsites.net`, for which the module creates no binding,
`modules/wordpress-site/main.tf:1128`), visitors get a certificate error or warning until
you bind one yourself. See [TLS settings](#tls-settings).

### Secret rotation

The module has no rotation procedure for the database password, the storage account key or the
Application Insights connection string. See the warning under
[Terraform state](#terraform-state-holds-generated-secrets) before you try to rotate the
database password. The one secret the module does rotate is the backup container SAS: it is
re-issued by the first plan after `app_service_backup.sas_rotation_days`, and rotating the account
key invalidates it until the next apply re-issues it
([The SAS: source, rotation and trade-off](../modules/wordpress-site/README.md#the-sas-source-rotation-and-trade-off)).

## Terraform state holds generated secrets

Terraform writes every managed attribute to state, including secrets. HashiCorp: "If you are
developing with Terraform locally, Terraform stores your state in a plaintext file, which
includes any secret values you defined in your configuration"
([Manage sensitive data](https://developer.hashicorp.com/terraform/language/state/sensitive-data)).
Marking a variable `sensitive` hides it from CLI output only: "Terraform still stores the
values of sensitive variables in your state"
([Input variables](https://developer.hashicorp.com/terraform/language/values/variables)).

For each site, state holds at least:

- the MySQL admin password, as the `random_password` result
  (`modules/wordpress-site/main.tf:320-324`), as the server's `administrator_password`
  (`modules/database/main.tf:40`) and as the `db-password` Key Vault secret;
- the storage account key (`modules/wordpress-site/main.tf:514`;
  `modules/storage/outputs.tf:24-34`);
- the backup container SAS, when `app_service_backup_enabled` is on: the module signs it from the
  account key at plan time (`modules/wordpress-site/backup.tf`), and it sits in state in the web
  app's backup block (`modules/app-service/main.tf:364`), never in an output
  ([The SAS: source, rotation and trade-off](../modules/wordpress-site/README.md#the-sas-source-rotation-and-trade-off));
- the Application Insights connection string (`modules/wordpress-site/main.tf:515`);
- every `extra_secrets` value that reaches the vault
  (`modules/wordpress-site/variables.tf:1016-1021`). Each becomes a Key Vault secret resource
  (`modules/key-vault/main.tf:105-110`). An entry named like a module-owned secret is
  dropped by the merge (`modules/wordpress-site/main.tf:563`);
- the publishing credentials of the app and the slot. The azurerm provider exports a
  `site_credential` block on the web app, with "the Site Credentials Password used for
  publishing"
  ([linux_web_app](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_web_app)).
  With basic auth on (the default, see [SCM plane](#scm-plane)), these open Kudu;
- the Log Analytics workspace's shared keys, when the module creates the workspace
  (`modules/wordpress-site/main.tf:371-381`), and the Application Insights instrumentation
  key (`modules/wordpress-site/main.tf:384-393`). The provider exports both as attributes
  ([log_analytics_workspace](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace),
  [application_insights](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights)).

Plan files can hold the same values: HashiCorp says "Terraform state and plan files"
can contain sensitive values.

Anyone who can read your state can read these secrets, whatever the Key Vault firewall and
access policies say.

### How to protect state

The module does not configure a backend. Step 1 of the
[Deployment guide](deployment-guide.md#step-1-create-the-state-store) creates a state store
along these lines, with one container per environment, and
[Getting started](getting-started.md#the-configuration) shows the backend settings. The
principles:

1. **Store state remotely**, never in a local file or in version control. HashiCorp
   recommends storing state remotely, encrypting it at rest, limiting access and keeping
   audit logs ([Manage sensitive data](https://developer.hashicorp.com/terraform/language/state/sensitive-data)).
2. **Use the `azurerm` backend with Microsoft Entra ID authentication.** Set
   `use_azuread_auth = true`, and grant the deploying principal Storage Blob Data
   Contributor on the state container. HashiCorp marks both as recommended
   ([azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)).
   The backend locks state with Azure Blob Storage's native capabilities.
3. **Restrict the state storage account** to the people and runners that deploy. Treat read
   access to state as read access to every site secret.
4. **Rely on Azure Storage encryption at rest.** It is on for every account and cannot be
   turned off
   ([Storage encryption](https://learn.microsoft.com/en-us/azure/storage/common/storage-service-encryption)).
5. **Turn on logging** for the state account, so you can see who read state.
6. **Treat saved plan files like state.** Do not upload them as public CI artifacts.

> **Do not rotate the database password by replacing `random_password.db`.** The server
> ignores password changes (`ignore_changes = [administrator_password]`,
> `modules/database/main.tf:99-102`). A new `random_password` result updates the
> `db-password` Key Vault secret, which the app reads, but not the server. WordPress would
> fail to connect as soon as the app refetches the secret. A tested rotation procedure is
> **UNKNOWN**: none exists yet.

## Unknowns

These could not be confirmed from the code or from vendor documentation:

1. Whether traffic between the app and MySQL is encrypted at the network layer. The v4.1.1 code
   comment said so; the v4.3.0 comment (`modules/database/main.tf:106-110`) says only that it is
   confined to the VNet.
2. Whether the WordPress container keeps its MySQL connection with
   `mysql_require_secure_transport = true`. The site module README says PHP connects with TLS by
   default (`DB_SSL_CONNECTION`); this page has not tested the parameter against the container.
3. Whether a later apply removes the `X-Azure-FDID` check, and for how long. The web app
   resource manages the whole rule list with no `ignore_changes`
   (`modules/app-service/main.tf:397-454`, `ignore_changes` `:450-453`), and in the azurerm provider source `ip_restriction`
   is optional, not computed
   ([`IpRestrictionSchema`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v5.6.0/internal/services/appservice/helpers/shared_schema.go#L56-L59),
   used at [`linux_web_app_schema.go:119`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v5.6.0/internal/services/appservice/helpers/linux_web_app_schema.go#L119)). So the next plan may show drift and restore the rules without
   the header, until `azapi_update_resource` (`modules/wordpress-site/main.tf:1017-1055`) adds it
   back on a later apply. This has not been tested.
4. Whether Cloudflare's Full (strict) mode works end to end with the module's host-name
   binding, which carries no certificate (`modules/wordpress-site/main.tf:1126-1153`). The
   default page rules use it on the admin, login and content paths
   (`modules/cloudflare/page-rules.tf:30`, `:57`, `:79`).
5. What the Cloudflare skip rules achieve. A skip with `ruleset = "current"` skips the
   remaining rules of the ruleset it is in
   ([actions](https://developers.cloudflare.com/ruleset-engine/rules-language/actions/)).
   The module's managed-phase ruleset holds only skip rules
   (`modules/cloudflare/waf.tf:19-75`), so on its own it appears to skip nothing. How it
   interacts with a managed ruleset deployed outside Terraform is not known.
6. How soon a new app resolves its Key Vault references after the module grants its
   identity access, which happens after the app is created
   (`modules/wordpress-site/main.tf:699-702`).
7. A tested procedure for rotating the database password, the storage key or the
   Application Insights connection string.
8. Whether any Blob offload plugin, should you install one, serves SAS-signed media URLs. The account disallows anonymous
   blob access and the uploads container is private (`modules/storage/main.tf:28`, `:91`), so
   unsigned URLs, which the Microsoft Azure Storage for WordPress plugin 4.5.2 writes, fail.

## References

Microsoft:

- [App Service access restrictions](https://learn.microsoft.com/en-us/azure/app-service/overview-access-restrictions)
- [App Service virtual network integration](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration)
- [Use Key Vault references as app settings](https://learn.microsoft.com/en-us/azure/app-service/app-service-key-vault-references)
- [Virtual network service endpoints for Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/overview-vnet-service-endpoints)
- [Network security groups overview](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview)
- [Azure Database for MySQL private access](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/concepts-networking-vnet)
- [Azure Storage encryption for data at rest](https://learn.microsoft.com/en-us/azure/storage/common/storage-service-encryption)
- [SAS expiration policy](https://learn.microsoft.com/en-us/azure/storage/common/sas-expiration-policy)
- [Azure Front Door tier comparison](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-cdn-comparison)

Cloudflare:

- [Rate limiting rules](https://developers.cloudflare.com/waf/rate-limiting-rules/)
- [Rules language: actions](https://developers.cloudflare.com/ruleset-engine/rules-language/actions/)

HashiCorp:

- [Manage sensitive data in your configuration](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
- [Input variables](https://developer.hashicorp.com/terraform/language/values/variables)
- [azurerm provider resources](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs):
  `linux_web_app`, `log_analytics_workspace`, `application_insights`
- [azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)

This repository:

- [SECURITY.md](../SECURITY.md)
- [Architecture](architecture.md)
- [Getting started](getting-started.md)
- [Deployment guide](deployment-guide.md)
- [app-service module](../modules/app-service/README.md)
- [key-vault module](../modules/key-vault/README.md)
- [storage module](../modules/storage/README.md)
- [networking module](../modules/networking/README.md)
- [wordpress-site module](../modules/wordpress-site/README.md)
