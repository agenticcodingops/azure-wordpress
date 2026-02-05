# Cloudflare WAF Configuration for WordPress
# Creates managed ruleset overrides to prevent false positives in WordPress admin
#
# CRITICAL: Without these exclusions, Cloudflare WAF blocks:
# - WordPress visual editor (XSS-like content)
# - Plugin/theme uploads
# - Customizer changes
# - Post/page editing with special characters
#
# This is equivalent to Azure WAF rules 942230, 941320 exclusions
#
# NOTE: Compatible with Cloudflare provider v5.x

# ============================================================================
# WAF MANAGED RULES OVERRIDE
# ============================================================================

# Skip WAF for WordPress admin operations
resource "cloudflare_ruleset" "wordpress_waf_exceptions" {
  count = var.enable_waf ? 1 : 0

  zone_id     = local.zone_id
  name        = "WordPress WAF Exceptions"
  description = "Skip managed WAF rules for WordPress admin to prevent false positives"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules = [
    # Rule 1: Skip all WAF rules for WordPress admin paths
    {
      action = "skip"
      action_parameters = {
        ruleset = "current"
      }
      expression  = <<-EOT
        (http.request.uri.path contains "/wp-admin/") or
        (http.request.uri.path contains "/wp-login.php") or
        (http.request.uri.path eq "/wp-cron.php") or
        (http.request.uri.path eq "/xmlrpc.php")
      EOT
      description = "Skip WAF for WordPress admin paths"
      enabled     = true
      ref         = "wp_admin_skip"
    },
    # Rule 2: Skip WAF for authenticated WordPress users (logged-in cookies)
    {
      action = "skip"
      action_parameters = {
        ruleset = "current"
      }
      expression  = <<-EOT
        (http.cookie contains "wordpress_logged_in_") or
        (http.cookie contains "wordpress_sec_") or
        (http.cookie contains "wp-settings-")
      EOT
      description = "Skip WAF for authenticated WordPress users"
      enabled     = true
      ref         = "wp_auth_skip"
    },
    # Rule 3: Skip WAF for WordPress REST API (used by Gutenberg editor)
    {
      action = "skip"
      action_parameters = {
        ruleset = "current"
      }
      expression  = <<-EOT
        (http.request.uri.path contains "/wp-json/") and
        (http.cookie contains "wordpress_logged_in_")
      EOT
      description = "Skip WAF for authenticated WordPress REST API requests"
      enabled     = true
      ref         = "wp_rest_skip"
    }
  ]
}

# ============================================================================
# RATE LIMITING FOR WORDPRESS LOGIN
# ============================================================================

# Rate limit login attempts to prevent brute force attacks
resource "cloudflare_ruleset" "wordpress_rate_limit" {
  count = var.enable_waf ? 1 : 0

  zone_id     = local.zone_id
  name        = "WordPress Rate Limiting"
  description = "Rate limit WordPress login and xmlrpc to prevent brute force"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    # Rate limit wp-login.php
    {
      action = "block"
      ratelimit = {
        characteristics     = ["ip.src"]
        period              = 60
        requests_per_period = 10
        mitigation_timeout  = 600 # 10 minute block
      }
      expression  = <<-EOT
        (http.request.uri.path eq "/wp-login.php") and
        (http.request.method eq "POST")
      EOT
      description = "Rate limit WordPress login attempts (10/minute)"
      enabled     = true
      ref         = "wp_login_ratelimit"
    },
    # Rate limit xmlrpc.php (common attack vector)
    {
      action = "block"
      ratelimit = {
        characteristics     = ["ip.src"]
        period              = 60
        requests_per_period = 5
        mitigation_timeout  = 3600 # 1 hour block
      }
      expression  = "(http.request.uri.path eq \"/xmlrpc.php\")"
      description = "Rate limit XML-RPC requests (5/minute)"
      enabled     = true
      ref         = "wp_xmlrpc_ratelimit"
    }
  ]
}

# ============================================================================
# SECURITY RULES FOR WORDPRESS
# ============================================================================

# Block common WordPress attack patterns
resource "cloudflare_ruleset" "wordpress_security" {
  count = var.enable_waf ? 1 : 0

  zone_id     = local.zone_id
  name        = "WordPress Security Rules"
  description = "Block common WordPress attack patterns"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [
    # Block direct access to wp-config.php
    {
      action      = "block"
      expression  = "(http.request.uri.path contains \"wp-config.php\")"
      description = "Block access to wp-config.php"
      enabled     = true
      ref         = "block_wp_config"
    },
    # Block access to .htaccess
    {
      action      = "block"
      expression  = "(http.request.uri.path contains \".htaccess\")"
      description = "Block access to .htaccess files"
      enabled     = true
      ref         = "block_htaccess"
    },
    # Block PHP file execution in uploads directory
    {
      action      = "block"
      expression  = <<-EOT
        (http.request.uri.path contains "/wp-content/uploads/") and
        (http.request.uri.path contains ".php")
      EOT
      description = "Block PHP execution in uploads directory"
      enabled     = true
      ref         = "block_uploads_php"
    },
    # Block common vulnerability scanners
    {
      action      = "managed_challenge"
      expression  = <<-EOT
        (http.request.uri.path contains "/wp-includes/") and
        (http.request.uri.path contains ".php") and
        (not http.request.uri.path contains "wp-includes/js/")
      EOT
      description = "Challenge direct access to wp-includes PHP files"
      enabled     = true
      ref         = "challenge_wp_includes"
    }
  ]
}
