data "aws_caller_identity" "current" {}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id

  # Lite mode switches off everything the AWS Free plan blocks or that would burn the credits fast
  enable_firewall   = var.enable_network_firewall && !var.lite_mode
  enable_ad         = !var.lite_mode
  enable_workspaces = !var.lite_mode
  enable_mirroring  = var.enable_traffic_mirroring && !var.lite_mode

  # Lite sizes are all free-tier eligible (Free plan accounts can only launch these)
  default_instance_types = {
    full = {
      rhel_server   = "t3.medium"
      jumpserver    = "t3.micro"
      rhel_security = "t3.large"
      security_main = "t3.xlarge"
      webserver     = "t3.small"
      openvpn       = "t3.micro"
    }
    lite = {
      rhel_server   = "t3.small" # FreeIPA needs ~2 GB
      jumpserver    = "t3.micro"
      rhel_security = "c7i-flex.large" # OpenVAS needs ~4 GB
      security_main = "m7i-flex.large" # Graylog + OpenSearch needs ~8 GB
      webserver     = "t3.micro"
      openvpn       = "t3.micro"
    }
  }
  instance_types = {
    for k, v in local.default_instance_types[var.lite_mode ? "lite" : "full"] :
    k => coalesce(var.instance_types[k], v)
  }

  # Each "Domain" box in the diagram maps to one or more subnets in a single VPC.
  # tier selects the route table:
  #   firewall -> IGW
  #   public   -> Network Firewall endpoint (or IGW if the firewall is disabled)
  #   private  -> NAT gateway
  #   isolated -> no internet route at all
  subnets = {
    firewall     = { cidr = cidrsubnet(var.vpc_cidr, 12, 0), az = var.azs[0], tier = "firewall", domain = "perimeter" }
    corp_a       = { cidr = cidrsubnet(var.vpc_cidr, 8, 10), az = var.azs[0], tier = "private", domain = "corp.doc" }
    corp_b       = { cidr = cidrsubnet(var.vpc_cidr, 8, 11), az = var.azs[1], tier = "private", domain = "corp.doc" }
    workspaces_a = { cidr = cidrsubnet(var.vpc_cidr, 8, 20), az = var.azs[0], tier = "private", domain = "workspaces.doc" }
    workspaces_b = { cidr = cidrsubnet(var.vpc_cidr, 8, 21), az = var.azs[1], tier = "private", domain = "workspaces.doc" }
    mgmt         = { cidr = cidrsubnet(var.vpc_cidr, 8, 30), az = var.azs[0], tier = "private", domain = "mgmt.doc" }
    sec          = { cidr = cidrsubnet(var.vpc_cidr, 8, 40), az = var.azs[0], tier = "private", domain = "sec.doc" }
    dmz_public   = { cidr = cidrsubnet(var.vpc_cidr, 8, 50), az = var.azs[0], tier = "public", domain = "dmz.doc" }
    dmz_data_a   = { cidr = cidrsubnet(var.vpc_cidr, 8, 51), az = var.azs[0], tier = "isolated", domain = "dmz.doc" }
    dmz_data_b   = { cidr = cidrsubnet(var.vpc_cidr, 8, 52), az = var.azs[1], tier = "isolated", domain = "dmz.doc" }
  }

  # EC2 hosts from the diagram. Static private IPs avoid dependency cycles
  # (every host needs Graylog's IP, Graylog's host needs the IPA server's IP, ...).
  hosts = {
    rhel_server   = { hostname = "rhel-server", domain = "mgmt.doc", subnet = "mgmt", host_num = 10, volume_gb = 40 }
    jumpserver    = { hostname = "jumpserver", domain = "mgmt.doc", subnet = "mgmt", host_num = 11, volume_gb = 30 }
    rhel_security = { hostname = "rhel-security", domain = "sec.doc", subnet = "sec", host_num = 10, volume_gb = 80 }
    security_main = { hostname = "security-main", domain = "sec.doc", subnet = "sec", host_num = 11, volume_gb = 100 }
    webserver     = { hostname = "webserver", domain = "dmz.doc", subnet = "dmz_public", host_num = 10, volume_gb = 30 }
    openvpn       = { hostname = "openvpn", domain = "dmz.doc", subnet = "dmz_public", host_num = 11, volume_gb = 20 }
  }

  host_ips     = { for k, h in local.hosts : k => cidrhost(local.subnets[h.subnet].cidr, h.host_num) }
  host_fqdns   = { for k, h in local.hosts : k => "${h.hostname}.${h.domain}" }
  public_hosts = toset(["webserver", "openvpn"])

  # FreeIPA lives in mgmt.doc (IPA server on rhel-server)
  ipa_domain = "mgmt.doc"
  ipa_realm  = upper(local.ipa_domain)

  # Ansible groups mirror the components drawn inside each host box
  ansible_groups = {
    ansible_controller = ["rhel_server"]
    ipaserver          = ["rhel_server"]
    ipaclients         = ["jumpserver", "rhel_security", "security_main"]
    graylog            = ["security_main"]
    snort              = ["security_main"]
    openvas            = ["rhel_security"]
    glpi               = ["rhel_security"]
    nginx              = ["webserver"]
    openvpn            = ["openvpn"]
  }

  ansible_inventory = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    groups     = local.ansible_groups
    fqdns      = local.host_fqdns
    ips        = local.host_ips
    graylog_ip = local.host_ips["security_main"]
    ipa_server = local.host_fqdns["rhel_server"]
    ipa_domain = local.ipa_domain
    ipa_realm  = local.ipa_realm
    ad_domain  = var.ad_domain
    ad_enabled = local.enable_ad
    vpc_cidr   = var.vpc_cidr
    vpc_mask   = cidrnetmask(var.vpc_cidr)
    vpc_dns    = cidrhost(var.vpc_cidr, 2) # Amazon-provided VPC resolver
  })
}
