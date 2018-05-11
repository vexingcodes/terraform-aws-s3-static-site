provider "template" {
    version = "~> 1.0"
}

provider "aws" {
    alias  = "use1"
    region = "us-east-1"
}

# Templates can only handle strings so convert to a string and join
data "template_file" "www_first" {
    count    = "${var.www_is_main}"
    template = "${format("%s,%s", local.www_domains, join(",", var.domains))}"
}

data "template_file" "root_first" {
    count    = "${1 - var.www_is_main}"
    template = "${format("%s,%s", join(",", var.domains), local.www_domains)}"
}

data "aws_route53_zone" "zone" {
    count = "${length(local.zone_domain_name)}"
    name  = "${format("%s.", local.zone_domain_name[count.index])}"
}

locals {
    all_domains      = "${split(",", join(",", concat(data.template_file.www_first.*.rendered, data.template_file.root_first.*.rendered)))}"
    primary_domain   = "${local.all_domains[0]}"
    www_domains      = "${join(",", formatlist("www.%s", var.domains))}"
    redirect_domains = "${slice(local.all_domains, 1, length(local.all_domains))}"

    # Ugly but we need a valid zone name for each domain to feed into the zone data source (i.e. without the "www" part).
    # A map would have been better but we'll have to do with a list parallel to local.all_domains
    zone_domain_name = "${split(",", replace(join(",", local.all_domains), "/(?i)www\\./", ""))}"

    # Ditto here.  The order shouldn't change.
    endpoints = ["${split(",", format("%s,%s", aws_s3_bucket.main.website_endpoint, join(",", aws_s3_bucket.redirect.*.website_endpoint)))}"]
}

# This policy is applied to the main S3 bucket.  It allows CloudFront access to
# the bucket through the use of the user-agent field through which S3 and
# CloudFront share a secret. This kind of policy is not necessary for the
# redirect bucket since it doesn't store any objects, it just redirects.
data "aws_iam_policy_document" "bucket" {
  statement {
    actions = [
      "s3:GetObject"
    ]

    resources = [
      "arn:aws:s3:::${local.primary_domain}/*",
    ]

    principals {
      type = "AWS"
      identifiers = ["*"]
    }

    condition {
      test = "StringEquals"
      variable = "aws:UserAgent"
      values = ["${var.secret}"]
    }
  }
}
#
## This policy is applied to the IAM user that handles deployments for the
## static site. It basically allows full access to the main S3 bucket, and
## allows the user to create CloudFront invalidations when the site is updated
## so that the new content is rolled out quickly.
#data "aws_iam_policy_document" "deploy" {
#  statement {
#    actions = [
#      "s3:ListBucket"
#    ]
#
#    resources = [
#      "${aws_s3_bucket.main.arn}"
#    ]
#  }
#
#  statement {
#    actions = [
#      "s3:DeleteObject",
#      "s3:GetObject",
#      "s3:GetObjectAcl",
#      "s3:ListBucket",
#      "s3:PutObject",
#      "s3:PutObjectAcl"
#    ]
#
#    resources = [
#      "${aws_s3_bucket.main.arn}/*"
#    ]
#  }
#
#  statement {
#    actions = [
#      "cloudfront:CreateInvalidation"
#    ]
#
#    resources = [
#      "*" # A specific resource cannot be specified here, unfortunately.
#    ]
#  }
#}
#
resource "aws_s3_bucket" "main" {
    bucket = "${local.primary_domain}"
    policy = "${data.aws_iam_policy_document.bucket.json}"

    website = {
      index_document = "index.html"
      error_document = "404.html"
    }
}

resource "aws_s3_bucket" "redirect" {
    count  = "${length(local.redirect_domains)}"
    bucket = "${local.redirect_domains[count.index]}"

    website = {
      redirect_all_requests_to = "${aws_s3_bucket.main.id}"
    }
}

resource "aws_acm_certificate" "cert" {
    provider                  = "aws.use1" # CloudFront requires certificates in this region.
    domain_name               = "${local.primary_domain}"
    subject_alternative_names = ["${local.redirect_domains}"]
    validation_method         = "DNS"
}

resource "aws_route53_record" "cert" {
  count   = "${length(local.all_domains)}"
  name    = "${lookup(aws_acm_certificate.cert.domain_validation_options[count.index], "resource_record_name")}"
  type    = "${lookup(aws_acm_certificate.cert.domain_validation_options[count.index], "resource_record_type")}"
  records = ["${lookup(aws_acm_certificate.cert.domain_validation_options[count.index], "resource_record_value")}"]
  zone_id = "${element(data.aws_route53_zone.zone.*.zone_id, count.index)}"
  ttl     = 300
}

resource "aws_acm_certificate_validation" "cert" {
    provider                = "aws.use1" # CloudFront requires certificates in this region.
    certificate_arn         = "${aws_acm_certificate.cert.arn}"
    validation_record_fqdns = ["${aws_route53_record.cert.*.fqdn}"]

    timeouts {
      create = "2h"
    }
}

resource "aws_cloudfront_distribution" "cdn" {
    count           = "${length(local.all_domains)}"
    enabled         = true
    http_version    = "http2"
    aliases         = ["${local.all_domains[count.index]}"]
    is_ipv6_enabled = true

    origin {
      domain_name = "${local.endpoints[count.index]}"
      origin_id   = "${format("S3-%s", local.all_domains[count.index])}"

      custom_origin_config {
        origin_protocol_policy = "http-only"
        http_port              = "80"
        https_port             = "443"
        origin_ssl_protocols = ["TLSv1", "TLSv1.2"]
      }

      custom_header {
        name  = "User-Agent"
        value = "${var.secret}"
      }
    }

    restrictions {
      geo_restriction {
        restriction_type = "none"
      }
    }

    viewer_certificate {
      acm_certificate_arn      = "${aws_acm_certificate_validation.cert.certificate_arn}"
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1"
    }

    default_cache_behavior {
      allowed_methods  = ["GET", "HEAD"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = "${format("S3-%s", local.all_domains[count.index])}"
      compress = "true"
      viewer_protocol_policy = "redirect-to-https"
      min_ttl = 0
      default_ttl = 3600
      max_ttl = 86400

      forwarded_values {
        query_string = false

        cookies {
          forward = "none"
        }
      }
    }
}

#resource "aws_route53_record" "A" {
#  count = "${length(local.domains)}"
#  zone_id = "${aws_route53_zone.zone.zone_id}"
#  name = "${element(local.domains, count.index)}"
#  type = "A"
#
#  alias {
#    name = "${element(aws_cloudfront_distribution.cdn.*.domain_name,
#                      count.index)}"
#    zone_id = "${element(aws_cloudfront_distribution.cdn.*.hosted_zone_id,
#                         count.index)}"
#    evaluate_target_health = false
#  }
#}
#
#resource "aws_route53_record" "AAAA" {
#  count = "${length(local.domains)}"
#
#  zone_id = "${aws_route53_zone.zone.zone_id}"
#  name    = "${element(local.domains, count.index)}"
#  type    = "AAAA"
#
#  alias {
#
#  }
#}
#
#resource "aws_iam_user" "deploy" {
#  name = "${var.domain}-deploy"
#  path = "/"
#}
#
#resource "aws_iam_access_key" "deploy" {
#  user = "${aws_iam_user.deploy.name}"
#}
#
#resource "aws_iam_user_policy" "deploy" {
#  name = "deploy"
#  user = "${aws_iam_user.deploy.name}"
#  policy = "${data.aws_iam_policy_document.deploy.json}"
#}
#