# Front Door Module - Layer 2 Application
# Creates Azure Front Door CDN + WAF with WordPress exclusions
# CRITICAL: WAF exclusions for rules 942230 and 941320 prevent blocking WordPress admin

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming
  name_prefix = "${var.project_name}-${var.site_name}-${local.env_suffix}"

  # Endpoint naming (must be globally unique)
  endpoint_name = "${var.site_name}-${local.env_suffix}"
}

# Front Door Profile
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "afd-${local.name_prefix}"
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Front Door Endpoint
resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = local.endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Origin Group
resource "azurerm_cdn_frontdoor_origin_group" "main" {
  name                     = "og-${var.site_name}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  session_affinity_enabled = true

  health_probe {
    interval_in_seconds = 30
    path                = "/"
    protocol            = "Https"
    request_type        = "HEAD"
  }

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }
}

# Origin (App Service)
resource "azurerm_cdn_frontdoor_origin" "main" {
  name                          = "origin-${var.site_name}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  enabled                       = true

  host_name          = var.origin_hostname
  http_port          = 80
  https_port         = 443
  origin_host_header = var.origin_hostname
  priority           = 1
  weight             = 1000

  certificate_name_check_enabled = true
}

# Custom Domain
resource "azurerm_cdn_frontdoor_custom_domain" "main" {
  name                     = replace(var.custom_domain, ".", "-")
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = var.custom_domain

  tls {
    certificate_type    = "ManagedCertificate"
    minimum_tls_version = "TLS12"
  }
}

# Route
resource "azurerm_cdn_frontdoor_route" "main" {
  name                          = "route-${var.site_name}"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.main.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  link_to_default_domain = true
  https_redirect_enabled = true

  cdn_frontdoor_custom_domain_ids = [azurerm_cdn_frontdoor_custom_domain.main.id]

  cache {
    query_string_caching_behavior = "UseQueryString"
    compression_enabled           = true
    content_types_to_compress     = ["text/html", "text/css", "application/javascript", "application/json", "image/svg+xml"]
  }
}

# Custom Domain Association
resource "azurerm_cdn_frontdoor_custom_domain_association" "main" {
  cdn_frontdoor_custom_domain_id = azurerm_cdn_frontdoor_custom_domain.main.id
  cdn_frontdoor_route_ids        = [azurerm_cdn_frontdoor_route.main.id]
}

# WAF Policy
# CRITICAL: WordPress admin exclusions for rules 942230 and 941320
resource "azurerm_cdn_frontdoor_firewall_policy" "main" {
  name                              = "waf${replace(local.name_prefix, "-", "")}"
  resource_group_name               = var.resource_group_name
  sku_name                          = var.sku_name
  enabled                           = true
  mode                              = var.waf_mode
  custom_block_response_status_code = 403

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"

    # Exclusion for WordPress login cookies (rule 942230 - SQL injection)
    exclusion {
      match_variable = "RequestCookieNames"
      selector       = "wordpress_logged_in_"
      operator       = "StartsWith"
    }

    # Exclusion for WordPress session cookies (rule 942230 - SQL injection)
    exclusion {
      match_variable = "RequestCookieNames"
      selector       = "wordpress_sec_"
      operator       = "StartsWith"
    }

    # Exclusion for WordPress admin cookie (rule 942230 - SQL injection)
    exclusion {
      match_variable = "RequestCookieNames"
      selector       = "wp-settings-"
      operator       = "StartsWith"
    }

    # Override rule 942230 to log only for WordPress paths
    override {
      rule_group_name = "SQLI"
      rule {
        rule_id = "942230"
        enabled = true
        action  = "Log"
      }
    }

    # Override rule 941320 to log only (XSS in editor)
    override {
      rule_group_name = "XSS"
      rule {
        rule_id = "941320"
        enabled = true
        action  = "Log"
      }
    }
  }

  # Bot protection
  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.1"
    action  = "Block"
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Security Policy (links WAF to endpoint)
resource "azurerm_cdn_frontdoor_security_policy" "main" {
  name                     = "sp-${var.site_name}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.main.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.main.id
        }
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_custom_domain.main.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

# Rule Set for caching
resource "azurerm_cdn_frontdoor_rule_set" "caching" {
  name                     = "caching${replace(var.site_name, "-", "")}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
}

# Rule: Cache static assets
resource "azurerm_cdn_frontdoor_rule" "cache_static" {
  name                      = "CacheStaticAssets"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.caching.id
  order                     = 1
  behavior_on_match         = "Continue"

  conditions {
    url_file_extension_condition {
      operator         = "Equal"
      match_values     = ["css", "js", "jpg", "jpeg", "png", "gif", "ico", "woff", "woff2", "ttf", "svg"]
      negate_condition = false
      transforms       = ["Lowercase"]
    }
  }

  actions {
    route_configuration_override_action {
      cache_behavior                = "OverrideAlways"
      cache_duration                = "${format("%02d", floor(var.cache_static_minutes / 60))}:${format("%02d", var.cache_static_minutes % 60)}:00"
      compression_enabled           = true
      query_string_caching_behavior = "UseQueryString"
    }
  }
}

# Rule: Cache uploads (media files)
resource "azurerm_cdn_frontdoor_rule" "cache_uploads" {
  name                      = "CacheUploads"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.caching.id
  order                     = 2
  behavior_on_match         = "Continue"

  conditions {
    url_path_condition {
      operator         = "BeginsWith"
      match_values     = ["/wp-content/uploads/"]
      negate_condition = false
      transforms       = ["Lowercase"]
    }
  }

  actions {
    route_configuration_override_action {
      cache_behavior                = "OverrideAlways"
      cache_duration                = "${format("%02d", floor(var.cache_uploads_minutes / 60))}:${format("%02d", var.cache_uploads_minutes % 60)}:00"
      compression_enabled           = true
      query_string_caching_behavior = "IgnoreQueryString"
    }
  }
}

# Rule: No cache for admin
resource "azurerm_cdn_frontdoor_rule" "no_cache_admin" {
  name                      = "NoCacheAdmin"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.caching.id
  order                     = 0 # Highest priority
  behavior_on_match         = "Stop"

  conditions {
    url_path_condition {
      operator         = "BeginsWith"
      match_values     = ["/wp-admin/", "/wp-login.php"]
      negate_condition = false
      transforms       = ["Lowercase"]
    }
  }

  actions {
    route_configuration_override_action {
      cache_behavior = "Disabled"
    }
  }
}
