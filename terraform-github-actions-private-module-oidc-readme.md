# Terraform Infrastructure Deployment with Private Modules, GitHub Actions & AWS OIDC

This project demonstrates a Terraform setup where:

-   The **Terraform reusable module** is stored in a **private GitHub
    repository**.
-   The **root Terraform configuration** is stored in a **separate
    private GitHub repository**.
-   GitHub Actions runs from the root/infrastructure repository.
-   Terraform downloads the private child module during
    `terraform init`.
-   GitHub Actions authenticates to AWS using **GitHub OIDC**, so no
    long-lived AWS access keys are stored in GitHub.
-   A Terraform plan is created before applying infrastructure.
-   Pull requests run validation/plan checks.
-   A merge to `main` triggers the deployment/apply flow.

------------------------------------------------------------------------

## 1. Architecture

``` text
                         GitHub Organization
                                |
                 +--------------+--------------+
                 |                             |
                 v                             v
       terraform-modules                 terraform-infra
          PRIVATE repo                    PRIVATE repo
                 |                             |
                 |                             |
                 |                       GitHub Actions
                 |                             |
                 |                    +--------+--------+
                 |                    |                 |
                 |                    v                 v
                 |              Git authentication   AWS OIDC
                 |                    |                 |
                 |                    |                 v
                 |                    |             AWS IAM Role
                 |                    |                 |
                 |                    |                 v
                 |                    |               AWS
                 |                    |
                 +<-------------------+
                         terraform init
```

The root repository consumes the reusable module like this:

``` hcl
module "ec2" {
  source = "git::https://github.com/<OWNER>/module-test.git//aws/ec2?ref=main"

  instance_type = "t3.micro"
}
```

The important syntax is:

``` text
.git//aws/ec2?ref=main
     ^^^^^^^^
     module directory

              ^^^^^^^^
              Git branch/tag
```

-   `//aws/ec2` = directory inside the module repository.
-   `?ref=main` = Git branch/tag/commit reference.

------------------------------------------------------------------------

# 2. Repository Structure

## Private module repository

Example:

``` text
module-test/
└── aws/
    └── ec2/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

The EC2 module defines its input variables.

Example:

``` hcl
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}
```

The module can then use:

``` hcl
resource "aws_instance" "this" {
  instance_type = var.instance_type

  # other configuration...
}
```

## Private infrastructure/root repository

Example:

``` text
terraform-infra/
├── terraform/
│   ├── main.tf
│   ├── ec2.tf
│   ├── variables.tf
│   ├── providers.tf
│   └── backend.tf
│
└── .github/
    └── workflows/
        └── terraform.yml
```

The root module calls the private child module:

``` hcl
module "ec2" {
  source = "git::https://github.com/<OWNER>/module-test.git//aws/ec2?ref=main"

  instance_type = "t3.micro"
}
```

------------------------------------------------------------------------

# 3. Private Module Repository Authentication

Because `module-test` is private, GitHub Actions cannot automatically
clone it just because both repositories belong to the same GitHub
account/organization.

A separate authentication mechanism is required.

For this setup we used a **GitHub fine-grained Personal Access Token
(PAT)**.

## Create the PAT

Go to:

``` text
GitHub
  -> Settings
  -> Developer settings
  -> Personal access tokens
  -> Fine-grained tokens
```

Create a token with:

``` text
Repository access:
    Only select repositories

Repository:
    module-test

Permissions:
    Contents -> Read-only
```

`Metadata -> Read-only` is required automatically.

For a production setup, restrict the token to only the module repository
rather than giving it access to all repositories.

## Store the PAT in the root repository

In the `terraform-infra` repository:

``` text
Settings
  -> Secrets and variables
  -> Actions
  -> New repository secret
```

Create:

``` text
Name:
GH_MODULE_TOKEN

Value:
<your fine-grained PAT>
```

Do not put the PAT directly in:

-   Terraform code
-   workflow YAML
-   `.tfvars`
-   Git
-   README files

------------------------------------------------------------------------

# 4. Configure Git Authentication in GitHub Actions

Before `terraform init`, configure Git to use the PAT when accessing
GitHub over HTTPS.

``` yaml
- name: Configure Git authentication
  run: |
    git config --global url."https://x-access-token:${GH_MODULE_TOKEN}@github.com/".insteadOf "https://github.com/"
  env:
    GH_MODULE_TOKEN: ${{ secrets.GH_MODULE_TOKEN }}
```

`x-access-token` is used as the HTTPS username.

The actual token comes from:

``` yaml
${{ secrets.GH_MODULE_TOKEN }}
```

The workflow does not contain the actual secret value.

After this configuration, when Terraform executes:

``` bash
terraform init
```

and encounters:

``` hcl
source = "git::https://github.com/<OWNER>/module-test.git//aws/ec2?ref=main"
```

Git can authenticate and clone the private repository.

------------------------------------------------------------------------

# 5. AWS Authentication with GitHub OIDC

The second authentication problem is completely separate.

The module PAT authenticates:

``` text
GitHub Actions -> Private GitHub module repository
```

AWS OIDC authenticates:

``` text
GitHub Actions -> AWS IAM Role -> AWS resources
```

We use OIDC so that we do not need to store:

``` text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

in GitHub.

------------------------------------------------------------------------

# 6. Create the GitHub OIDC Provider in AWS

In AWS IAM, create/configure the GitHub OIDC identity provider.

Provider URL:

``` text
https://token.actions.githubusercontent.com
```

Audience:

``` text
sts.amazonaws.com
```

The AWS account used by the workflow must have an IAM role that trusts
this OIDC provider.

------------------------------------------------------------------------

# 7. IAM Role Trust Policy

The GitHub Actions job requests an OIDC token.

AWS checks the token against the IAM role trust policy.

A simplified trust relationship looks like:

``` json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

Replace:

``` text
<AWS_ACCOUNT_ID>
<OWNER>
<REPO>
```

with your actual values.

## Important

The `sub` value must match the subject claim GitHub sends for your
repository/workflow context.

For a deployment restricted to the `main` branch, the traditional branch
form is:

``` text
repo:<OWNER>/<REPO>:ref:refs/heads/main
```

GitHub also supports newer repository identity/immutable-subject
formats. If your GitHub repository uses that format, use the exact `sub`
claim presented by GitHub rather than assuming the traditional form.

The key point is:

> The AWS trust policy must match the actual GitHub OIDC `sub` claim.

------------------------------------------------------------------------

# 8. IAM Role Permissions

The trust policy answers:

> Who is allowed to assume this role?

The IAM permissions policy answers:

> What can the assumed role do in AWS?

For example, the role used by Terraform might have permissions required
to manage:

-   EC2
-   VPC
-   Security Groups
-   IAM resources where appropriate
-   Other resources defined by the Terraform configuration

Use least privilege rather than giving the role unrestricted
administrator permissions.

------------------------------------------------------------------------

# 9. GitHub Actions OIDC Permissions

The workflow needs:

``` yaml
permissions:
  id-token: write
  contents: read
```

### `contents: read`

Allows the workflow to read the repository.

For example:

``` yaml
- uses: actions/checkout@v4
```

### `id-token: write`

Allows the workflow to request a GitHub OIDC identity token.

This does NOT give the workflow AWS permissions by itself.

The flow is:

``` text
id-token: write
       |
       v
GitHub OIDC token
       |
       v
AWS IAM trust policy
       |
       v
AssumeRoleWithWebIdentity
       |
       v
AWS IAM role permissions
```

------------------------------------------------------------------------

# 10. GitHub Actions Workflow

The workflow used for the infrastructure repository is:

``` yaml
name: Terraform Deploy

on:
  push:
    branches:
      - main
    paths:
      - 'terraform/**'

  pull_request:
    branches:
      - main

permissions:
  id-token: write
  contents: read

jobs:
  terraform-infra-build:
    runs-on: ubuntu-latest

    steps:

      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: aws-actions/configure-aws-credentials@v6
        with:
          aws-region: ap-south-1
          role-to-assume: ${{ secrets.AWS_IAM_ROLE }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: 1.5.0

      - name: Configure Git authentication
        run: |
          git config --global url."https://x-access-token:${GH_MODULE_TOKEN}@github.com/".insteadOf "https://github.com/"
        env:
          GH_MODULE_TOKEN: ${{ secrets.GH_MODULE_TOKEN }}

      - name: Terraform Init
        run: terraform init
        working-directory: ./terraform

      - name: Terraform Format Check
        run: terraform fmt -check
        working-directory: ./terraform

      - name: Terraform Validate
        run: terraform validate
        working-directory: ./terraform

      - name: Terraform Plan
        run: terraform plan -out=tfplan
        working-directory: ./terraform

      - name: Terraform Apply
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: terraform apply -auto-approve tfplan
        working-directory: ./terraform
```

------------------------------------------------------------------------

# 11. Workflow Explanation

## Step 1: Checkout

``` yaml
- uses: actions/checkout@v4
```

Checks out the **terraform-infra repository** onto the GitHub Actions
runner.

It does not automatically give access to the separate private
`module-test` repository.

------------------------------------------------------------------------

## Step 2: AWS OIDC

``` yaml
- name: Configure AWS Credentials
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  uses: aws-actions/configure-aws-credentials@v6
  with:
    aws-region: ap-south-1
    role-to-assume: ${{ secrets.AWS_IAM_ROLE }}
```

On a push to `main`, GitHub Actions requests an OIDC token and uses it
to assume the AWS IAM role.

The role ARN is stored as:

``` text
AWS_IAM_ROLE
```

in GitHub Actions secrets.

------------------------------------------------------------------------

## Step 3: Install Terraform

``` yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v2
  with:
    terraform_version: 1.5.0
```

Installs Terraform 1.5.0 on the runner.

------------------------------------------------------------------------

## Step 4: Authenticate to the Private Module Repository

``` yaml
- name: Configure Git authentication
  run: |
    git config --global url."https://x-access-token:${GH_MODULE_TOKEN}@github.com/".insteadOf "https://github.com/"
  env:
    GH_MODULE_TOKEN: ${{ secrets.GH_MODULE_TOKEN }}
```

This is required because Terraform uses Git to download the private
module.

------------------------------------------------------------------------

# 12. Terraform Init

``` yaml
- name: Terraform Init
  run: terraform init
  working-directory: ./terraform
```

Terraform:

1.  Initializes the backend.
2.  Reads the root module.
3.  Finds the module source.
4.  Uses Git authentication.
5.  Downloads the private module.
6.  Places the downloaded module under the Terraform working directory's
    `.terraform/modules` directory.

Example:

``` text
terraform-infra/
└── terraform/
    ├── main.tf
    ├── ec2.tf
    └── .terraform/
        └── modules/
            └── ec2/
```

The downloaded module is not committed back to GitHub.

------------------------------------------------------------------------

# 13. Terraform Format

``` yaml
terraform fmt -check
```

Checks whether Terraform code follows Terraform's formatting rules.

Using:

``` bash
terraform fmt -check
```

is preferable in CI because it detects formatting problems without
modifying the repository.

------------------------------------------------------------------------

# 14. Terraform Validate

``` yaml
terraform validate
```

Checks whether the Terraform configuration is syntactically valid and
internally consistent.

------------------------------------------------------------------------

# 15. Terraform Plan

``` yaml
terraform plan -out=tfplan
```

Creates an execution plan and saves it as:

``` text
tfplan
```

The file is created in the GitHub Actions runner's current Terraform
working directory:

``` text
./terraform/tfplan
```

It is **not automatically committed to the GitHub repository**.

For separate plan/apply jobs, pass the plan using an artifact rather
than relying on runner workspace persistence.

------------------------------------------------------------------------

# 16. Terraform Apply

``` yaml
- name: Terraform Apply
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  run: terraform apply -auto-approve tfplan
  working-directory: ./terraform
```

Apply only happens when:

``` text
event = push
branch = main
```

Therefore a normal pull request does not automatically apply
infrastructure.

------------------------------------------------------------------------

# 17. Pull Request vs Main Deployment

The workflow has two important paths.

## Pull Request

``` text
Developer
    |
    v
Pull Request -> main
    |
    v
GitHub Actions
    |
    +-- checkout
    +-- Terraform init
    +-- Terraform fmt
    +-- Terraform validate
    +-- Terraform plan
    |
    X
  No Apply
```

This allows Terraform changes to be validated before merging.

## Merge to Main

``` text
Pull Request
    |
    v
Manager approval
    |
    v
Merge to main
    |
    v
push event
    |
    +-- Terraform init
    +-- Terraform fmt
    +-- Terraform validate
    +-- Terraform plan
    +-- Terraform apply
    |
    v
AWS
```

------------------------------------------------------------------------

# 18. Required GitHub Secrets

The `terraform-infra` repository should contain at least:

  -----------------------------------------------------------------------
  Secret                              Purpose
  ----------------------------------- -----------------------------------
  `GH_MODULE_TOKEN`                   Fine-grained PAT used to read the
                                      private Terraform module repository

  `AWS_IAM_ROLE`                      ARN of the AWS IAM role assumed
                                      through GitHub OIDC
  -----------------------------------------------------------------------

Example:

``` text
GH_MODULE_TOKEN = github_pat_...
AWS_IAM_ROLE    = arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>
```

Never commit these values to the repository.

------------------------------------------------------------------------

# 19. Two Different Authentication Mechanisms

This setup has two separate authentication flows.

## GitHub private repository

``` text
GitHub Actions
      |
      | GH_MODULE_TOKEN
      v
Private terraform-modules repo
```

Purpose:

> Allow Terraform/Git to download the private module.

## AWS

``` text
GitHub Actions
      |
      | OIDC token
      v
AWS IAM
      |
      | AssumeRoleWithWebIdentity
      v
Terraform IAM Role
      |
      v
AWS resources
```

Purpose:

> Allow Terraform to authenticate to AWS without storing long-lived AWS
> access keys.

These should not be confused with each other.

------------------------------------------------------------------------

# 20. Common Problems Encountered

## Problem 1: Wrong module source

Incorrect:

``` hcl
source = "git::https://github.com/<OWNER>/module-test.git?ref=aws/ec2"
```

This means `aws/ec2` is being treated as the Git ref.

Correct:

``` hcl
source = "git::https://github.com/<OWNER>/module-test.git//aws/ec2?ref=main"
```

Here:

``` text
//aws/ec2 = module directory
?ref=main = Git branch
```

------------------------------------------------------------------------

## Problem 2: Private module authentication

Error:

``` text
fatal: could not read Username for 'https://github.com'
```

Solution:

Configure Git authentication before:

``` bash
terraform init
```

using:

``` yaml
GH_MODULE_TOKEN: ${{ secrets.GH_MODULE_TOKEN }}
```

------------------------------------------------------------------------

## Problem 3: PAT does not have repository access

Error:

``` text
remote: Write access to repository not granted.
403
```

Check the fine-grained PAT:

``` text
Repository access:
    module-test

Contents:
    Read-only
```

The PAT does not need write access just to clone/read the Terraform
module.

------------------------------------------------------------------------

## Problem 4: AWS OIDC not authorized

Error:

``` text
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

Check:

1.  `permissions.id-token` is `write`.
2.  GitHub OIDC provider exists in AWS.
3.  Provider URL is:

``` text
https://token.actions.githubusercontent.com
```

4.  Audience is:

``` text
sts.amazonaws.com
```

5.  The IAM role trust policy matches the actual GitHub OIDC `sub`
    claim.
6.  The repository/branch restriction is correct.
7.  `AWS_IAM_ROLE` contains the correct IAM role ARN.

------------------------------------------------------------------------

# 21. Security Recommendations

### Use least privilege

For the module PAT:

``` text
Only module repository
Contents -> Read-only
```

For AWS:

``` text
Only required AWS permissions
```

Do not automatically use:

``` text
AdministratorAccess
```

unless there is a specific reason.

### Do not store AWS access keys

Prefer:

``` text
GitHub OIDC -> AWS IAM Role
```

instead of:

``` text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

### Protect the main branch

Use branch protection/rulesets so production changes require review
before being merged to `main`.

### Do not commit Terraform plan files

Add:

``` gitignore
.terraform/
*.tfstate
*.tfstate.*
tfplan
```

to `.gitignore`.

Terraform state should be stored in the configured remote backend rather
than committed to Git.

------------------------------------------------------------------------

# 22. Final End-to-End Flow

``` text
Developer
    |
    | commit / PR
    v
terraform-infra (PRIVATE)
    |
    v
GitHub Actions
    |
    +-----------------------------+
    |                             |
    v                             v
Git authentication              AWS OIDC
    |                             |
    | GH_MODULE_TOKEN             | id-token
    v                             v
module-test (PRIVATE)           AWS IAM Role
    |                             |
    | aws/ec2                     |
    +-------------+               |
                  |               |
                  v               v
             terraform init    AWS access
                  |
                  v
             Terraform Plan
                  |
                  v
             PR validation
                  |
                  v
             Manager approval
                  |
                  v
               Merge main
                  |
                  v
            Terraform Apply
                  |
                  v
             AWS resources
```

## Summary

The key pieces of this implementation are:

1.  **Private Terraform module repository**
2.  **Private Terraform root/infrastructure repository**
3.  **Fine-grained PAT** for reading the private module
4.  `GH_MODULE_TOKEN` stored as a GitHub Actions secret
5.  Git authentication configured before `terraform init`
6.  **AWS OIDC provider**
7.  AWS IAM role with a restricted GitHub trust policy
8.  `id-token: write` and `contents: read`
9.  Terraform validation and plan on pull requests
10. Terraform apply only after changes reach `main`
11. Terraform module referenced using:

``` hcl
git::https://github.com/<OWNER>/<MODULE_REPO>.git//<MODULE_PATH>?ref=<VERSION_OR_BRANCH>
```

This gives a clean separation between **reusable Terraform modules**,
**infrastructure/root configuration**, **GitHub authentication**, and
**AWS authentication**.
