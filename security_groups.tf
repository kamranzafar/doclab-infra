############################################
# Security groups - one per host / service in the diagram
############################################
locals {
  security_groups = {
    rhel_server   = "rhel-server (mgmt.doc): FreeIPA server, Ansible, rsyslog"
    jumpserver    = "jumpserver (mgmt.doc): admin bastion reached over VPN"
    rhel_security = "rhel-security (sec.doc): OpenVAS CE in Docker, GLPI"
    security_main = "security-main (sec.doc): Graylog, Snort"
    webserver     = "webserver (dmz.doc): NGINX"
    openvpn       = "OpenVPN (dmz.doc)"
    rds           = "PII database (dmz.doc)"
    workspaces    = "AWS WorkSpaces (workspaces.doc)"
  }

  # FreeIPA client -> server ports (green dashed lines)
  ipa_ports = [
    { proto = "tcp", port = 80 },
    { proto = "tcp", port = 443 },
    { proto = "tcp", port = 389 },
    { proto = "tcp", port = 636 },
    { proto = "tcp", port = 88 },
    { proto = "udp", port = 88 },
    { proto = "tcp", port = 464 },
    { proto = "udp", port = 464 },
    { proto = "udp", port = 123 },
  ]

  ipa_clients   = ["jumpserver", "rhel_security", "security_main"]
  managed_hosts = ["jumpserver", "rhel_security", "security_main", "webserver", "openvpn"]
  admin_sources = ["jumpserver", "openvpn"]
  scan_targets  = ["rhel_server", "jumpserver", "security_main", "webserver", "openvpn", "rds"]

  # Every rule uses the same shape; "" means "not set".
  sg_rules = concat(
    # FreeIPA enrolment / auth (green dashed)
    flatten([for c in local.ipa_clients : [for p in local.ipa_ports : {
      key   = "ipa-${c}-${p.proto}-${p.port}", sg = "rhel_server", src_sg = c, cidr = "",
      proto = p.proto, from = p.port, to = p.port, desc = "FreeIPA from ${c}"
    }]]),

    # Ansible on rhel-server manages all hosts over SSH (dark red dashed)
    [for h in local.managed_hosts : {
      key   = "ansible-ssh-${h}", sg = h, src_sg = "rhel_server", cidr = "",
      proto = "tcp", from = 22, to = 22, desc = "Ansible SSH from rhel-server"
    }],

    # Admin path: VPN -> jumpserver -> hosts
    [{
      key   = "vpn-ssh-jumpserver", sg = "jumpserver", src_sg = "openvpn", cidr = "",
      proto = "tcp", from = 22, to = 22, desc = "SSH from VPN clients"
    }],
    [for h in ["rhel_server", "rhel_security", "security_main", "webserver", "openvpn"] : {
      key   = "jump-ssh-${h}", sg = h, src_sg = "jumpserver", cidr = "",
      proto = "tcp", from = 22, to = 22, desc = "SSH from jumpserver"
    }],

    # Rsyslog -> Graylog (blue dashed). Any host in the VPC, incl. the AD DNS servers.
    [for p in ["tcp", "udp"] : {
      key   = "syslog-${p}", sg = "security_main", src_sg = "", cidr = var.vpc_cidr,
      proto = p, from = 1514, to = 1514, desc = "Syslog to Graylog"
    }],
    [{
      key   = "gelf-udp", sg = "security_main", src_sg = "", cidr = var.vpc_cidr,
      proto = "udp", from = 12201, to = 12201, desc = "GELF to Graylog (OpenVAS, Docker)"
    }],

    # Admin web UIs, reachable only from jumpserver / VPN
    flatten([for s in local.admin_sources : [
      {
        key   = "graylog-ui-${s}", sg = "security_main", src_sg = s, cidr = "",
        proto = "tcp", from = 9000, to = 9000, desc = "Graylog web UI"
      },
      {
        key   = "glpi-ui-${s}", sg = "rhel_security", src_sg = s, cidr = "",
        proto = "tcp", from = 443, to = 443, desc = "GLPI web UI"
      },
      {
        key   = "gsa-ui-${s}", sg = "rhel_security", src_sg = s, cidr = "",
        proto = "tcp", from = 9392, to = 9392, desc = "OpenVAS GSA web UI"
      },
    ]]),

    # Public NGINX
    flatten([for c in var.web_allowed_cidrs : [for port in [80, 443] : {
      key   = "web-${port}-${c}", sg = "webserver", src_sg = "", cidr = c,
      proto = "tcp", from = port, to = port, desc = "HTTP(S) to NGINX"
    }]]),

    # Public OpenVPN
    [for c in var.vpn_allowed_cidrs : {
      key   = "vpn-${c}", sg = "openvpn", src_sg = "", cidr = c,
      proto = "udp", from = 1194, to = 1194, desc = "OpenVPN"
    }],

    # NGINX -> PII database (dashed line in DMZ), plus DBA access from jumpserver
    [
      {
        key   = "db-webserver", sg = "rds", src_sg = "webserver", cidr = "",
        proto = "tcp", from = 5432, to = 5432, desc = "PostgreSQL from NGINX app tier"
      },
      {
        key   = "db-jumpserver", sg = "rds", src_sg = "jumpserver", cidr = "",
        proto = "tcp", from = 5432, to = 5432, desc = "PostgreSQL admin from jumpserver"
      },
      {
        key   = "vxlan-mirror", sg = "security_main", src_sg = "webserver", cidr = "",
        proto = "udp", from = 4789, to = 4789, desc = "Traffic Mirroring VXLAN to Snort"
      },
    ],

    # OpenVAS on rhel-security scans everything
    [for h in(var.enable_vuln_scanning ? local.scan_targets : []) : {
      key   = "openvas-${h}", sg = h, src_sg = "rhel_security", cidr = "",
      proto = "-1", from = 0, to = 0, desc = "OpenVAS vulnerability scanning"
    }],
  )
}

resource "aws_security_group" "this" {
  for_each = local.security_groups

  name        = "${local.name}-${replace(each.key, "_", "-")}"
  description = each.value
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-${replace(each.key, "_", "-")}" }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = { for r in local.sg_rules : r.key => r }

  security_group_id            = aws_security_group.this[each.value.sg].id
  referenced_security_group_id = each.value.src_sg != "" ? aws_security_group.this[each.value.src_sg].id : null
  cidr_ipv4                    = each.value.cidr != "" ? each.value.cidr : null
  ip_protocol                  = each.value.proto
  from_port                    = each.value.proto == "-1" ? null : each.value.from
  to_port                      = each.value.proto == "-1" ? null : each.value.to
  description                  = each.value.desc
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = { for k in keys(local.security_groups) : k => k if k != "rds" }

  security_group_id = aws_security_group.this[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound"
}
