# Remote state configuration.
# The bucket and DynamoDB table referenced here are created by bootstrap.sh
# before terraform init is run for the first time.
#
# Values are populated from config/defaults.env by up.sh via
# the TF_CLI_ARGS_init environment variable.

terraform {
  backend "s3" {
    # These values are injected at runtime by up.sh from config/defaults.env.
    # Do not hardcode bucket names, account IDs, or regions here.
    # bucket         = set via -backend-config in up.sh
    # key            = set via -backend-config in up.sh
    # region         = set via -backend-config in up.sh
    # dynamodb_table = set via -backend-config in up.sh
    # kms_key_id     = set via -backend-config in up.sh
    encrypt = true
  }
}
