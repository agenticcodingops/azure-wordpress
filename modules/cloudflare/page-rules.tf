# Cloudflare Page Rules for WordPress Caching
# Configures cache behavior for different WordPress content types
#
# Free plan includes 3 page rules - we use them strategically:
# 1. Bypass cache for wp-admin/*
# 2. Bypass cache for wp-login.php
# 3. Cache everything for wp-content/* (static assets)
#
# NOTE: Compatible with Cloudflare provider v5.x

# ============================================================================
# PAGE RULES
# ============================================================================

# Rule 1: Bypass cache for WordPress admin
# Priority 1 (highest) - ensures admin is never cached
resource "cloudflare_page_rule" "wp_admin" {
  count = var.enable_page_rules ? 1 : 0

  zone_id  = local.zone_id
  target   = "*${var.domain}/wp-admin/*"
  priority = 1
  status   = "active"

  actions = {
    cache_level         = "bypass"
    disable_apps        = true
    disable_performance = true
    security_level      = "high"
    ssl                 = "strict"
  }
}

# Rule 2: Bypass cache for WordPress login
# Priority 2 - login page should never be cached
resource "cloudflare_page_rule" "wp_login" {
  count = var.enable_page_rules ? 1 : 0

  zone_id  = local.zone_id
  target   = "*${var.domain}/wp-login.php*"
  priority = 2
  status   = "active"

  actions = {
    cache_level    = "bypass"
    security_level = "high"
    ssl            = "strict"
  }
}

# Rule 3: Cache everything for static content
# Priority 3 - wp-content contains themes, plugins, uploads
resource "cloudflare_page_rule" "wp_content" {
  count = var.enable_page_rules ? 1 : 0

  zone_id  = local.zone_id
  target   = "*${var.domain}/wp-content/*"
  priority = 3
  status   = "active"

  actions = {
    cache_level    = "cache_everything"
    edge_cache_ttl = var.static_content_cache_ttl
    ssl            = "strict"
  }
}

# ============================================================================
# CACHE RULES (Modern replacement for Page Rules)
# Using rulesets for more granular control
# ============================================================================

# Cache rules for WordPress optimization
# NOTE: Rulesets require a paid Cloudflare plan - skip on Free plan
resource "cloudflare_ruleset" "wordpress_cache" {
  count = var.enable_cache_rules ? 1 : 0

  zone_id     = local.zone_id
  name        = "WordPress Cache Rules"
  description = "Optimize caching for WordPress sites"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    # Cache static file extensions aggressively
    {
      action = "set_cache_settings"
      action_parameters = {
        edge_ttl = {
          mode    = "override_origin"
          default = var.static_content_cache_ttl
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 86400 # 1 day for browser cache
        }
        cache = true
      }
      expression  = <<-EOT
        (http.request.uri.path.extension in {"css" "js" "jpg" "jpeg" "png" "gif" "ico" "svg" "woff" "woff2" "ttf" "eot"})
      EOT
      description = "Cache static assets (CSS, JS, images, fonts)"
      enabled     = true
      ref         = "cache_static_assets"
    },
    # Never cache WordPress admin
    {
      action = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      expression  = <<-EOT
        (http.request.uri.path contains "/wp-admin/") or
        (http.request.uri.path eq "/wp-login.php") or
        (http.request.uri.path eq "/wp-cron.php")
      EOT
      description = "Bypass cache for WordPress admin"
      enabled     = true
      ref         = "bypass_admin_cache"
    },
    # Never cache WordPress API (used by Gutenberg)
    {
      action = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      expression  = "(http.request.uri.path contains \"/wp-json/\")"
      description = "Bypass cache for WordPress REST API"
      enabled     = true
      ref         = "bypass_api_cache"
    },
    # Never cache for logged-in users
    {
      action = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      expression  = <<-EOT
        (http.cookie contains "wordpress_logged_in_") or
        (http.cookie contains "wp-settings-") or
        (http.cookie contains "comment_author_")
      EOT
      description = "Bypass cache for logged-in WordPress users"
      enabled     = true
      ref         = "bypass_logged_in_cache"
    },
    # Cache WordPress feeds
    {
      action = "set_cache_settings"
      action_parameters = {
        edge_ttl = {
          mode    = "override_origin"
          default = 3600 # 1 hour for feeds
        }
        cache = true
      }
      expression  = "(http.request.uri.path contains \"/feed/\")"
      description = "Cache WordPress RSS feeds"
      enabled     = true
      ref         = "cache_feeds"
    }
  ]
}
