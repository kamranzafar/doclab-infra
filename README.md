# doclab-infra

Terraform for the `*.doc` architecture: workspaces / corp / mgmt / sec / dmz domains on AWS.

## How the diagram maps to AWS

| Diagram element | Implementation |
|---|---|
| Each "Domain" box | Subnet(s) in one VPC (`10.0.0.0/16`), tagged with the domain |
| workspaces.doc → workstation | `aws_workspaces_directory` + `aws_workspaces_workspace` (2 subnets, `10.0.20-21.0/24`) |
| corp.doc → Domain Controller (AD + DNS) | AWS Managed Microsoft AD `corp.doc` (2 DCs, `10.0.10-11.0/24`); VPC DHCP points at it |
| corp.doc → Storage (S3) | Private, versioned, KMS-encrypted bucket via S3 gateway endpoint |
| mgmt.doc → rhel-server (IPA server, Ansible, Rsyslog) | RHEL 9 EC2 `10.0.30.10` |
| mgmt.doc → jumpserver (IPA client, Rsyslog) | RHEL 9 EC2 `10.0.30.11` |
| sec.doc → rhel-security (IPA client, Rsyslog, Docker/OpenVAS CE, GLPI) | RHEL 9 EC2 `10.0.40.10` |
| sec.doc → security-main (IPA client, Graylog, Snort) | RHEL 9 EC2 `10.0.40.11` (+ optional VPC Traffic Mirroring for Snort) |
| dmz.doc → webserver (NGINX) | RHEL 9 EC2 `10.0.50.10` + Elastic IP |
| dmz.doc → OpenVPN (EC2) | RHEL 9 EC2 `10.0.50.11` + Elastic IP |
| dmz.doc → PII Database (RDS) | PostgreSQL, isolated subnets with no internet route, managed master secret |
| dmz.doc → Backup Storage (S3) | Bucket with Glacier IR tiering; webserver role can write to it |
| Firewall icon on the boundary | AWS Network Firewall with IGW ingress routing in front of the DMZ |
| Green dashed lines (IPA) | SG rules: clients → rhel-server on 80/443/389/636/88/464/123 |
| Blue dashed lines (logs) | SG rules: VPC → Graylog 1514 tcp/udp, 12201 udp; rsyslog forwarding in bootstrap |
| Dark red dashed lines (Ansible) | SG rules: rhel-server → all hosts on 22; generated Ansible inventory |
| Red solid lines (AD) | GLPI and WorkSpaces → AD (Managed AD SG allows VPC traffic) |
| Dashed NGINX ↔ RDS | SG rule: webserver → RDS 5432 |

Private Route 53 zones `mgmt.doc`, `sec.doc` and `dmz.doc` hold A records for every host.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Managed AD takes 30-45 minutes to create; WorkSpaces registration waits on it.

## Lite mode (AWS Free plan)

Set `lite_mode = true` to get a build that runs on a Free plan account (credits only) and costs roughly USD 0.40/hr (~USD 10/day if left running) instead of ~1.30/hr:

| | Full | Lite |
|---|---|---|
| corp.doc Managed AD | yes | **off** (Directory Service is blocked on the Free plan) |
| workspaces.doc WorkSpaces | yes | **off** (needs the AD) |
| Network Firewall | yes | **off** (paid plan only); security groups still enforce the perimeter |
| Traffic Mirroring | optional | **off** |
| OS | RHEL 9 | **AlmaLinux 9** (RHEL-compatible, no licence charge) |
| Instance types | t3.medium-t3.xlarge | free-tier eligible: t3.micro/small, c7i-flex.large (OpenVAS), m7i-flex.large (Graylog) |
| RDS | as configured | forced single-AZ |

Everything else (VPC layout, mgmt/sec/dmz hosts, FreeIPA, Ansible, Graylog, S3, RDS, Route 53) is the same. `ansible/inventory.ini` still sets `ad_domain`, but there is no AD to point GLPI at, so skip the GLPI LDAP step.

The NAT gateway (~USD 0.06/hr) is kept so private hosts can install packages. Run `terraform destroy` when you are not using the lab: the credits last much longer that way.

Switching an existing deployment between modes does not change the OS of hosts already built (`ami` is in `ignore_changes`); destroy and re-apply for a clean switch.

## After apply: configure the services with Ansible

The playbooks in `ansible/` configure every service. They run on rhel-server (the only host that can reach the private subnets); `scripts/ansible.sh` copies `ansible/` there over SSM Session Manager and runs a playbook:

```bash
AWS_PROFILE=doclab scripts/ansible.sh              # everything (site.yml)
AWS_PROFILE=doclab scripts/ansible.sh graylog.yml  # one service
AWS_PROFILE=doclab scripts/ansible.sh verify.yml   # read-only health check
```

| Playbook | Host | What it sets up |
|---|---|---|
| `common.yml` | all | swap on small hosts, base tools, controller secrets dir |
| `graylog.yml` | security-main | Graylog + OpenSearch + MongoDB (Docker); inputs Syslog TCP/UDP 1514, GELF UDP 12201 |
| `freeipa.yml` | rhel-server, IPA clients | FreeIPA server (realm `MGMT.DOC`, DNS stays in Route 53), enrols jumpserver, rhel-security, security-main; creates the lab users, `it-admins` group, HBAC and sudo rules |
| `nginx.yml` | webserver | NGINX with HTTPS (self-signed), HTTP→HTTPS redirect, PostgreSQL client |
| `openvpn.yml` | openvpn | easy-rsa PKI, OpenVPN on UDP 1194, NAT, client profiles |
| `snort.yml` | security-main | Snort 3 (Talos container) + community rules; alerts shipped to Graylog |
| `glpi.yml` | rhel-security | GLPI + MariaDB behind HTTPS on 443 |
| `openvas.yml` | rhel-security | Greenbone Community Edition; container logs to Graylog via GELF |
| `verify.yml` | all | checks logs reach Graylog, Snort alerts, IPA enrolment, UIs, DB port, VPN |

Every play is idempotent, so re-running is safe.

**Passwords** are generated on first run and kept on rhel-server in `/home/ec2-user/.doclab-secrets/` (`graylog_admin`, `ipa_admin`, `ipa_directory_manager`, `openvas_admin`, `glpi_db`, ...). VPN client profiles are in `.doclab-secrets/openvpn/`.

**Lab users** (FreeIPA, defined in `ansible/group_vars/all.yml` as `ipa_lab_users`):

| User | Role | Groups | Can do |
|---|---|---|---|
| `labadmin` | Lab administrator | `admins`, `it-admins` | Manage FreeIPA (users, hosts, policies) + SSH and sudo on all IPA hosts |
| `itadmin` | IT administrator | `it-admins` | SSH and sudo on all IPA hosts; no FreeIPA admin rights |

Passwords are in `.doclab-secrets/ipa_user_labadmin` / `ipa_user_itadmin`; change them with `passwd` after first login. Log in over the VPN with `ssh itadmin@jumpserver.mgmt.doc` (password), then `ssh rhel-server.mgmt.doc`, `ssh security-main.sec.doc` or `ssh rhel-security.sec.doc` (Kerberos, no password). webserver and openvpn are not IPA clients, so these users can't log in there.

**Admin UIs** are private (security groups only allow jumpserver and OpenVPN clients):

| UI | URL | Login |
|---|---|---|
| Graylog | http://security-main.sec.doc:9000 | `admin` / `graylog_admin` |
| OpenVAS (GSA) | https://rhel-security.sec.doc:9392 | `admin` / `openvas_admin` |
| GLPI | https://rhel-security.sec.doc | `glpi` / `glpi` (change it) |
| FreeIPA | https://rhel-server.mgmt.doc/ipa/ui | `admin` / `ipa_admin` |

Reach them either over the VPN (import the `.ovpn` profile) or with Session Manager port forwarding, e.g. for Graylog:

```bash
AWS_PROFILE=doclab aws ssm start-session --target <instance_ids["security-main.sec.doc"]> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9000"],"localPortNumber":["9000"]}'
```

(needs the AWS Session Manager plugin). For WorkSpaces (full build only), set `workspace_bundle_id` and `workspace_users`, then apply again.

**Notes:** OpenVAS feeds keep syncing for a while after the first start before scans return full results. In lite mode there is no Traffic Mirroring, so Snort only inspects security-main's own traffic. In lite mode there is no AD for GLPI to use; in the full build, add `corp.doc` as an LDAP directory in GLPI using `terraform output ad_dns_ips`.

## Notes and caveats

- **Bootstrap scope:** user_data installs base packages, SSM agent, rsyslog forwarding and the Ansible key. Application configuration is intentionally left to Ansible, which is what the diagram shows running on rhel-server.
- **Domain Controller:** Managed AD replaces a self-managed Windows DC because WorkSpaces needs a registered AWS directory. If you need a real EC2 DC, swap in a Windows EC2 + AD Connector.
- **Single-AZ hosts:** EC2 hosts, NAT and the firewall live in one AZ to keep cost down. Add a second set per AZ for production.
- **Traffic Mirroring:** off by default. Both webserver and security-main must be instance types that support it (e.g. m6i, c6i); see `terraform.tfvars.example`.
- **WorkSpaces AZs:** WorkSpaces only supports some AZ IDs per region. If registration fails, change `azs`.
- **Secrets in state:** the AD admin password and Ansible private key are in Terraform state. Use an encrypted remote backend with restricted access.
- **Cost drivers:** Network Firewall (~USD 0.40/hr), Managed AD, NAT gateway, WorkSpaces and the `t3.xlarge` Graylog host.
- **Destroy:** set `db_deletion_protection = false` and apply before `terraform destroy`. S3 buckets must be emptied first.
