locals {
  www_domain = "www.${var.domain}"

  # This is a parallel array with local.endpoints, keep them in the same order.
  #
  # The module is configured by default to redirect www.domain.name to
  # domain.name. If the desired behavior is to redirect domain.name to
  # www.domain.name simply change the ordering in local.domains and
  # local.endpoints.
  #
  # This module doesn't currently support having more than two domains in this
  # list. It would be nice to update the module to have the first one in the
  # list be the main one, and the remaining domains be redirects to the main
  # one, but for now I only care about having one subdomain redirect to the
  # apex.
  domains = [
    "${var.domain}",
    "${local.www_domain}"
  ]

  # This is a parallel array with local.domains, keep them in the
  # same order.
  endpoints = [
    "${aws_s3_bucket.main.website_endpoint}",
    "${aws_s3_bucket.redirect.website_endpoint}"
  ]
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
      "arn:aws:s3:::${var.domain}/*",
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

# This policy is applied to the IAM user that handles deployments for the
# static site. It basically allows full access to the main S3 bucket, and
# allows the user to create CloudFront invalidations when the site is updated
# so that the new content is rolled out quickly.
data "aws_iam_policy_document" "deploy" {
  statement {
    actions = [
      "s3:ListBucket"
    ]

    resources = [
      "${aws_s3_bucket.main.arn}"
    ]
  }

  statement {
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectAcl",
      "s3:ListBucket",
      "s3:PutObject",
      "s3:PutObjectAcl"
    ]

    resources = [
      "${aws_s3_bucket.main.arn}/*"
    ]
  }

  statement {
    actions = [
      "cloudfront:CreateInvalidation"
    ]

    resources = [
      "${element(aws_cloudfront_distribution.cdn.*.arn, 0)}"
    ]
  }
}

resource "aws_s3_bucket" "main" {
  bucket = "${var.domain}"
  policy = "${data.aws_iam_policy_document.bucket.json}"
  website = {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket" "redirect" {
  bucket = "${local.www_domain}"
  website = {
    redirect_all_requests_to = "${aws_s3_bucket.main.id}"
  }
}

resource "aws_route53_zone" "zone" {
  name = "${var.domain}"
}

resource "aws_acm_certificate" "cert" {
  domain_name = "${var.domain}"
  subject_alternative_names = ["${local.www_domain}"]
  validation_method = "DNS"
  provider = "aws.us-east-1" # CloudFront requires certificates in this region.
}

resource "aws_route53_record" "cert" {
  count = "${length(local.domains)}"
  name =
    "${lookup(aws_acm_certificate.cert.domain_validation_options[count.index],
              "resource_record_name")}"
  type =
    "${lookup(aws_acm_certificate.cert.domain_validation_options[count.index],
              "resource_record_type")}"
  records = [
    "${lookup(aws_acm_certificate.cert.domain_validation_options[count.index],
     "resource_record_value")}"
  ]
  zone_id = "${aws_route53_zone.zone.id}"
  ttl = 300
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = "${aws_acm_certificate.cert.arn}"
  validation_record_fqdns = ["${aws_route53_record.cert.*.fqdn}"]
  provider = "aws.us-east-1" # CloudFront requires certificates in this region.
  timeouts {
    create = "2h"
  }
}

resource "aws_cloudfront_distribution" "cdn" {
  count = "${length(local.domains)}"
  enabled = true
  http_version = "http2"
  aliases = ["${element(local.domains, count.index)}"]
  is_ipv6_enabled = true

  origin {
    domain_name = "${element(local.endpoints, count.index)}"
    origin_id = "S3-${element(local.domains, count.index)}"

    custom_origin_config {
      origin_protocol_policy = "http-only"
      http_port              = "80"
      https_port             = "443"
      origin_ssl_protocols = ["TLSv1"]
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
    acm_certificate_arn =
      "${aws_acm_certificate_validation.cert.certificate_arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${element(local.domains, count.index)}"
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

resource "aws_route53_record" "A" {
  count = "${length(local.domains)}"
  zone_id = "${aws_route53_zone.zone.zone_id}"
  name = "${element(local.domains, count.index)}"
  type = "A"

  alias {
    name = "${element(aws_cloudfront_distribution.cdn.*.domain_name,
                      count.index)}"
    zone_id = "${element(aws_cloudfront_distribution.cdn.*.hosted_zone_id,
                         count.index)}"
    evaluate_target_health = false
  }
}

resource "aws_iam_user" "deploy" {
  name = "${var.domain}-deploy"
  path = "/"
}

resource "aws_iam_access_key" "deploy" {
  user = "${aws_iam_user.deploy.name}"
}

resource "aws_iam_user_policy" "deploy" {
  name = "deploy"
  user = "${aws_iam_user.deploy.name}"
  policy = "${data.aws_iam_policy_document.deploy.json}"
}
