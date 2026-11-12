# Cloudflare WAF Configuration for WordPress
# Configures rate limiting and custom rules when enable_waf is true.
# Managed rulesets and their exceptions are configured separately by the operator.
#
# NOTE: Compatible with Cloudflare provider v5.x

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
