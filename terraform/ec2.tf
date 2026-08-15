module "ec2" {
    source = "git::https://github.com/pri2mdas/module-test.git?ref=aws/ec2"

    instance_type = "c7i-flex.large"
}
