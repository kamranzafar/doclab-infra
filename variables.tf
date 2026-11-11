############################################
# General
############################################
variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Name prefix for all resources (lowercase; also used in S3 bucket names)."
  type        = string
  default     = "doclab"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project))
    error_message = "project must be 3-20 characters of lowercase letters, digits or hyphens."
  }
}

variable "azs" {
  description = "Exactly two AZs. Managed AD, WorkSpaces and RDS each need two. WorkSpaces only supports some AZ IDs per region - check before changing."
  type        = list(string)
  default     = ["ap-southeast-2a", "ap-southeast-2b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "Provide exactly two availability zones."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must be /16 or larger; subnets are carved as /24s (plus one /28 for the firewall)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid CIDR with a prefix of /16 or larger."
  }
}

############################################
# Lite mode
############################################
variable "lite_mode" {
  description = <<-EOT
    Cheap build that runs on an AWS Free plan account. Turns off Managed AD (corp.doc),
    WorkSpaces, Network Firewall and Traffic Mirroring, uses AlmaLinux 9 instead of RHEL 9
    (no licence charge) and free-tier-eligible instance types.
  EOT
  type        = bool
  default     = false
}

############################################
# Perimeter access
############################################
variable "web_allowed_cidrs" {
  description = "CIDRs allowed to reach NGINX on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vpn_allowed_cidrs" {
  description = "CIDRs allowed to reach OpenVPN on UDP 1194. Tighten this if you can."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

############################################
# Compute
############################################
variable "instance_types" {
  description = "Instance type per host. Override only the ones you need; unset hosts get the full or lite default (see locals.tf)."
  type = object({
    rhel_server   = optional(string) # FreeIPA + Ansible
    jumpserver    = optional(string)
    rhel_security = optional(string) # OpenVAS CE + GLPI
    security_main = optional(string) # Graylog (OpenSearch + MongoDB) + Snort
    webserver     = optional(string)
    openvpn       = optional(string)
  })
  default = {}
}

variable "key_name" {
  description = "Optional EC2 key pair for break-glass SSH. SSM Session Manager works without one."
  type        = string
  default     = null
}

############################################
# Feature toggles
############################################
variable "enable_network_firewall" {
  description = "Deploy AWS Network Firewall in front of the DMZ (~USD 0.40/hr + data processing)."
  type        = bool
  default     = true
}

variable "enable_traffic_mirroring" {
  description = "Mirror webserver traffic to security-main for Snort. Source and target must be instance types that support Traffic Mirroring (e.g. m6i/c6i)."
  type        = bool
  default     = false
}

variable "enable_vuln_scanning" {
  description = "Allow rhel-security (OpenVAS) to reach every host on all ports for scanning."
  type        = bool
  default     = true
}

variable "use_ad_dns_for_vpc" {
  description = "Point the VPC DHCP options at the AD DNS servers (as in the diagram, where the DC provides DNS)."
  type        = bool
  default     = true
}

############################################
# Active Directory (corp.doc)
############################################
variable "ad_domain" {
  description = "FQDN of the Active Directory domain."
  type        = string
  default     = "corp.doc"
}

variable "ad_short_name" {
  description = "NetBIOS name of the AD domain."
  type        = string
  default     = "CORP"
}

variable "ad_edition" {
  description = "AWS Managed Microsoft AD edition: Standard or Enterprise."
  type        = string
  default     = "Standard"
}

############################################
# WorkSpaces (workspaces.doc)
############################################
variable "create_workspaces_default_role" {
  description = "Create the account-wide workspaces_DefaultRole. Set false if it already exists in the account."
  type        = bool
  default     = true
}

variable "workspace_bundle_id" {
  description = "WorkSpaces bundle ID (aws workspaces describe-workspace-bundles --owner AMAZON). No WorkSpaces are created while null."
  type        = string
  default     = null
}

variable "workspace_users" {
  description = "AD usernames to create WorkSpaces for. Users must already exist in AD ('Admin' exists by default)."
  type        = list(string)
  default     = []
}

############################################
# PII database (RDS)
############################################
variable "db_engine_version" {
  description = "PostgreSQL major or major.minor version."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_username" {
  type    = string
  default = "appadmin"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}
