variable "domain" {
  type = "string"
  description = "The domain name of the site."
}

variable "secret" {
  type = "string"
  description = "A secret string between CloudFront and S3 to control access."
}
