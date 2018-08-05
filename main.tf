# Templates can only handle strings, so convert to a string and join
data "template_file" "www_first" {
    count    = "${var.www_is_main}"
    template = "${format("%s,%s", local.www_domains, join(",", var.domains))}"
}

data "template_file" "root_first" {
    count    = "${1 - var.www_is_main}"
    template = "${format("%s,%s", join(",", var.domains), local.www_domains)}"
}

# This policy is applied to the main S3 bucket.  It allows CloudFront access to
# the bucket through the use of the user-agent field through which S3 and
# CloudFront share a secret. This kind of policy is not necessary for the
# redirect bucket since it doesn't store any objects, it just redirects.
data "template_file" "bucket_policy" {
    template = "${file("${path.module}/policies/bucket-policy.json")}"

    vars {
      bucket_name = "${local.primary_domain}"
      secret      = "${var.secret}"
    }
}

# This policy is applied to the IAM user that handles deployments for the
# static site. It basically allows full access to the main S3 bucket, and
# allows the user to create CloudFront invalidations when the site is updated
# so that the new content is rolled out quickly.
data "template_file" "deploy_policy" {
    template = "${file("${path.module}/policies/deploy-policy.json")}"

    vars {
      bucket_arn = "${aws_s3_bucket.main.arn}"
    }
}

data "aws_route53_zone" "zone" {
    count = "${length(local.zone_domain_name)}"
    name  = "${format("%s.", local.zone_domain_name[count.index])}"
}

locals {
    all_domains      = "${split(",", join(",", concat(data.template_file.www_first.*.rendered, 
                                                      data.template_file.root_first.*.rendered)))}"
    primary_domain   = "${local.all_domains[0]}"
    www_domains      = "${join(",", formatlist("www.%s", var.domains))}"
    redirect_domains = "${slice(local.all_domains, 1, length(local.all_domains))}"

    # Ugly but we need a valid zone name for each domain to feed into the zone data source (i.e. without the "www" part).
    # A map would have been better but we'll have to do with a list parallel to local.all_domains
    zone_domain_name = "${split(",", replace(join(",", local.all_domains), "/(?i)www\\./", ""))}"

    # Ditto here.  The order shouldn't change.
    endpoints = ["${split(",", format("%s,%s", aws_s3_bucket.main.website_endpoint, 
                                               join(",", aws_s3_bucket.redirect.*.website_endpoint)))}"]
}

resource "aws_s3_bucket" "main" {
    bucket = "${local.primary_domain}"
    policy = "${data.template_file.bucket_policy.rendered}"

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
    aliases         = ["${local.all_domains[count.index]}"]
    comment         = "CloudFront CDN for ${local.all_domains[count.index]}"
    enabled         = true
    is_ipv6_enabled = true
    price_class     = "${lookup(var.cdn_settings, "price_class", "PriceClass_All")}"

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
        restriction_type = "${lookup(var.cdn_settings, "restriction_type", "none")}"
        locations        = ["${var.countries}"]
      }
    }

    viewer_certificate {
      acm_certificate_arn      = "${aws_acm_certificate_validation.cert.certificate_arn}"
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "${lookup(var.cdn_settings, "minimum_protocol_version", "TLSv1_2016")}"
    }

    default_cache_behavior {
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      target_origin_id       = "${format("S3-%s", local.all_domains[count.index])}"
      compress               = "true"
      viewer_protocol_policy = "redirect-to-https"
      min_ttl                = "${lookup(var.cdn_settings, "min_ttl", "0")}"
      default_ttl            = "${lookup(var.cdn_settings, "default_ttl", "86400")}"
      max_ttl                = "${lookup(var.cdn_settings, "max_ttl", "31536000")}"

      forwarded_values {
        query_string = false

        cookies {
          forward = "none"
        }
      }
    }
}

resource "aws_route53_record" "A" {
    count   = "${length(local.all_domains)}"
    zone_id = "${element(data.aws_route53_zone.zone.*.zone_id, count.index)}"
    name    = "${local.all_domains[count.index]}"
    type    = "A"

    alias {
      name                   = "${element(aws_cloudfront_distribution.cdn.*.domain_name, count.index)}"
      zone_id                = "${element(aws_cloudfront_distribution.cdn.*.hosted_zone_id, count.index)}"
      evaluate_target_health = false
  }
}

resource "aws_route53_record" "AAAA" {
    count   = "${length(local.all_domains)}"
    zone_id = "${element(data.aws_route53_zone.zone.*.zone_id, count.index)}"
    name    = "${local.all_domains[count.index]}"
    type    = "AAAA"

    alias {
      name                   = "${element(aws_cloudfront_distribution.cdn.*.domain_name, count.index)}"
      zone_id                = "${element(aws_cloudfront_distribution.cdn.*.hosted_zone_id, count.index)}"
      evaluate_target_health = false
  }
}

resource "aws_iam_user" "deploy" {
    count = "${var.enable_iam_user ? 1 : 0}"
    name  = "${local.primary_domain}-deploy"
    path  = "/"
}

resource "aws_iam_access_key" "deploy" {
    count = "${var.enable_iam_user ? 1 : 0}"
    user  = "${aws_iam_user.deploy.name}"
}

resource "aws_iam_user_policy" "deploy" {
    count  = "${var.enable_iam_user ? 1 : 0}"
    name   = "deploy"
    user   = "${aws_iam_user.deploy.name}"
    policy = "${data.template_file.deploy_policy.rendered}"
}
