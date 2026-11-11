############################################
# corp.doc - Domain Controller (Active Directory + DNS)
# Implemented as AWS Managed Microsoft AD: it provides AD + DNS on two
# managed domain controllers and is required for WorkSpaces registration.
############################################
resource "random_password" "ad_admin" {
  count = local.enable_ad ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#%^*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_secretsmanager_secret" "ad_admin" {
  count = local.enable_ad ? 1 : 0

  name                    = "${local.name}/ad/admin"
  description             = "Admin credentials for ${var.ad_domain}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "ad_admin" {
  count = local.enable_ad ? 1 : 0

  secret_id = aws_secretsmanager_secret.ad_admin[0].id
  secret_string = jsonencode({
    username = "Admin"
    password = random_password.ad_admin[0].result
    domain   = var.ad_domain
  })
}

resource "aws_directory_service_directory" "corp" {
  count = local.enable_ad ? 1 : 0

  name       = var.ad_domain
  short_name = var.ad_short_name
  password   = random_password.ad_admin[0].result
  edition    = var.ad_edition
  type       = "MicrosoftAD"

  vpc_settings {
    vpc_id     = aws_vpc.this.id
    subnet_ids = [aws_subnet.this["corp_a"].id, aws_subnet.this["corp_b"].id]
  }

  tags = { Name = "${local.name}-corp-ad", Domain = var.ad_domain }
}

# The DC is the DNS for the environment; AD DNS forwards everything else to the VPC resolver,
# so the Route 53 private zones below still resolve.
resource "aws_vpc_dhcp_options" "ad" {
  count = local.enable_ad && var.use_ad_dns_for_vpc ? 1 : 0

  domain_name         = var.ad_domain
  domain_name_servers = sort(tolist(aws_directory_service_directory.corp[0].dns_ip_addresses))

  tags = { Name = "${local.name}-dhcp-ad" }
}

resource "aws_vpc_dhcp_options_association" "ad" {
  count = local.enable_ad && var.use_ad_dns_for_vpc ? 1 : 0

  vpc_id          = aws_vpc.this.id
  dhcp_options_id = aws_vpc_dhcp_options.ad[0].id
}

############################################
# Private DNS zones for the other domains
############################################
resource "aws_route53_zone" "private" {
  for_each = toset(["mgmt.doc", "sec.doc", "dmz.doc"])

  name = each.key

  vpc {
    vpc_id = aws_vpc.this.id
  }
}

resource "aws_route53_record" "host" {
  for_each = local.hosts

  zone_id = aws_route53_zone.private[each.value.domain].zone_id
  name    = local.host_fqdns[each.key]
  type    = "A"
  ttl     = 300
  records = [local.host_ips[each.key]]
}

resource "aws_route53_record" "pii_db" {
  zone_id = aws_route53_zone.private["dmz.doc"].zone_id
  name    = "pii-db.dmz.doc"
  type    = "CNAME"
  ttl     = 300
  records = [aws_db_instance.pii.address]
}
