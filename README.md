# terraform-aws-rds-db-provisioner

A token-protected API that creates a new PostgreSQL database and user inside a private RDS instance, then stores the credentials in the default `postgres` database. Built with Terraform for AWS, intended for testing.

## How it works

```
curl → API Gateway (HTTP API) → authorizer Lambda (bearer token check)
     → provisioner Lambda (in VPC) → Secrets Manager (via VPC endpoint)
     → RDS PostgreSQL (port 5432, SSL)
```

1. The caller sends `POST /postgres-db-creator` with a bearer token and a JSON body.
2. The authorizer Lambda compares the token with the one Terraform generated. A wrong token never reaches the provisioner.
3. The provisioner reads the RDS master credentials from Secrets Manager and connects to RDS over SSL.
4. It creates the role and a database owned by that role, then saves the username, database name, password, and RDS endpoint in `public.database_n_credentials`.

## What gets created

Terraform creates 30 resources in `us-east-1` (the VPC itself is only read):

- Two private subnets in two availability zones, a dedicated route table with no internet route, and three security groups.
- A Secrets Manager VPC interface endpoint, so the Lambda needs no NAT gateway.
- RDS PostgreSQL 16 on `db.t4g.micro`, encrypted, private, SSL enforced, with an AWS-managed master password.
- A provisioner Lambda and an authorizer Lambda (Python 3.12), IAM roles, and invoke permissions.
- An HTTP API with the route `POST /postgres-db-creator`, stage `uat`.
- A random 40-character API token.
- CloudWatch log groups with 7-day retention.

## Prerequisites

- Terraform 1.5 or later
- AWS credentials for the target account
- `pip` and a bash-compatible shell (used to package `psycopg2-binary` for Lambda)
- A default VPC in `us-east-1`, or pass another with `-var='vpc_id=...'`

## Repository layout

```
.
├── main.tf
└── lambda/
    ├── provisioner/lambda_function.py
    └── authorizer/lambda_function.py
```

## Before you deploy

Check these once:

```bash
# No existing Secrets Manager endpoint (a second one with private DNS conflicts)
aws ec2 describe-vpc-endpoints --region us-east-1 \
  --filters Name=service-name,Values=com.amazonaws.us-east-1.secretsmanager

# Default VPC exists
aws ec2 describe-vpcs --region us-east-1 \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId'

# 172.31.200.0/24 and 172.31.201.0/24 must not already be used
aws ec2 describe-subnets --region us-east-1 \
  --filters Name=vpc-id,Values=<vpc-id> --query 'Subnets[].CidrBlock'
```

**Shared VPC caution:** with private DNS enabled, every Secrets Manager call from anything in this VPC resolves to this stack's endpoint. Other workloads in the same VPC that use Secrets Manager would time out. Use a dedicated VPC if that matters.

## Deploy

```bash
terraform init
terraform plan      # expect: 30 to add, 0 to change, 0 to destroy
terraform apply
```

Apply takes about 5 to 10 minutes, mostly RDS.

## Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `us-east-1` | AWS region |
| `stage` | `uat` | API Gateway stage name |
| `lambda_runtime` | `python3.12` | Lambda runtime, also used to pick the `psycopg2-binary` wheel |
| `vpc_id` | `null` | Existing VPC to use. `null` uses the default VPC |
| `private_subnet_cidrs` | `["172.31.200.0/24", "172.31.201.0/24"]` | Two new /24 ranges inside the VPC |

## Outputs

| Output | Description |
|---|---|
| `api_url` | Full endpoint URL |
| `api_token` | Bearer token (sensitive) |
| `rds_endpoint` | RDS hostname |

## Usage

**bash**

```bash
TOKEN=$(terraform output -raw api_token)
URL=$(terraform output -raw api_url)

curl -i -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database_name":"test_db01","username":"test_user01"}'
```

**fish**

```fish
set URL (terraform output -raw api_url)
set TOKEN (terraform output -raw api_token)

curl -i -X POST $URL \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database_name":"test_db01","username":"test_user01"}'
```

### Request

```json
{"database_name": "test_db01", "username": "test_user01"}
```

Both names must be 3 to 63 characters: lowercase letters, digits, and underscores, starting with a letter. Names starting with `pg_` and reserved names (`postgres`, `rdsadmin`, `public`, `template0`, `template1`, `rds_superuser`) are rejected.

### Responses

| Status | Meaning |
|---|---|
| 201 | `CREATED`. Returns database, username, password, endpoint, and port. The password is returned only on creation. |
| 200 | `EXISTS`. The same database and user pair is already registered. No password returned. |
| 400 | Invalid JSON, or an invalid or reserved name. |
| 401 / 403 | Missing or wrong token. |
| 409 | `CONFLICT`. A name is already registered, or already exists in PostgreSQL. |
| 500 | Internal error. Check the CloudWatch logs. |

### Credentials table

The provisioner creates this table on the first call:

```sql
CREATE TABLE IF NOT EXISTS public.database_n_credentials (
    "DB_USERNAME" VARCHAR(63) PRIMARY KEY,
    "DB_NAME" VARCHAR(63) UNIQUE NOT NULL,
    "DB_PASSWORD" TEXT NOT NULL,
    "RDS_ENDPOINT" VARCHAR(255) NOT NULL
);
```

Each user maps to exactly one database.

## Security notes

- **Passwords are stored in plaintext** in `database_n_credentials`. Acceptable for testing only.
- **The API token lives in Terraform state** (marked sensitive) and in the authorizer's environment. Never commit `terraform.tfstate`. Rotate the token with `terraform taint random_password.api_token` and then `terraform apply`.
- **The database is private.** It has no public IP, no internet route, and its security group only accepts port 5432 from the provisioner Lambda. Querying it directly needs a bastion or EC2 instance inside the VPC.
- **The token is a single shared secret** with no expiry or per-user identity. For multiple callers, use a JWT authorizer (for example Cognito).
- **The 201 response contains the new password.** Avoid pasting it into shared places.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Red error on the authorizer trigger in the Lambda console | Display quirk only. The console expects a route integration, and the authorizer is not one. The API works normally. |
| `pip` error during apply | Install `pip`, change `pip` to `pip3` in the `local-exec` block, or use `python3.12` or `python3.13`. |
| 500 on a valid token | Run `aws logs tail /aws/lambda/rds-postgres-db-provisioner --region us-east-1 --since 10m`. Common causes: no route to Secrets Manager or RDS. |
| Subnet CIDR conflict | Change `private_subnet_cidrs` to unused ranges inside the VPC. |
| Destroy pauses on subnets | Lambda network interfaces take several minutes to release. Wait or rerun `terraform destroy`. |

## Cost and cleanup

The `db.t4g.micro` instance and the Secrets Manager interface endpoint (about $7 per month) cost money while they exist. Remove everything with:

```bash
terraform destroy
```

RDS is configured with `skip_final_snapshot = true` and no backups, so destroying it deletes the data permanently.

## Possible next steps

- Store each database's password in Secrets Manager instead of plaintext.
- Add delete and password-rotation endpoints.
- Use a dedicated VPC, multi-AZ, backups, and deletion protection for non-test use.