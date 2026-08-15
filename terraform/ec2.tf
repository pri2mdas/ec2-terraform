module "ec2" {
    source = "git::https://github.com/pri2mdas/module-test.git//aws/ec2?ref=main"

    instance_type = "t3.micro"
}
