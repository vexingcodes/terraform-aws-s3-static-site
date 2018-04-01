# terraform-aws-s3-static-site
Creates a static website on a domain hosted on S3 and delivered by CloudFront over HTTPS with Route53 managing DNS.

## Features
* Redirects the following to `https://domain.name`
  * `http://domain.name`
  * `http://www.domain.name`
  * `https://www.domain.name`
* The raw S3 buckets are not publicly accessible.
* A single certificate is issued by the Amazon Certificate Manager for both `domain.name` and `www.domain.name`.
* An IAM user named like `domain.name-deploy` is created that is given deployment access to the S3 bucket containing the site data.

## Inputs
This module is not particularly configurable. You can only select the domain name to be used, and  secret key that is shared between CloudFront and S3 to authorize access.

## Outputs
The only output is an AWS access key/secret that can be used to deploy to the site's S3 bucket.

## Details
Two S3 buckets are created, one for `domain.name` which will hold all of the site data and the other for `www.domain.name` which is simply a bucket set up to redirect to the first bucket.

A Route 53 hosted zone is created for `domain.name`, and a certificate is issued for `domain.name` and `www.domain.name` by automatically adding the appropriate `CNAME` records to the hosted zone. Then the module waits for the certificate to actually be issued. See the notes section for troubleshooting.

Two CloudFront distributions are created, one for `domain.name` and one for `www.domain.name`. Each of them simply points at the respective S3 bucket and uses the certificate created in the previous step.

Once the CloudFront distributions are available, then the `A` records are created in Route 53 for `domain.name` and `www.domain.name`. The `A` records are simply `ALIAS` records to the respective CloudFront distributions.

Finally, an IAM user is created, an access key is given to this user, and a policy is attached to the user that only allows the user to modify the `domain.name` S3 bucket.

## Notes
The certificate is created automatically by adding DNS entries to the Route 53 hosted zone. The script will wait up to two hours for the certificate to be issued. If your domain is not owned by Route 53, you may need to go to the Route 53 hosted zone, look at the NS record, and assign your domain those nameservers. If the script times out because this was not done rerunning `terraform apply` after making sure the nameservers are correct should allow the module to continue.
