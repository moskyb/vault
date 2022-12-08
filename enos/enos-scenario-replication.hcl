scenario "replication" {
  matrix {
    arch              = ["amd64", "arm64"]
    distro            = ["ubuntu", "rhel"]
    primary_backend   = ["raft", "consul"]
    secondary_backend = ["raft", "consul"]
    consul_version    = ["1.13.2", "1.12.5", "1.11.10"]
    edition           = ["ent"]
    primary_seal      = ["awskms", "shamir"]
    secondary_seal    = ["awskms", "shamir"]
  }

  terraform_cli = terraform_cli.default
  terraform     = terraform.default
  providers = [
    provider.aws.default,
    provider.enos.ubuntu,
    provider.enos.rhel
  ]

  locals {
    artifact_path           = var.artifact_path
    dependencies_to_install = ["jq"]
    enos_provider = {
      rhel   = provider.enos.rhel
      ubuntu = provider.enos.ubuntu
    }
    install_artifactory_artifact = true
    tags = merge({
      "Project Name" : var.project_name
      "Project" : "Enos",
      "Environment" : "ci"
    }, var.tags)
    vault_instance_types = {
      amd64 = "t3a.small"
      arm64 = "t4g.small"
    }
    vault_instance_type = coalesce(var.vault_instance_type, local.vault_instance_types[matrix.arch])
  }

  step "find_azs" {
    module = module.az_finder
    variables {
      instance_type = [
        local.vault_instance_type
      ]
    }
  }

  step "create_vpc" {
    module     = module.create_vpc
    depends_on = [step.find_azs]

    variables {
      ami_architectures  = [matrix.arch]
      availability_zones = step.find_azs.availability_zones
      common_tags        = local.tags
    }
  }

  step "read_license" {
    module = module.read_license

    variables {
      file_name = abspath(joinpath(path.root, "./support/vault.hclic"))
    }
  }

  step "fetch_vault_artifact" {
    module = module.build_artifactory

    variables {
      artifactory_host      = var.artifactory_host
      artifactory_repo      = var.artifactory_repo
      artifactory_username  = var.artifactory_username
      artifactory_token     = var.artifactory_token
      arch                  = matrix.arch
      vault_product_version = var.vault_product_version
      artifact_type         = "bundle"
      distro                = matrix.distro
      edition               = matrix.edition
      instance_type         = local.vault_instance_type
      revision              = var.vault_revision
    }
  }

  step "create_primary_backend_cluster" {
    module     = "backend_${matrix.primary_backend}"
    depends_on = [step.create_vpc]

    providers = {
      enos = provider.enos.ubuntu
    }

    variables {
      ami_id      = step.create_vpc.ami_ids["ubuntu"][matrix.arch]
      common_tags = local.tags
      consul_release = {
        edition = var.backend_edition
        version = matrix.consul_version
      }
      instance_type = var.backend_instance_type
      kms_key_arn   = step.create_vpc.kms_key_arn
      vpc_id        = step.create_vpc.vpc_id
    }
  }

  step "create_vault_primary_cluster" {
    module = module.vault_cluster
    depends_on = [
      step.create_primary_backend_cluster,
      step.fetch_vault_artifact,
    ]
    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      ami_id                    = step.create_vpc.ami_ids[matrix.distro][matrix.arch]
      common_tags               = local.tags
      consul_cluster_tag        = step.create_primary_backend_cluster.consul_cluster_tag
      dependencies_to_install   = local.dependencies_to_install
      instance_type             = local.vault_instance_type
      kms_key_arn               = step.create_vpc.kms_key_arn
      storage_backend           = matrix.primary_backend
      unseal_method             = matrix.primary_seal
      vault_artifactory_release = local.install_artifactory_artifact ? step.fetch_vault_artifact.vault_artifactory_release : null
      vault_environment = {
        VAULT_LOG_LEVEL = "debug"
      }
      vault_license = step.read_license.license
      vpc_id        = step.create_vpc.vpc_id
    }
  }

  step "create_secondary_backend_cluster" {
    module     = "backend_${matrix.secondary_backend}"
    depends_on = [step.create_vpc]

    providers = {
      enos = provider.enos.ubuntu
    }

    variables {
      ami_id      = step.create_vpc.ami_ids["ubuntu"][matrix.arch]
      common_tags = local.tags
      consul_release = {
        edition = var.backend_edition
        version = matrix.consul_version
      }
      instance_type = var.backend_instance_type
      kms_key_arn   = step.create_vpc.kms_key_arn
      vpc_id        = step.create_vpc.vpc_id
    }
  }

  step "create_vault_secondary_cluster" {
    module = module.vault_cluster
    depends_on = [
      step.create_secondary_backend_cluster,
      step.fetch_vault_artifact,
    ]
    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      ami_id                    = step.create_vpc.ami_ids[matrix.distro][matrix.arch]
      common_tags               = local.tags
      consul_cluster_tag        = step.create_secondary_backend_cluster.consul_cluster_tag
      dependencies_to_install   = local.dependencies_to_install
      instance_type             = local.vault_instance_type
      kms_key_arn               = step.create_vpc.kms_key_arn
      storage_backend           = matrix.secondary_backend
      unseal_method             = matrix.secondary_seal
      vault_artifactory_release = local.install_artifactory_artifact ? step.fetch_vault_artifact.vault_artifactory_release : null
      vault_environment = {
        VAULT_LOG_LEVEL = "debug"
      }
      vault_license = step.read_license.license
      vpc_id        = step.create_vpc.vpc_id
    }
  }

  step "verify_vault_primary_unsealed" {
    module = module.vault_verify_unsealed
    depends_on = [
      step.create_vault_primary_cluster
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances = step.create_vault_primary_cluster.vault_instances
    }
  }

  step "verify_vault_secondary_unsealed" {
    module = module.vault_verify_unsealed
    depends_on = [
      step.create_vault_secondary_cluster
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances = step.create_vault_secondary_cluster.vault_instances
      // vault_root_token = step.create_vault_secondary_cluster.vault_root_token
    }
  }

  step "get_primary_cluster_ips" {
    module     = module.vault_cluster_ips
    depends_on = [step.verify_vault_primary_unsealed]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances  = step.create_vault_primary_cluster.vault_instances
      vault_root_token = step.create_vault_primary_cluster.vault_root_token
    }
  }

  step "get_secondary_cluster_ips" {
    module     = module.vault_cluster_ips
    depends_on = [step.verify_vault_secondary_unsealed]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances  = step.create_vault_secondary_cluster.vault_instances
      vault_root_token = step.create_vault_secondary_cluster.vault_root_token
    }
  }

  step "verify_vault_primary_write_data" {
    module     = module.vault_verify_write_data
    depends_on = [step.get_primary_cluster_ips]


    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      primary_leader_public_ip  = step.get_primary_cluster_ips.leader_public_ip
      primary_leader_private_ip = step.get_primary_cluster_ips.leader_private_ip
      vault_instances           = step.create_vault_primary_cluster.vault_instances
      vault_root_token          = step.create_vault_primary_cluster.vault_root_token
    }
  }

  step "configure_performance_replication_primary" {
    module     = module.vault_performance_replication_primary
    depends_on = [step.get_primary_cluster_ips]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      primary_leader_public_ip  = step.get_primary_cluster_ips.leader_public_ip
      primary_leader_private_ip = step.get_primary_cluster_ips.leader_private_ip
      vault_root_token          = step.create_vault_primary_cluster.vault_root_token
    }
  }

  step "generate_secondary_token" {
    module     = module.generate_secondary_token
    depends_on = [step.configure_performance_replication_primary]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      primary_leader_public_ip = step.get_primary_cluster_ips.leader_public_ip
      vault_root_token         = step.create_vault_primary_cluster.vault_root_token
    }
  }

  step "configure_performance_replication_secondary" {
    module     = module.vault_performance_replication_secondary
    depends_on = [step.generate_secondary_token]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      secondary_leader_public_ip  = step.get_secondary_cluster_ips.leader_public_ip
      secondary_leader_private_ip = step.get_secondary_cluster_ips.leader_private_ip
      vault_root_token            = step.create_vault_secondary_cluster.vault_root_token
      wrapping_token              = step.generate_secondary_token.secondary_token
    }
  }

  step "unseal_secondary_followers" {
    // skip_step  = matrix.primary_seal != "shamir"
    module = module.vault_unseal_nodes
    depends_on = [
      step.create_vault_primary_cluster,
      step.create_vault_secondary_cluster,
      step.get_secondary_cluster_ips,
      step.configure_performance_replication_secondary
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      follower_public_ips = step.get_secondary_cluster_ips.follower_public_ips
      vault_unseal_keys   = matrix.primary_seal == "shamir" ? step.create_vault_primary_cluster.vault_unseal_keys_hex : null
      vault_seal_type     = matrix.primary_seal
    }
  }

  step "verify_vault_secondary_unsealed_after_replication" {
    module = module.vault_verify_unsealed
    depends_on = [
      step.unseal_secondary_followers
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances = step.create_vault_secondary_cluster.vault_instances
    }
  }

  step "verify_performance_replication" {
    module     = module.vault_verify_performance_replication
    depends_on = [step.verify_vault_secondary_unsealed_after_replication]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      primary_leader_public_ip    = step.get_primary_cluster_ips.leader_public_ip
      primary_leader_private_ip   = step.get_primary_cluster_ips.leader_private_ip
      secondary_leader_public_ip  = step.get_secondary_cluster_ips.leader_public_ip
      secondary_leader_private_ip = step.get_secondary_cluster_ips.leader_private_ip
    }
  }

  step "verify_replicated_data" {
    module     = module.vault_verify_replicated_data
    depends_on = [step.verify_performance_replication]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      secondary_leader_public_ip  = step.get_secondary_cluster_ips.leader_public_ip
      secondary_leader_private_ip = step.get_secondary_cluster_ips.leader_private_ip
    }
  }

  step "add_primary_cluster_nodes" {
    module = module.vault_cluster
    depends_on = [
      step.create_vpc,
      step.create_primary_backend_cluster,
      step.create_vault_primary_cluster,
      step.verify_replicated_data
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      ami_id                  = step.create_vpc.ami_ids[matrix.distro][matrix.arch]
      common_tags             = local.tags
      consul_cluster_tag      = step.create_primary_backend_cluster.consul_cluster_tag
      dependencies_to_install = local.dependencies_to_install
      // instance_count            = 2
      instance_type             = local.vault_instance_type
      kms_key_arn               = step.create_vpc.kms_key_arn
      storage_backend           = matrix.primary_backend
      unseal_method             = matrix.primary_seal
      vault_cluster_tag         = step.create_vault_primary_cluster.vault_cluster_tag
      vault_init                = false
      vault_license             = step.read_license.license
      vault_artifactory_release = local.install_artifactory_artifact ? step.fetch_vault_artifact.vault_artifactory_release : null
      vault_environment = {
        VAULT_LOG_LEVEL = "debug"
      }
      vault_node_prefix         = "newprimary_node"
      vault_root_token          = step.create_vault_primary_cluster.vault_root_token
      vault_unseal_when_no_init = true
      vault_unseal_keys         = matrix.primary_seal == "shamir" ? step.create_vault_primary_cluster.vault_unseal_keys_hex : null
      vpc_id                    = step.create_vpc.vpc_id
    }
  }

  step "verify_add_node_unsealed" {
    module     = module.vault_verify_unsealed
    depends_on = [step.add_primary_cluster_nodes]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances = step.add_primary_cluster_nodes.vault_instances
    }
  }

  step "verify_raft_auto_join_voter" {
    skip_step = matrix.primary_backend != "raft"
    module    = module.vault_verify_raft_auto_join_voter
    depends_on = [
      step.add_primary_cluster_nodes,
      step.create_vault_primary_cluster,
      step.verify_add_node_unsealed
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances  = step.add_primary_cluster_nodes.vault_instances
      vault_root_token = step.create_vault_primary_cluster.vault_root_token
    }
  }

  step "remove_primary_follower_1" {
    module = module.remove_node
    depends_on = [
      step.get_primary_cluster_ips,
      step.verify_add_node_unsealed
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      node_public_ip = step.get_primary_cluster_ips.follower_public_ip_1
    }
  }

  step "remove_primary_leader" {
    module = module.remove_node
    depends_on = [
      step.get_primary_cluster_ips,
      step.remove_primary_follower_1
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      node_public_ip = step.get_primary_cluster_ips.leader_public_ip
    }
  }

  step "get_updated_primary_cluster_ips" {
    module = module.vault_cluster_ips
    depends_on = [
      step.add_primary_cluster_nodes,
      step.remove_primary_follower_1,
      step.remove_primary_leader
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances       = step.create_vault_primary_cluster.vault_instances
      added_vault_instances = step.add_primary_cluster_nodes.vault_instances
      vault_root_token      = step.create_vault_primary_cluster.vault_root_token
      node_public_ip        = step.get_primary_cluster_ips.follower_public_ip_2
    }
  }

  step "verify_updated_performance_replication" {
    module     = module.vault_verify_performance_replication
    depends_on = [step.get_updated_primary_cluster_ips]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      primary_leader_public_ip    = step.get_updated_primary_cluster_ips.leader_public_ip
      primary_leader_private_ip   = step.get_updated_primary_cluster_ips.leader_private_ip
      secondary_leader_public_ip  = step.get_secondary_cluster_ips.leader_public_ip
      secondary_leader_private_ip = step.get_secondary_cluster_ips.leader_private_ip
    }
  }

  output "vault_primary_cluster_instance_ids" {
    description = "The Vault primary cluster instance IDs"
    value       = step.create_vault_primary_cluster.instance_ids
  }

  output "vault_primary_cluster_pub_ips" {
    description = "The Vault primary cluster public IPs"
    value       = step.create_vault_primary_cluster.instance_public_ips
  }

  output "vault_primary_cluster_priv_ips" {
    description = "The Vault primary cluster private IPs"
    value       = step.create_vault_primary_cluster.instance_private_ips
  }

  output "vault_primary_newnode_pub_ip" {
    description = "The Vault added new node on primary cluster public IP"
    value       = step.add_primary_cluster_nodes.instance_public_ips
  }

  output "vault_primary_newnode_priv_ip" {
    description = "The Vault added new node on primary cluster private IP"
    value       = step.add_primary_cluster_nodes.instance_private_ips
  }

  output "vault_primary_cluster_key_id" {
    description = "The Vault primary cluster Key ID"
    value       = step.create_vault_primary_cluster.key_id
  }

  output "vault_primary_cluster_root_token" {
    description = "The Vault primary cluster root token"
    value       = step.create_vault_primary_cluster.vault_root_token
  }

  output "vault_primary_cluster_unseal_keys_b64" {
    description = "The Vault primary cluster unseal keys"
    value       = step.create_vault_primary_cluster.vault_unseal_keys_b64
  }

  output "vault_primary_cluster_unseal_keys_hex" {
    description = "The Vault primary cluster unseal keys hex"
    value       = step.create_vault_primary_cluster.vault_unseal_keys_hex
  }

  output "vault_primary_cluster_tag" {
    description = "The Vault primary cluster tag"
    value       = step.create_vault_primary_cluster.vault_cluster_tag
  }

  output "vault_secondary_cluster_instance_ids" {
    description = "The Vault secondary cluster instance IDs"
    value       = step.create_vault_secondary_cluster.instance_ids
  }

  output "vault_secondary_cluster_pub_ips" {
    description = "The Vault secondary cluster public IPs"
    value       = step.create_vault_secondary_cluster.instance_public_ips
  }

  output "vault_secondary_cluster_priv_ips" {
    description = "The Vault secondary cluster private IPs"
    value       = step.create_vault_secondary_cluster.instance_private_ips
  }

  output "vault_secondary_cluster_tag" {
    description = "The Vault secondary cluster tag"
    value       = step.create_vault_secondary_cluster.vault_cluster_tag
  }

  output "vault_secondary_cluster_key_id" {
    description = "The Vault secondary cluster Key ID"
    value       = step.create_vault_secondary_cluster.key_id
  }

  output "vault_secondary_cluster_root_token" {
    description = "The Vault secondary cluster root token"
    value       = step.create_vault_secondary_cluster.vault_root_token
  }

  output "vault_secondary_cluster_unseal_keys_b64" {
    description = "The Vault secondary cluster unseal keys"
    value       = step.create_vault_secondary_cluster.vault_unseal_keys_b64
  }

  output "vault_secondary_cluster_unseal_keys_hex" {
    description = "The Vault secondary cluster unseal keys hex"
    value       = step.create_vault_secondary_cluster.vault_unseal_keys_hex
  }

  output "vault_primary_performance_replication_status" {
    description = "The Vault primary cluster performance replication status"
    value       = step.verify_performance_replication.primary_replication_status
  }

  output "vault_replication_known_primary_cluster_addrs" {
    description = "The Vault secondary cluster performance replication status"
    value       = step.verify_performance_replication.known_primary_cluster_addrs
  }

  output "vault_secondary_performance_replication_status" {
    description = "The Vault secondary cluster performance replication status"
    value       = step.verify_performance_replication.secondary_replication_status
  }

  output "vault_primary_updated_performance_replication_status" {
    description = "The Vault updated primary cluster performance replication status"
    value       = step.verify_updated_performance_replication.primary_replication_status
  }

  output "verify_secondary_updated_performance_replication_status" {
    description = "The Vault updated secondary cluster performance replication status"
    value       = step.verify_updated_performance_replication.secondary_replication_status
  }
}
