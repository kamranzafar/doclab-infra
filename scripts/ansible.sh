#!/usr/bin/env bash
# Run an Ansible playbook on the lab's controller (rhel-server) over SSM Session Manager.
#
#   AWS_PROFILE=doclab scripts/ansible.sh                    # whole lab (site.yml)
#   AWS_PROFILE=doclab scripts/ansible.sh graylog.yml        # one playbook
#   AWS_PROFILE=doclab scripts/ansible.sh nginx.yml --check  # extra ansible-playbook args
#
# Copies ./ansible (including the Terraform-generated inventory.ini) to
# /home/ec2-user/doclab-ansible on rhel-server, runs the playbook as ec2-user and prints the
# end of the log. The full log stays on rhel-server at /home/ec2-user/ansible-last.log.
set -euo pipefail
cd "$(dirname "$0")/.."

PLAYBOOK="${1:-site.yml}"
shift || true
EXTRA_ARGS="$*"

[ -f "ansible/$PLAYBOOK" ] || { echo "No such playbook: ansible/$PLAYBOOK" >&2; exit 1; }
[ -f ansible/inventory.ini ] || { echo "ansible/inventory.ini missing - run terraform apply first" >&2; exit 1; }

INSTANCE_ID=$(terraform output -json instance_ids | python3 -c 'import json,sys; print(json.load(sys.stdin)["rhel-server.mgmt.doc"])')
REGION=$(terraform output -raw region 2>/dev/null || aws configure get region)

PAYLOAD=$(COPYFILE_DISABLE=1 tar -C ansible --exclude='.DS_Store' -czf - . | base64 | tr -d '\n')

PARAMS=$(PAYLOAD="$PAYLOAD" PLAYBOOK="$PLAYBOOK" EXTRA_ARGS="$EXTRA_ARGS" python3 - <<'EOF'
import json, os, shlex
d = "/home/ec2-user/doclab-ansible"
script = f"""set -e
rm -rf {d}.new && mkdir -p {d}.new
echo '{os.environ["PAYLOAD"]}' | base64 -d | tar -xzf - -C {d}.new
rm -rf {d} && mv {d}.new {d} && chown -R ec2-user:ec2-user {d} && chmod 755 {d}
cd {d}
set +e
sudo -u ec2-user -H ANSIBLE_FORCE_COLOR=0 ansible-playbook {shlex.quote(os.environ["PLAYBOOK"])} {os.environ["EXTRA_ARGS"]} > /home/ec2-user/ansible-last.log 2>&1
rc=$?
tail -c 22000 /home/ec2-user/ansible-last.log
exit $rc
"""
print(json.dumps({"commands": [script], "executionTimeout": ["10800"]}))
EOF
)

CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --timeout-seconds 600 \
  --comment "doclab ansible $PLAYBOOK" --parameters "$PARAMS" \
  --query Command.CommandId --output text)
echo "Running $PLAYBOOK on rhel-server ($INSTANCE_ID), command $CMD_ID ..."

while :; do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed) sleep 15 ;; *) break ;; esac
done

aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
echo "Status: $STATUS"
[ "$STATUS" = "Success" ]
