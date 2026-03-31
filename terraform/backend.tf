# Remote state configuration.
# The S3 bucket referenced here is created by bootstrap.sh before terraform
# init is run for the first time. State locking uses S3 native locking
# (use_lockfile = true), requiring no separate DynamoDB table.
#
# Values are populated from config/defaults.env by up.sh via
# the TF_CLI_ARGS_init environment variable.

terraform {
  backend "s3" {
    # These values are injected at runtime by up.sh from config/defaults.env.
    # Do not hardcode bucket names, account IDs, or regions here.
    # bucket   = set via -backend-config in up.sh
    # key      = set via -backend-config in up.sh
    # region   = set via -backend-config in up.sh
    use_lockfile = true
    encrypt      = true
  }
}
