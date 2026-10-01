#!/usr/bin/env bash
# RDS PostgreSQL 17 (db.t4g.micro, not public) and DATABASE_URL in SSM Parameter Store.
source "$(dirname "$0")/env.sh"
: "${SG_RDS:?run 01-network.sh first}"

STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null | tr -d '\r' || true)

if [[ -z "$STATUS" ]]; then
  step "Creating RDS instance $DB_INSTANCE (takes 5–15 min)"
  PG_VERSION=$(t aws rds describe-db-engine-versions --engine postgres \
    --query "DBEngineVersions[?starts_with(EngineVersion,'17.')].EngineVersion | [-1]" --output text)
  # Hex password: URL-safe, so it can go into DATABASE_URL without escaping.
  DB_PASSWORD=$(openssl rand -hex 16)
  # Keep the password only in SSM (encrypted), never on disk or in git.
  aws ssm put-parameter --name /spry/DB_PASSWORD --type SecureString --overwrite \
    --value "$DB_PASSWORD" >/dev/null
  aws rds create-db-instance --db-instance-identifier "$DB_INSTANCE" \
    --engine postgres --engine-version "$PG_VERSION" --db-instance-class db.t4g.micro \
    --allocated-storage 20 --storage-type gp3 \
    --db-name "$DB_NAME" --master-username "$DB_USER" --master-user-password "$DB_PASSWORD" \
    --vpc-security-group-ids "$SG_RDS" --no-publicly-accessible --no-multi-az \
    --backup-retention-period 1 --query DBInstance.DBInstanceIdentifier --output text
  unset DB_PASSWORD
else
  echo "RDS $DB_INSTANCE already exists ($STATUS)"
fi

step "Waiting until the database is available…"
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE"
DB_HOST=$(t aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
save DB_HOST "$DB_HOST"

step "Storing DATABASE_URL in SSM Parameter Store (SecureString)"
DB_PASSWORD=$(t aws ssm get-parameter --name /spry/DB_PASSWORD --with-decryption \
  --query Parameter.Value --output text)
aws ssm put-parameter --name /spry/DATABASE_URL --type SecureString --overwrite \
  --value "postgresql+asyncpg://$DB_USER:$DB_PASSWORD@$DB_HOST:5432/$DB_NAME?ssl=require" >/dev/null
unset DB_PASSWORD
echo "Database $DB_HOST is ready."
echo "Done. Next: bash infra/aws/03-image.sh"
