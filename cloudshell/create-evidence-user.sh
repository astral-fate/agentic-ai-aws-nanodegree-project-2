#!/usr/bin/env bash
#
# Create a read-only IAM user for console screenshot capture.
#
#   bash create-evidence-user.sh            create it and print the keys
#   bash create-evidence-user.sh --delete   remove it and its keys
#
# Why this exists: scripts/capture_console.py signs a browser into the console
# with sts:GetFederationToken, which needs no password and no manual step. The
# account root **cannot call GetFederationToken at all** — AWS forbids it — so
# federated capture needs an IAM user, and CloudShell usually runs as root.
#
# The user gets ReadOnlyAccess plus sts:GetFederationToken, and nothing else.
# A session that could change infrastructure is a session that could change it
# by accident, and this one exists only to look at pages.
#
# The printed secret is shown once. Put both values into the repo's .env as
# EVIDENCE_AWS_ACCESS_KEY_ID / EVIDENCE_AWS_SECRET_ACCESS_KEY — .env is
# git-ignored. Delete the user when the screenshots are captured.

set -uo pipefail

IAM_USER="${IAM_USER:-evidence-capture}"
POLICY_NAME="evidence-federation"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'
RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
die()  { bad "$*"; exit 1; }

command -v aws >/dev/null || die "aws CLI not found — run this in AWS CloudShell."
command -v jq  >/dev/null || die "jq not found — run this in AWS CloudShell."

# ── delete ───────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--delete" ]]; then
  printf '%sRemoving %s%s\n\n' "$BOLD" "$IAM_USER" "$RESET"

  for key in $(aws iam list-access-keys --user-name "$IAM_USER" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$key" >/dev/null 2>&1 \
      && ok "deleted access key $key"
  done

  aws iam delete-user-policy --user-name "$IAM_USER" --policy-name "$POLICY_NAME" >/dev/null 2>&1
  aws iam detach-user-policy --user-name "$IAM_USER" \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess >/dev/null 2>&1
  aws iam delete-user --user-name "$IAM_USER" >/dev/null 2>&1 \
    && ok "deleted user $IAM_USER" \
    || warn "user $IAM_USER not found"

  printf '\nAlso remove EVIDENCE_AWS_* from your local .env.\n\n'
  exit 0
fi

# ── create ───────────────────────────────────────────────────────────────────
printf '%sCreating a read-only IAM user for console capture%s\n\n' "$BOLD" "$RESET"

account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "no AWS credentials"
ok "account $account"

if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
  ok "$IAM_USER already exists"
else
  aws iam create-user --user-name "$IAM_USER" >/dev/null 2>&1 \
    || die "could not create $IAM_USER"
  ok "created $IAM_USER"
fi

aws iam attach-user-policy --user-name "$IAM_USER" \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess >/dev/null 2>&1 \
  && ok "attached ReadOnlyAccess"

# GetFederationToken is not in ReadOnlyAccess and has to be granted explicitly.
aws iam put-user-policy --user-name "$IAM_USER" --policy-name "$POLICY_NAME" \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetFederationToken","Resource":"*"}]}' \
  >/dev/null 2>&1 && ok "granted sts:GetFederationToken"

# IAM allows two keys per user; clear old ones so this is re-runnable.
existing="$(aws iam list-access-keys --user-name "$IAM_USER" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null)"
for key in $existing; do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$key" >/dev/null 2>&1 \
    && warn "revoked previous key $key"
done

keys="$(aws iam create-access-key --user-name "$IAM_USER" --query AccessKey --output json 2>/dev/null)"
[[ -z "$keys" || "$keys" == "None" ]] && die "could not create an access key"

access="$(jq -r .AccessKeyId <<<"$keys")"
secret="$(jq -r .SecretAccessKey <<<"$keys")"
ok "created a new access key"

printf '\n  %swaiting 15s for IAM to propagate%s ' "$DIM" "$RESET"
sleep 15
printf '%s✓%s\n' "$GREEN" "$RESET"

cat <<EOF

${BOLD}────────────────────────────────────────────────────────────────────${RESET}
 Add these two lines to the repo's .env on your own machine
 (.env is git-ignored; the secret is shown once and never again)
${BOLD}────────────────────────────────────────────────────────────────────${RESET}

EVIDENCE_AWS_ACCESS_KEY_ID=${access}
EVIDENCE_AWS_SECRET_ACCESS_KEY=${secret}

${BOLD}Then, locally:${RESET}

  pip install playwright boto3
  python -m playwright install chromium
  python scripts/capture_console.py --out evidence/run-02/screenshots

It signs a headless Chrome into the console with no password and captures
each page.

${YELLOW}When the screenshots are captured, delete this user:${RESET}
  bash cloudshell/create-evidence-user.sh --delete

EOF
