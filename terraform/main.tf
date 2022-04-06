terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "swarm-node-count" {
  type      = string
  dedefault = "2"
}

variable "admin-name" {
  type    = "String"
  default = "adminswarm"

}

data "azurerm_client_config" "current" {}


resource "azurerm_key_vault" "test" {
  name                       = "kv-test${lower(random_id.kv-name.hex)}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enabled_for_deployment     = "true"
  enable_rbac_authorization  = "false"
  purge_protection_enabled   = "false"

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  depends_on = [
    azurerm_subnet.lab
  ]
}

resource "azurerm_key_vault_access_policy" "kv-test-access-policy" {
  key_vault_id = azurerm_key_vault.test.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Get",
    "Import",
    "List",
  ]

  secret_permissions = [
    "List",
    "Get",
    "Set",
  ]
}

resource "azurerm_key_vault_secret" "kv-secret-admin-vm" {
  name         = "vm-admin-password"
  value        = random_password.vm-admin-password.result
  key_vault_id = azurerm_key_vault.test.id

  depends_on = [
    azurerm_key_vault.test
  ]
}

# Create (and display) an SSH key
resource "tls_private_key" "ssh-cluster-swarm" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_key_vault_secret" "ssh-pub-key" {
  name         = "ssh-cluster-pub-key"
  value        = tls_private_key.ssh-cluster-swarm.public_key_openssh
  key_vault_id = azurerm_key_vault.test.id

  lifecycle {
    ignore_changes = ["value"]
  }
}

resource "azurerm_key_vault_secret" "ssh-priv-key" {
  name         = "ssh-cluster-priv-key"
  value        = tls_private_key.ssh-cluster-swarm.private_key_pem_openssh
  key_vault_id = azurerm_key_vault.test.id

  lifecycle {
    ignore_changes = ["value"]
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-techblog"
  location = "Central US"
}

resource "azurerm_virtual_network" "test" {
  name                = "vnet-techblog-cidr"
  address_space       = ["172.31.255.0/24"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "test" {
  name                 = "acctsub"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = ["172.31.255.64/27"]
}

resource "azurerm_public_ip" "test" {
  name                = "publicIPForLB"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Basic"
}

resource "azurerm_lb" "test" {
  name                = "loadBalancer"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Basic"

  frontend_ip_configuration {
    name                 = "publicIPAddress"
    public_ip_address_id = azurerm_public_ip.test.id
  }
}

resource "azurerm_lb_backend_address_pool" "test" {
  loadbalancer_id = azurerm_lb.test.id
  name            = "Swarm Cluster"
}

resource "azurerm_network_interface" "test" {
  count               = var.swarm-node-count
  name                = "acctni${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "testConfiguration"
    subnet_id                     = azurerm_subnet.test.id
    private_ip_address_allocation = "dynamic"
  }
}

resource "azurerm_managed_disk" "test" {
  count                = var.swarm-node-count
  name                 = "datadisk_existing_${count.index}"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = "64"
}

resource "azurerm_availability_set" "avset" {
  name                         = "avset"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
  managed                      = true
}

resource "azurerm_virtual_machine" "test" {
  count                 = var.swarm-node-count
  name                  = "techblog${count.index}"
  location              = azurerm_resource_group.rg.location
  availability_set_id   = azurerm_availability_set.avset.id
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [element(azurerm_network_interface.test.*.id, count.index)]
  vm_size               = "Standard_B2S"
  admin_username        = var.admin-name
  disable_password_authentication = true

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  # delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name              = "myosdisk${count.index}"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  # Optional data disks
  storage_data_disk {
    name              = "datadisk_new_${count.index}"
    managed_disk_type = "Standard_LRS"
    create_option     = "Empty"
    lun               = 0
    disk_size_gb      = "64"
  }

  storage_data_disk {
    name            = element(azurerm_managed_disk.test.*.name, count.index)
    managed_disk_id = element(azurerm_managed_disk.test.*.id, count.index)
    create_option   = "Attach"
    lun             = 1
    disk_size_gb    = element(azurerm_managed_disk.test.*.disk_size_gb, count.index)
  }

  admin_ssh_key {
    username   = var.admin-name
    public_key = azurerm_key_vault_secret.ssh-pub-key.value
  }

  tags = {
    role        = "Swarm Cluster"
    environment = "Tech Blog"
  }
}