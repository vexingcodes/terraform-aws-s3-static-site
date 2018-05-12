provider "aws" {
    version = "~> 1.14"
    region  = "${var.region}"
}

terraform {
    backend "s3" {
      bucket  = "terraform-remote-state-bucket-s3"
      key     = "static-site-test/terraform.tfstate"
      region  = "eu-west-2"
      encrypt = true
    }
}

module "s3-static-site" {
    source          = "git::https://github.com/tiguard/terraform-aws-s3-static-site.git?ref=development"
    countries       = ["RU", "CN"]
    enable_iam_user = false
    secret          = "ghhyryr678rhbjoh"
    www_is_main     = true

    cdn_settings = {
        price_class              = "PriceClass_100"
        restriction_type         = "blacklist"
        minimum_protocol_version = "TLSv1.2_2018"
    }
}
