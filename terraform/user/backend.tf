terraform {
  backend "s3" {
    encrypt = true
    # All values injected at runtime via -backend-config flags in up.sh / down.sh
  }
}
