module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  azs                  = var.azs
}

module "security_group" {
  source = "./modules/security_group"

  project_name                = var.project_name
  environment                 = var.environment
  vpc_id                      = module.vpc.vpc_id
  vpc_cidr                    = var.vpc_cidr
  kafka_port                  = var.kafka_port
  allow_internal_kafka_access = var.allow_internal_kafka_access
}

module "secrets_manager" {
  source = "./modules/secrets_manager"

  project_name = var.project_name
  environment  = var.environment
}

module "iam" {
  source = "./modules/iam"

  project_name      = var.project_name
  environment       = var.environment
  phase3_secret_arn = module.secrets_manager.secret_arn
}

module "ec2_kafka" {
  source = "./modules/ec2_kafka"

  project_name             = var.project_name
  environment              = var.environment
  subnet_id                = module.vpc.public_subnet_ids[0]
  security_group_id        = module.security_group.security_group_id
  iam_instance_profile     = module.iam.instance_profile_name
  instance_type            = var.instance_type
  root_volume_size         = var.root_volume_size
  kafka_version            = var.kafka_version
  scala_version            = var.scala_version
  topic_name               = var.kafka_topic_name
  topic_partitions         = var.kafka_topic_partitions
  topic_replication_factor = var.kafka_topic_replication_factor
  kafka_secret_arn         = module.secrets_manager.secret_arn
  kafka_secret_version_id  = module.secrets_manager.secret_version_id
}

locals {
  compliance_scope_tag_value = coalesce(var.compliance_scope_tag_value, "${var.project_name}-${var.environment}")
}

module "config_controls" {
  source = "./modules/config_controls"

  project_name                    = var.project_name
  environment                     = var.environment
  conformance_pack_name           = var.conformance_pack_name
  config_snapshot_frequency_hours = var.config_snapshot_frequency_hours
  scope_tag_key                   = var.compliance_scope_tag_key
  scope_tag_value                 = local.compliance_scope_tag_value
}
