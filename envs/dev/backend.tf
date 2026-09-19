# The bucket is created by bootstrap/bootstrap.sh before the first init, since
# Terraform cannot create the backend it is about to use.
#
#   terraform init -backend-config=bucket=<your-state-bucket>
terraform {
  backend "gcs" {
    prefix = "dev"
  }
}
