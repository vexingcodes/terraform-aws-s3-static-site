variable "domains" {
  type        = "list"
  description = "A list of domains to create the CloudFront infrastructure for. "
  default     = []
}

variable "secret" {
  type        = "string"
  description = "A secret string between CloudFront and S3 to control access."
  default     = ""
}

variable "www_is_main" {
  type        = "string"
  description = "Controls whether the naked domain or www subdomain is the main site."
  default     = false
}

variable "enable_iam_user" {
  type        = "string"
  description = "Controls whether the module should create the AWS IAM deployment user."
  default     = true
}

variable "cdn_settings" {
  type        = "map"
  description = "CloudFront CDN settings."
  default     = {}
}

variable "countries" {
  type        = "list"
  description = "The ISO 3166-alpha-2 country codes of the countries to be black- or white-listed."
  default     = []
}
