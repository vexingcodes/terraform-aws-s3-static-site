variable "domains" {
  type = "list"
  description = "The domain name of the site."
}

variable "secret" {
  type = "string"
  description = "A secret string between CloudFront and S3 to control access."
}

variable "www_is_main" {
  type    = "string"
  default = false
}

variable "enable_iam_user" {
  type    = "string"
  default = true
}

variable "cdn_settings" {
  type = "map"
  description = "CloudFront CDN settings"
  default = {
  }
}
