output "deploy-id" {
  description = "The AWS Access Key ID for the IAM deployment user."
  value       = "${aws_iam_access_key.deploy.*.id}"
}

output "deploy-secret" {
  description = "The AWS Secret Key for the IAM deployment user."
  value       = "${aws_iam_access_key.deploy.*.secret}"
}

output "bucket-name" {
  description = "The name of the main S3 bucket."
  value       = "${aws_s3_bucket.main.bucket}"
}
